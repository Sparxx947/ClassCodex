"""Shared helpers for the Class Codex data refresh tools.

Everything here is deliberately dependency-free: Python 3.11+ standard
library only, so the toolchain runs on a plain Linux box without a
virtualenv, a package manager or a headless browser.
"""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATA = REPO / "Data"
CACHE = Path(os.environ.get("CC_CACHE", REPO / "tools" / ".cache"))

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
)

# Wowhead sits behind a WAF that rejects anything not sending a full
# browser header set — a plain User-Agent still earns a 403 whether or
# not the page exists. Sending the Sec-Fetch / client-hint headers a
# real navigation carries is what gets a 200 back. Harmless elsewhere,
# so every request uses them.
BROWSER_HEADERS = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,"
              "image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate",
    "sec-ch-ua": '"Chromium";v="128", "Not;A=Brand";v="24"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Linux"',
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
    "Connection": "close",
}

# Class folder name -> the CLASS token the addon keys its tables with.
CLASS_DIRS = {
    "DeathKnight": "DEATHKNIGHT",
    "DemonHunter": "DEMONHUNTER",
    "Druid": "DRUID",
    "Evoker": "EVOKER",
    "Hunter": "HUNTER",
    "Mage": "MAGE",
    "Monk": "MONK",
    "Paladin": "PALADIN",
    "Priest": "PRIEST",
    "Rogue": "ROGUE",
    "Shaman": "SHAMAN",
    "Warlock": "WARLOCK",
    "Warrior": "WARRIOR",
}

# Archon/Icy Veins class slug -> class folder name.
SLUG_TO_DIR = {
    "death-knight": "DeathKnight",
    "demon-hunter": "DemonHunter",
    "druid": "Druid",
    "evoker": "Evoker",
    "hunter": "Hunter",
    "mage": "Mage",
    "monk": "Monk",
    "paladin": "Paladin",
    "priest": "Priest",
    "rogue": "Rogue",
    "shaman": "Shaman",
    "warlock": "Warlock",
    "warrior": "Warrior",
}

_log_lock = threading.Lock()


def log(msg: str) -> None:
    with _log_lock:
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()


# --------------------------------------------------------------------------
# HTTP with an on-disk cache
# --------------------------------------------------------------------------

_throttle = threading.Semaphore(1)
_last_request = [0.0]
MIN_INTERVAL = float(os.environ.get("CC_MIN_INTERVAL", "0.15"))


def _pace() -> None:
    """Keep a floor between requests so we stay a polite client."""
    with _throttle:
        wait = _last_request[0] + MIN_INTERVAL - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _last_request[0] = time.monotonic()


def fetch(url: str, *, max_age: float = 21600.0, retries: int = 4) -> str:
    """GET *url* as text, cached on disk for *max_age* seconds.

    Raises urllib.error.HTTPError on a final failure so callers can decide
    whether a missing page is fatal or just an absent spec/encounter.
    """
    CACHE.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:32]
    path = CACHE / f"{key}.html.gz"
    if path.exists() and (time.time() - path.stat().st_mtime) < max_age:
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            return fh.read()

    last: Exception | None = None
    for attempt in range(retries):
        _pace()
        req = urllib.request.Request(url, headers=dict(BROWSER_HEADERS))
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read()
                enc = (resp.headers.get("Content-Encoding") or "").lower()
                if enc == "gzip":
                    raw = gzip.decompress(raw)
                elif enc == "deflate":
                    raw = zlib.decompress(raw, -zlib.MAX_WBITS)
                text = raw.decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code in (404, 410):
                raise
            time.sleep(1.5 * (attempt + 1))
            continue
        except Exception as exc:  # noqa: BLE001 - network flakiness
            last = exc
            time.sleep(1.5 * (attempt + 1))
            continue

        with gzip.open(path, "wt", encoding="utf-8") as fh:
            fh.write(text)
        return text

    raise RuntimeError(f"giving up on {url}: {last}")


def head_status(url: str, *, retries: int = 3) -> tuple[int, str]:
    """Return (status, final_url) for *url*, following redirects."""
    for attempt in range(retries):
        _pace()
        headers = dict(BROWSER_HEADERS)
        headers["Range"] = "bytes=0-2047"
        req = urllib.request.Request(url, method="GET", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp.read(1)
                return resp.status, resp.geturl()
        except urllib.error.HTTPError as exc:
            return exc.code, url
        except Exception:  # noqa: BLE001
            time.sleep(1.0 * (attempt + 1))
    return 0, url


# --------------------------------------------------------------------------
# Next.js payload
# --------------------------------------------------------------------------

_NEXT = re.compile(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S
)


def next_data(html: str) -> dict:
    m = _NEXT.search(html)
    if not m:
        raise ValueError("no __NEXT_DATA__ payload in page")
    return json.loads(m.group(1))


_GATHERER = re.compile(r"WH\.Gatherer\.addData\(\s*(\d+)\s*,\s*\d+\s*,\s*")


def _balanced(text: str, start: int) -> str | None:
    """The {...} literal beginning at *start*, or None if unterminated."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def wowhead_items(html: str, data_type: int = 3) -> dict[int, dict]:
    """Entity id -> {"name", "icon"} from a page's WH.Gatherer payloads.

    Wowhead's markup references items by id alone; the names and icon
    slugs ride along in these blocks. Type 3 is items. The icon slug is
    worth keeping: it encodes what an item *is*
    (…alchemy_flask…, …alchemy_voidpotion…, …enchanting_manaoil…), which
    is far more reliable than reading the item's name.
    """
    out: dict[int, dict] = {}
    for m in _GATHERER.finditer(html):
        if int(m.group(1)) != data_type:
            continue
        blob = _balanced(html, m.end())
        if not blob:
            continue
        try:
            payload = json.loads(blob)
        except json.JSONDecodeError:
            continue
        for key, value in payload.items():
            if not key.isdigit() or not isinstance(value, dict):
                continue
            name = value.get("name_enus")
            if not name:
                continue
            out[int(key)] = {"name": name, "icon": value.get("icon") or ""}
    return out


def wowhead_names(html: str, data_type: int = 3) -> dict[int, str]:
    """Entity id -> English name. See wowhead_items for the full record."""
    out: dict[int, str] = {}
    for m in _GATHERER.finditer(html):
        if int(m.group(1)) != data_type:
            continue
        blob = _balanced(html, m.end())
        if not blob:
            continue
        try:
            payload = json.loads(blob)
        except json.JSONDecodeError:
            continue
        for key, value in payload.items():
            name = isinstance(value, dict) and value.get("name_enus")
            if name and key.isdigit():
                out[int(key)] = name
    return out


def strip_markup(text: str | None) -> str:
    """Archon wraps labels in pseudo-JSX (<ActorIcon ...>Frost</ActorIcon>)."""
    if not text:
        return ""
    return re.sub(r"<[^>]+>", "", text).strip()


# --------------------------------------------------------------------------
# Lua emitter
# --------------------------------------------------------------------------

class Keyed(dict):
    """A dict whose keys come from the data, not from the schema.

    Spec slugs, context keys and difficulty labels are values that happen
    to be used as table keys. Emitting them quoted — ["holy"] rather than
    holy — keeps them visually distinct from structural field names and
    stops a slug that happens to be a Lua identifier from looking like
    one. Lua treats both forms identically.
    """


_LUA_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}


def lua_str(value: str) -> str:
    out = "".join(_LUA_ESCAPES.get(ch, ch) for ch in value)
    return f'"{out}"'


def lua_key(key: str, *, always_quote: bool = False) -> str:
    if not always_quote and _IDENT.match(key) and key not in _LUA_KEYWORDS:
        return f"{key} = "
    return f"[{lua_str(key)}] = "


def lua_value(value, indent: int = 0) -> str:
    """Serialise a Python value as Lua source.

    Dicts keep insertion order, which is what makes the generated files
    stable across runs and therefore diffable.
    """
    pad = "  " * indent
    inner = "  " * (indent + 1)
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(round(value, 4))
    if isinstance(value, str):
        return lua_str(value)
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        # Short all-scalar lists read better on one line — this is what a
        # stat priority rank looks like: { "Critical Strike", "Haste" }.
        if all(isinstance(v, (str, int, float, bool)) for v in value):
            oneline = "{ " + ", ".join(lua_value(v) for v in value) + " }"
            if len(oneline) + len(pad) <= 100:
                return oneline
        parts = [f"{inner}{lua_value(v, indent + 1)}," for v in value]
        return "{\n" + "\n".join(parts) + f"\n{pad}}}"
    if isinstance(value, dict):
        items = [(k, v) for k, v in value.items() if v is not None]
        if not items:
            return "{}"
        quote = isinstance(value, Keyed)
        parts = [f"{inner}{lua_key(k, always_quote=quote)}{lua_value(v, indent + 1)},"
                 for k, v in items]
        return "{\n" + "\n".join(parts) + f"\n{pad}}}"
    raise TypeError(f"cannot serialise {type(value).__name__}")


def write_lua(path: Path, global_name: str, class_token: str, payload: dict,
              *, header: str = "") -> None:
    """Write `Global = Global or {}` + `Global["CLASS"] = {...}`.

    The top level is keyed by spec slug, which is data, so it is emitted
    quoted regardless of whether a given slug happens to be a valid Lua
    identifier — otherwise ["beast-mastery"] and survival would sit side
    by side in the same table.
    """
    payload = Keyed(payload)
    path.parent.mkdir(parents=True, exist_ok=True)
    body = [
        "-- Generated by tools/ in this repository. Do not edit by hand.",
    ]
    if header:
        body.extend(f"-- {line}" for line in header.splitlines())
    body.append(f"{global_name} = {global_name} or {{}}")
    body.append(f"{global_name}[{lua_str(class_token)}] = {lua_value(payload, 0)}")
    path.write_text("\n".join(body) + "\n", encoding="utf-8")

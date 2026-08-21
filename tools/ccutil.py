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
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": UA,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
                "Accept-Encoding": "gzip, deflate",
                "Connection": "close",
            },
        )
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
        req = urllib.request.Request(
            url, method="GET", headers={"User-Agent": UA, "Accept": "*/*", "Range": "bytes=0-2047"}
        )
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


def strip_markup(text: str | None) -> str:
    """Archon wraps labels in pseudo-JSX (<ActorIcon ...>Frost</ActorIcon>)."""
    if not text:
        return ""
    return re.sub(r"<[^>]+>", "", text).strip()


# --------------------------------------------------------------------------
# Lua emitter
# --------------------------------------------------------------------------

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


def lua_key(key: str) -> str:
    if _IDENT.match(key) and key not in _LUA_KEYWORDS:
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
        parts = [f"{inner}{lua_value(v, indent + 1)}," for v in value]
        return "{\n" + "\n".join(parts) + f"\n{pad}}}"
    if isinstance(value, dict):
        items = [(k, v) for k, v in value.items() if v is not None]
        if not items:
            return "{}"
        parts = [f"{inner}{lua_key(k)}{lua_value(v, indent + 1)}," for k, v in items]
        return "{\n" + "\n".join(parts) + f"\n{pad}}}"
    raise TypeError(f"cannot serialise {type(value).__name__}")


def write_lua(path: Path, global_name: str, class_token: str, payload: dict,
              *, header: str = "") -> None:
    """Write `Global = Global or {}` + `Global["CLASS"] = {...}`."""
    path.parent.mkdir(parents=True, exist_ok=True)
    body = [
        "-- Generated by tools/ in this repository. Do not edit by hand.",
    ]
    if header:
        body.extend(f"-- {line}" for line in header.splitlines())
    body.append(f"{global_name} = {global_name} or {{}}")
    body.append(f"{global_name}[{lua_str(class_token)}] = {lua_value(payload, 0)}")
    path.write_text("\n".join(body) + "\n", encoding="utf-8")

"""Reader for the guide markup Wowhead embeds in its class guide pages.

Wowhead renders class guides client-side from a BBCode-like source that
it ships inside the HTML as a JavaScript string literal:

    WH.markup.printHtml("[h2 toc=\"Stats\"]...[/h2]...", ...)

That source is far easier to read than the rendered DOM, and it is where
the machine-usable parts live — talent export strings, stat priorities,
BiS item ids. This module extracts and walks it.
"""

from __future__ import annotations

import json
import re

MARKUP_KEY = 'WH.markup.printHtml("'

# Wowhead stat token -> the in-game stat name the addon displays.
STAT_NAMES = {
    "crit": "Critical Strike",
    "critical": "Critical Strike",
    "haste": "Haste",
    "mastery": "Mastery",
    "vers": "Versatility",
    "versatility": "Versatility",
    "leech": "Leech",
    "speed": "Speed",
    "avoidance": "Avoidance",
    "stamina": "Stamina",
}
# Primary stats are not a gearing choice, so the addon leaves them out.
PRIMARY_STATS = {"agi", "agility", "str", "strength", "int", "intellect"}


def extract(html: str) -> str | None:
    """Pull the guide markup out of a fetched page, or None if absent."""
    start = html.find(MARKUP_KEY)
    if start < 0:
        return None
    i = start + len(MARKUP_KEY)
    out: list[str] = []
    while i < len(html):
        ch = html[i]
        if ch == "\\":
            out.append(html[i:i + 2])
            i += 2
            continue
        if ch == '"':
            break
        out.append(ch)
        i += 1
    try:
        return json.loads('"' + "".join(out) + '"')
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------------------
# Tag helpers
# ---------------------------------------------------------------------------

_ATTR = re.compile(r'([a-z-]+)\s*=\s*(?:"([^"]*)"|([^\s\]]+))')


def tag_attrs(body: str, *, name: str = "") -> dict[str, str]:
    """Attributes of one opening tag's body (everything after the name).

    Some tags carry their value on the tag itself rather than in a named
    attribute — [nav-item=guide/classes/...] or
    [dragonflight-talent-calc=blizzard/CODE]. That value is returned
    under the tag's own name.
    """
    out: dict[str, str] = {}
    body = body or ""
    if body.startswith("="):
        head = body[1:].split(None, 1)
        if head:
            out[name] = head[0]
            body = head[1] if len(head) > 1 else ""
    for key, quoted, bare in _ATTR.findall(body):
        out[key] = quoted if quoted else bare
    return out


def blocks(markup: str, name: str) -> list[tuple[dict[str, str], str]]:
    """Every [name ...] ... [/name] block as (attributes, inner text)."""
    out: list[tuple[dict[str, str], str]] = []
    open_re = re.compile(rf"\[{name}([\s=][^\]]*)?\]", re.S)
    close = f"[/{name}]"
    for m in open_re.finditer(markup):
        end = markup.find(close, m.end())
        if end < 0:
            continue
        out.append((tag_attrs(m.group(1) or "", name=name), markup[m.end():end]))
    return out


def nested_blocks(markup: str, name: str) -> list[tuple[dict[str, str], str]]:
    """Like blocks(), but nesting-aware.

    Wowhead nests [tabs]/[tab] inside each other. A naive scan to the
    first [/name] would cut an outer block short and silently lose
    everything after the inner one's close tag.
    """
    out: list[tuple[dict[str, str], str]] = []
    open_re = re.compile(rf"\[{name}([\s=][^\]]*)?\]", re.S)
    close = f"[/{name}]"
    for m in open_re.finditer(markup):
        depth = 1
        i = m.end()
        while depth and i < len(markup):
            nxt = markup.find(close, i)
            if nxt < 0:
                break
            inner = open_re.search(markup, i, nxt)
            if inner:
                depth += 1
                i = inner.end()
                continue
            depth -= 1
            i = nxt + len(close)
        if depth == 0:
            out.append((tag_attrs(m.group(1) or "", name=name),
                        markup[m.end():i - len(close)]))
    return out


def self_blocks(markup: str, name: str) -> list[dict[str, str]]:
    """Every self-contained [name ...] tag, as attribute dicts."""
    return [tag_attrs(m.group(1) or "", name=name)
            for m in re.finditer(rf"\[{name}([\s=][^\]]*)?\]", markup, re.S)]


_CLEAN_SPELL = re.compile(r"\[(?:spell|item|npc|quest)=(\d+)[^\]]*\]")
_CLEAN_TAG = re.compile(r"\[/?[a-z][a-z0-9-]*(?:[=\s][^\]]*)?\]", re.S)
_WS = re.compile(r"\s+")


def plain(text: str) -> str:
    """Markup -> the addon's plain step text, with {spellId} placeholders."""
    text = _CLEAN_SPELL.sub(r"{\1}", text)
    text = _CLEAN_TAG.sub("", text)
    text = text.replace("&nbsp;", " ")
    return _WS.sub(" ", text).strip()


def stat_priority(spec: str) -> list[list[str]]:
    """"agi>mastery>crit=haste" -> [["Mastery"], ["Critical Strike", "Haste"]].

    Ranks are separated by ">", equal-value stats within a rank by "=" or
    "~". Primary stats are dropped: the addon lists secondaries only.
    """
    ranks: list[list[str]] = []
    for rank in spec.split(">"):
        names: list[str] = []
        for token in re.split(r"[=~]", rank):
            token = token.strip().lower()
            if not token or token in PRIMARY_STATS:
                continue
            name = STAT_NAMES.get(token)
            if name and name not in names:
                names.append(name)
        if names:
            ranks.append(names)
    return ranks

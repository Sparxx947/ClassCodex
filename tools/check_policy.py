#!/usr/bin/env python3
"""Check the addon against Blizzard's UI Add-On Development Policy.

https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534

The audit that found the original violation — a Patreon button and a
backer list shipping in-game, against rule 5 — was a one-off manual
review. This makes it repeatable, so the same thing cannot quietly come
back through a careless edit or a merge from upstream.

Not everything in the policy can be decided by a machine: whether the
addon is genuinely free, or whether a string is offensive in context,
still needs a person. What is checked here are the mechanical signals
that gave the original violation away.

The one rule that makes this check usable rather than ignored: **only
executable Lua is examined**. Comments explaining why a donation button
was removed contain the word "Patreon", and a check that flags its own
explanation is a check everyone learns to skip.

Exit code 1 on any finding.

Usage:
    python3 tools/check_policy.py [--verbose]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Directories that are not part of what the client loads. tools/ is this
# toolchain; docs/ is prose about it. Neither ships — see tools/package.sh.
SKIP_DIRS = {".git", ".github", "tools", "docs", "dist"}
# Embedded community libraries are third-party code, reported separately
# rather than treated as ours to fix.
LIB_DIR = "Libs"
# Data files are scraped guide text. They are quoted source material, not
# the addon speaking, so they are excluded from wording checks — but not
# from the asset check.
DATA_DIR = "Data"

# Hosts that mean money is being asked for or advertised (rules 1, 4, 5).
PAYMENT_HOSTS = (
    "patreon.com", "ko-fi.com", "kofi.com", "paypal.com", "paypal.me",
    "buymeacoffee.com", "gumroad.com", "boosty.to", "opencollective.com",
    "liberapay.com", "github.com/sponsors", "streamlabs.com",
    "donorbox.org", "tipeee", "subscribestar",
)
# Wording that solicits, independent of a link (rule 5).
SOLICIT_WORDS = (
    "donate", "donation", "pledge", "become a patron", "buy me a coffee",
    "support the addon", "support this addon", "tip jar",
)
# Locale keys that name a donation surface. Language-independent, which
# is the point: the wording lists above are English only.
SUSPECT_KEYS = ("patreon", "donate", "donation", "kofi", "ko_fi", "sponsor",
                "supporter", "support_")
OFFENSIVE_WORDS = (
    "fuck", "shit", "bitch", "cunt", "whore", "faggot", "nigger", "retard",
)
GAME_ASSETS = (".blp", ".mp3", ".ogg", ".wav", ".m2", ".mdx")

_COMMENT = re.compile(r"--\[\[.*?\]\]|--[^\n]*", re.S)
_STRING = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')


def lua_files(include_data: bool = False) -> list[Path]:
    out: list[Path] = []
    for path in REPO.rglob("*.lua"):
        rel = path.relative_to(REPO)
        if rel.parts[0] in SKIP_DIRS:
            continue
        if not include_data and rel.parts[0] == DATA_DIR:
            continue
        out.append(path)
    return sorted(out)


def code_only(text: str) -> str:
    """Lua with comments blanked out, line structure preserved.

    A comment is not the addon asking anyone for money. Blanking rather
    than deleting keeps line numbers usable in findings.
    """
    return _COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


class Report:
    def __init__(self) -> None:
        self.findings: list[tuple[str, str]] = []
        self.notes: list[str] = []

    def fail(self, rule: str, detail: str) -> None:
        self.findings.append((rule, detail))

    def note(self, detail: str) -> None:
        self.notes.append(detail)


def check_money(report: Report, verbose: bool) -> None:
    """Rules 1, 4 and 5 — charging, advertising, soliciting donations."""
    hits = 0
    for path in lua_files():
        rel = path.relative_to(REPO)
        text = code_only(path.read_text(encoding="utf-8", errors="replace"))
        for number, line in enumerate(text.splitlines(), 1):
            lowered = line.lower()
            for host in PAYMENT_HOSTS:
                if host in lowered:
                    report.fail("5", f"{rel}:{number} links a payment host: {host}")
                    hits += 1
            for word in SOLICIT_WORDS:
                if word in lowered:
                    report.fail("5", f"{rel}:{number} solicits: {word!r}")
                    hits += 1

    # Locale strings are what the player actually reads, so they are
    # checked whole rather than only where they are used.
    #
    # The wording lists are English, so they only catch enUS — a German
    # "Unterstütze das Addon" would slip past. The key *name* does not
    # translate, so it is checked too: that is what catches the same
    # string in all ten languages at once.
    for path in sorted((REPO / "Locales").glob("*.lua")):
        rel = path.relative_to(REPO)
        text = code_only(path.read_text(encoding="utf-8", errors="replace"))
        for number, line in enumerate(text.splitlines(), 1):
            key = re.match(r'\s*L\["([^"]+)"\]', line)
            if key and any(word in key.group(1).lower() for word in SUSPECT_KEYS):
                report.fail("5", f"{rel}:{number} key names a donation surface: "
                                 f"{key.group(1)}")
                hits += 1
            for value in _STRING.findall(line):
                lowered = value.lower()
                for word in SOLICIT_WORDS:
                    if word in lowered:
                        report.fail("5", f"{rel}:{number} string solicits: {value[:60]!r}")
                        hits += 1
                for host in PAYMENT_HOSTS:
                    if host in lowered:
                        report.fail("5", f"{rel}:{number} string links {host}")
                        hits += 1
    if verbose and not hits:
        report.note("no payment hosts or soliciting wording in executable code")


def check_visible_code(report: Report, verbose: bool) -> None:
    """Rule 2 — code must not be hidden or obfuscated."""
    for path in lua_files():
        rel = path.relative_to(REPO)
        if rel.parts[0] == LIB_DIR:
            continue
        text = code_only(path.read_text(encoding="utf-8", errors="replace"))
        for number, line in enumerate(text.splitlines(), 1):
            # loadstring on anything but a plain literal builds code at
            # runtime, which is what "hidden" means in practice.
            if re.search(r"\bloadstring\s*\(", line) and not re.search(
                    r'\bloadstring\s*\(\s*"', line):
                report.fail("2", f"{rel}:{number} builds code with loadstring")
            for blob in re.findall(r'"([A-Za-z0-9+/=]{300,})"', line):
                report.fail("2", f"{rel}:{number} embeds a {len(blob)}-char opaque literal")
    if verbose:
        report.note("talent export strings live in Data/ and are data, not code")


def check_realm_impact(report: Report, verbose: bool) -> None:
    """Rule 3 — no burden on realms or other players."""
    chat = 0
    for path in lua_files():
        rel = path.relative_to(REPO)
        text = code_only(path.read_text(encoding="utf-8", errors="replace"))
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r"\bSendChatMessage\s*\(", line):
                report.fail("3", f"{rel}:{number} sends chat messages")
                chat += 1
            if re.search(r"\b(C_ChatInfo\.)?SendAddonMessage\s*\(", line):
                report.fail("3", f"{rel}:{number} sends addon messages")
                chat += 1
            # A ticker with a zero interval fires every frame. That is
            # fine briefly, but only if something stops it.
            if re.search(r"NewTicker\s*\(\s*0\s*,", line):
                window = "\n".join(text.splitlines()[number - 1:number + 40])
                if "Cancel()" not in window:
                    report.fail("3", f"{rel}:{number} NewTicker(0, …) with no visible Cancel()")
                elif verbose:
                    report.note(f"{rel}:{number} NewTicker(0, …) is cancelled — fine")

    # An OnUpdate handler that is installed but never cleared runs for the
    # whole session.
    for path in lua_files():
        rel = path.relative_to(REPO)
        if rel.parts[0] == LIB_DIR:
            continue
        text = code_only(path.read_text(encoding="utf-8", errors="replace"))
        installs = len(re.findall(r'SetScript\s*\(\s*"OnUpdate"\s*,\s*function', text))
        clears = len(re.findall(r'SetScript\s*\(\s*"OnUpdate"\s*,\s*nil', text))
        if installs and clears < installs:
            report.fail("3", f"{rel} installs {installs} OnUpdate handler(s) "
                             f"but clears {clears}")
        elif installs and verbose:
            report.note(f"{rel}: {installs} OnUpdate handler(s), all cleared")
    if verbose and not chat:
        report.note("no chat or addon messages anywhere")


def check_offensive(report: Report, verbose: bool) -> None:
    """Rule 6 — nothing beyond the game's rating."""
    hits = 0
    for path in lua_files(include_data=True):
        rel = path.relative_to(REPO)
        text = path.read_text(encoding="utf-8", errors="replace").lower()
        for word in OFFENSIVE_WORDS:
            if re.search(rf"\b{re.escape(word)}\b", text):
                report.fail("6", f"{rel} contains {word!r}")
                hits += 1
    if verbose and not hits:
        report.note("no offensive wording found")


def check_assets(report: Report, verbose: bool) -> None:
    """Rule 7 — no redistributed Blizzard art or audio."""
    found = 0
    for path in REPO.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(REPO)
        if rel.parts[0] in SKIP_DIRS:
            continue
        if path.suffix.lower() in GAME_ASSETS:
            report.fail("7", f"{rel} is a game asset format ({path.suffix})")
            found += 1
    if verbose and not found:
        report.note("no .blp/.mp3/.ogg/.wav in the payload; icons are referenced by path")


RULES = {
    "1": "Add-ons must be free of charge",
    "2": "Add-on code must be completely visible",
    "3": "Add-ons must not negatively impact realms or other players",
    "4": "Add-ons may not include advertisements",
    "5": "Add-ons may not solicit donations",
    "6": "Add-ons must not contain offensive or objectionable material",
    "7": "Add-ons must abide by the ToU and EULA",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--verbose", action="store_true",
                    help="also print what was checked and found clean")
    args = ap.parse_args()

    report = Report()
    check_money(report, args.verbose)
    check_visible_code(report, args.verbose)
    check_realm_impact(report, args.verbose)
    check_offensive(report, args.verbose)
    check_assets(report, args.verbose)

    print("Blizzard UI Add-On Development Policy")
    print(f"checked {len(lua_files())} Lua files (excluding Data/ and tools/)\n")

    by_rule: dict[str, list[str]] = {}
    for rule, detail in report.findings:
        by_rule.setdefault(rule, []).append(detail)

    for rule, title in RULES.items():
        hits = by_rule.get(rule, [])
        mark = "FAIL" if hits else "ok"
        print(f"  {mark:4} rule {rule} — {title}")
        for detail in hits:
            print(f"         {detail}")

    if args.verbose and report.notes:
        print("\n  checked and clean:")
        for note in report.notes:
            print(f"    - {note}")

    print("\n  Not decidable here, and left to a person: whether the addon is\n"
          "  genuinely distributed free of charge (rule 1), and whether\n"
          "  Blizzard has disabled any functionality it uses (rule 8).")

    if report.findings:
        print(f"\n{len(report.findings)} finding(s)")
        return 1
    print("\nno findings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

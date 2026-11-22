#!/usr/bin/env python3
"""Check Clio's two dictionaries and SwiftUI design rules."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TONE = Path("App/Sources/Tone")
INK = Path("App/Sources/Design/Ink.swift")
READING = Path("App/Sources/Reading")
# Concurrent chat and pet work already owns its typography. The established
# color, font-family and monospaced checks still apply to those files.
SIZE_HANDOFF = {READING / "ChatPage.swift", READING / "ProseView.swift"}
EXCEPTIONS = {
    "custom": {INK, Path("App/Sources/Design/Kit.swift")},
    "color": {INK},
}
MESSAGES = {
    "mono": "Use Ink.mono or Ink.uiMono for monospaced text",
    "custom": "Choose fonts through Ink",
    "color": "Use a color from Ink",
    "size": "Choose one of the five Ink.Size values for UI text",
}
SWIFT_PATTERNS = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/'
    r'|(?P<mono>\bdesign\s*:\s*\.\s*monospaced\b)'
    r'|(?P<custom>\.\s*custom\s*\(\s*(?=#*"))'
    r'|(?P<color>\b(?:UI)?Color\s*\(\s*(?:red|white|hue|hex)\s*:)'
    r'|(?P<size>(?:\.\s*system\s*\(\s*size\s*:\s*|\bInk\s*\.\s*(?:serif|mark|mono|uiMono)\s*\(\s*)[0-9])'
    r'|(?P<raw>#+)(?:"""[\s\S]*?"""|"[^\n]*?")(?P=raw)'
    r'|"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"'
)
KEY = re.compile(r'^([ \t]*)("(?:\\.|[^"\\])*")[ \t]*:[ \t]*', re.MULTILINE)


def leaf_keys(node, prefix=()):
    for key, value in node.items():
        path = (*prefix, key)
        if isinstance(value, dict):
            yield from leaf_keys(value, path)
        else:
            yield path


def key_lines(text):
    parents = []
    for match in KEY.finditer(text):
        indent = len(match[1].expandtabs())
        while parents and parents[-1][0] >= indent:
            parents.pop()
        key = json.loads(match[2])
        path = (*(parent for _, parent in parents), key)
        if text[match.end():].lstrip().startswith("{"):
            parents.append((indent, key))
        yield path, text.count("\n", 0, match.start(2)) + 1


def dictionaries():
    entries = {}
    for style in ("daily", "literary"):
        path = TONE / f"zh-CN.{style}.json"
        try:
            text = (ROOT / path).read_text(encoding="utf-8")
            content = json.loads(text)
        except json.JSONDecodeError as error:
            yield path, error.lineno, error.msg
            continue
        except OSError as error:
            yield path, 1, str(error)
            continue
        if not isinstance(content, dict):
            yield path, 1, "Expected a JSON object"
            continue
        entries[style] = (path, set(leaf_keys(content)), dict(key_lines(text)))
    if len(entries) != 2:
        return
    for style, other in (("daily", "literary"), ("literary", "daily")):
        path, content, lines = entries[style]
        for key in sorted(content - entries[other][1]):
            yield path, lines.get(key, 1), f"{'.'.join(key)!r} is missing from the {other} dictionary"


def swift_sources():
    for full_path in sorted((ROOT / "App/Sources").rglob("*.swift")):
        path = full_path.relative_to(ROOT)
        text = full_path.read_text(encoding="utf-8")
        for match in SWIFT_PATTERNS.finditer(text):
            rule = match.lastgroup
            if rule == "size" and (path in SIZE_HANDOFF or path.name.startswith("ChatPage+") or path.is_relative_to("App/Sources/Pet")):
                continue
            if rule in MESSAGES and path not in EXCEPTIONS.get(rule, ()):
                yield path, text.count("\n", 0, match.start()) + 1, MESSAGES[rule]


LITERARY_TERMS = re.compile(
    r"旅伴|书案|斗室|远山|远游|信匣|密匣|拾遗|絮语|名帖|晨信|落款|调弦|雅集|别馆|港湾|更漏|良方|手札|日课|偶得|集珍|笔庄|应许|封缄|便笺"
)
LITERARY_SKIP_FILES = {
    Path("App/Sources/Design/Words.swift"),
    Path("App/Sources/Tone/ModelErrorCopy.swift"),
    Path("App/Sources/Shots.swift"),
}
LITERARY_STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')


def literary_warnings():
    for full_path in sorted((ROOT / "App/Sources").rglob("*.swift")):
        path = full_path.relative_to(ROOT)
        if path in LITERARY_SKIP_FILES:
            continue
        for lineno, raw in enumerate(full_path.read_text(encoding="utf-8").splitlines(), 1):
            code = raw.split("//", 1)[0]
            if not code or "Words.t(" in code or "L.t(" in code:
                continue
            if any(token in code for token in ("description:", "ToolOutput(", "Diag.note(", ".hitchPage(", "appendingPathComponent(")):
                continue
            for match in LITERARY_STRING.finditer(code):
                found = sorted(set(LITERARY_TERMS.findall(match.group(0))))
                if found:
                    yield path, lineno, f"bare literary term ({', '.join(found)}); wrap with Words.t(...) or L.t(...) if user-visible"
                    break


def main():
    errors = [*dictionaries(), *swift_sources()]
    warnings = list(literary_warnings())
    for path, line, message in warnings:
        print(f"warning: {path}:{line}: {message}", file=sys.stderr)
    for path, line, message in errors:
        print(f"{path}:{line}: {message}", file=sys.stderr)
    if not errors:
        print(f"Clio lint passed ({len(warnings)} literary warnings).")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())

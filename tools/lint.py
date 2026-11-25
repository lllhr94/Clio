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


SWIFT_STRIP = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/'
    r'|(?P<raw>#+)(?:"""[\s\S]*?"""|"[^\n]*?")(?P=raw)'
    r'|"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"'
)
HAS_VIEW_CONFORMANCE = re.compile(r':\s*(?:SwiftUI\.)?View\b')
PERF_ALLOC = re.compile(r'\b(?:DateFormatter|ByteCountFormatter|NSRegularExpression)\s*\(')
STATIC_LET_DECL = re.compile(r'\bstatic\s+let\b')
SOME_VIEW_SCOPE = re.compile(r'(?::|->)\s*(?:SwiftUI\.)?some\s+View\b')
NAMECARD_FILE_CALL = re.compile(r'\bNameCard\s*\.\s*file\s*\(')
SECRETS_SECRET_CALL = re.compile(r'\bSecrets\s*\.\s*secret\s*\(')
OVERLAY_MODIFIER = re.compile(r'\.overlay\b')
SHADOW_MODIFIER = re.compile(r'\s*\.\s*shadow\s*\(')
SWIPE_ACTION_STRUCT = re.compile(r'\bstruct\s+SwipeAction\b')
SWIPE_ACTION_INIT = re.compile(r'\bSwipeAction\s*\(')
FOREACH_CALL = re.compile(r'\bForEach\s*\(')
FOREACH_ID_ARG = re.compile(r'\bid\s*:')
UUID_CALL = re.compile(r'\bUUID\s*\(\s*\)')


def strip_comments_and_strings(text):
    return SWIFT_STRIP.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def balanced_span(text, start, open_ch, close_ch):
    if start >= len(text) or text[start] != open_ch:
        return None
    depth = 0
    for idx in range(start, len(text)):
        ch = text[idx]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return idx + 1
    return None


def skip_ws(text, pos):
    while pos < len(text) and text[pos].isspace():
        pos += 1
    return pos


def has_perf_exemption(raw_lines, lineno):
    return 1 <= lineno <= len(raw_lines) and "lint:perf-ok" in raw_lines[lineno - 1]


def perf_checks():
    perf_errors = []
    perf_warnings = []

    for full_path in sorted((ROOT / "App/Sources").rglob("*.swift")):
        path = full_path.relative_to(ROOT)
        text = full_path.read_text(encoding="utf-8")
        raw_lines = text.splitlines()
        stripped = strip_comments_and_strings(text)
        stripped_lines = stripped.splitlines()

        # 1. Non-static DateFormatter / ByteCountFormatter / NSRegularExpression in View-containing files.
        if HAS_VIEW_CONFORMANCE.search(stripped):
            static_let_depth = 0
            pending_static_let = False
            for lineno, line in enumerate(stripped_lines, 1):
                is_static_line = bool(STATIC_LET_DECL.search(line))
                if not is_static_line and static_let_depth == 0 and not pending_static_let:
                    if PERF_ALLOC.search(line) and not has_perf_exemption(raw_lines, lineno):
                        perf_warnings.append((
                            path,
                            lineno,
                            "non-static formatter/regex allocation in View file; hoist to static let (or // lint:perf-ok)",
                        ))
                if is_static_line:
                    pending_static_let = True
                if pending_static_let or static_let_depth > 0:
                    opens = line.count("{")
                    closes = line.count("}")
                    static_let_depth += opens - closes
                    if opens > 0 or "=" in line:
                        if static_let_depth <= 0 and "{" in line:
                            pending_static_let = False
                            static_let_depth = 0
                        elif static_let_depth > 0:
                            pending_static_let = False
                    if static_let_depth <= 0 and not line.rstrip().endswith(("=", "{")):
                        pending_static_let = False
                        static_let_depth = 0

        # 2. Direct NameCard.file( (error) or Secrets.secret( (warning) inside `some View` scopes.
        view_depth = 0
        awaiting_view_brace = False
        for lineno, line in enumerate(stripped_lines, 1):
            entered_here = False
            if SOME_VIEW_SCOPE.search(line):
                awaiting_view_brace = True
            if awaiting_view_brace and "{" in line:
                entered_here = True
            active_in_view = view_depth > 0 or entered_here
            if active_in_view and not has_perf_exemption(raw_lines, lineno):
                if NAMECARD_FILE_CALL.search(line):
                    perf_errors.append((
                        path,
                        lineno,
                        "direct NameCard.file( inside View body; use lazy NameCardTransfer (or // lint:perf-ok)",
                    ))
                if SECRETS_SECRET_CALL.search(line):
                    perf_warnings.append((
                        path,
                        lineno,
                        "direct Secrets.secret( inside View body; move keychain lookup out of body (or // lint:perf-ok)",
                    ))
            if awaiting_view_brace or view_depth > 0:
                for ch in line:
                    if ch == "{":
                        view_depth += 1
                        awaiting_view_brace = False
                    elif ch == "}" and view_depth > 0:
                        view_depth -= 1

        # 3. Chained .overlay(...).shadow( outer shadow causing offscreen render pass.
        for match in OVERLAY_MODIFIER.finditer(stripped):
            pos = skip_ws(stripped, match.end())
            if pos < len(stripped) and stripped[pos] == "(":
                end = balanced_span(stripped, pos, "(", ")")
                if end is None:
                    continue
                pos = skip_ws(stripped, end)
            if pos < len(stripped) and stripped[pos] == "{":
                end = balanced_span(stripped, pos, "{", "}")
                if end is None:
                    continue
                pos = end
            shadow_match = SHADOW_MODIFIER.match(stripped, pos)
            if shadow_match:
                overlay_line = stripped.count("\n", 0, match.start()) + 1
                shadow_line = stripped.count("\n", 0, shadow_match.start() + (len(shadow_match.group(0)) - len(shadow_match.group(0).lstrip()))) + 1
                if not has_perf_exemption(raw_lines, overlay_line) and not has_perf_exemption(raw_lines, shadow_line):
                    perf_warnings.append((
                        path,
                        shadow_line,
                        "chained .overlay(...).shadow( causes offscreen pass; move .shadow inside .background shape (or // lint:perf-ok)",
                    ))

        # 4. UUID() inside SwipeAction or ForEach(..., id: ...) closures.
        flagged_uuid_lines = set()
        for pattern in (SWIPE_ACTION_STRUCT, SWIPE_ACTION_INIT):
            open_ch, close_ch = ("{", "}") if pattern is SWIPE_ACTION_STRUCT else ("(", ")")
            for match in pattern.finditer(stripped):
                pos = stripped.find(open_ch, match.end()) if open_ch == "{" else match.end() - 1
                if pos == -1:
                    continue
                end = balanced_span(stripped, pos, open_ch, close_ch)
                if end is None:
                    continue
                for u_match in UUID_CALL.finditer(stripped, pos, end):
                    lineno = stripped.count("\n", 0, u_match.start()) + 1
                    if lineno not in flagged_uuid_lines and not has_perf_exemption(raw_lines, lineno):
                        flagged_uuid_lines.add(lineno)
                        perf_warnings.append((
                            path,
                            lineno,
                            "UUID() inside SwipeAction causes identity churn on every render (or // lint:perf-ok)",
                        ))
        for match in FOREACH_CALL.finditer(stripped):
            paren_start = match.end() - 1
            paren_end = balanced_span(stripped, paren_start, "(", ")")
            if paren_end is None:
                continue
            id_match = FOREACH_ID_ARG.search(stripped, paren_start, paren_end)
            if not id_match:
                continue
            for u_match in UUID_CALL.finditer(stripped, id_match.end(), paren_end):
                lineno = stripped.count("\n", 0, u_match.start()) + 1
                if lineno not in flagged_uuid_lines and not has_perf_exemption(raw_lines, lineno):
                    flagged_uuid_lines.add(lineno)
                    perf_warnings.append((
                        path,
                        lineno,
                        "UUID() inside ForEach(..., id:) causes view identity churn (or // lint:perf-ok)",
                    ))

    return perf_errors, perf_warnings


def main():
    perf_errors, perf_warnings = perf_checks()
    errors = [*dictionaries(), *swift_sources(), *perf_errors]
    lit_warnings = list(literary_warnings())
    warnings = [*lit_warnings, *perf_warnings]
    for path, line, message in warnings:
        print(f"warning: {path}:{line}: {message}", file=sys.stderr)
    for path, line, message in errors:
        print(f"{path}:{line}: {message}", file=sys.stderr)
    if not errors:
        print(f"Clio lint passed ({len(lit_warnings)} literary warnings, {len(perf_warnings)} perf warnings).")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Run the chat's current rules without loading SwiftUI or changing its source files."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
READING = ROOT / "App/Sources/Reading"


def extract(path: Path, pattern: str, label: str) -> str:
    matches = list(re.finditer(pattern, path.read_text(), flags=re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise SystemExit(f"{path.name}: expected one {label}; update the chat flow fixture for the new implementation")
    return matches[0][0]


def member(path: Path, name: str) -> str:
    return extract(path, rf"^    (?:private )?(?:static )?func {name}\([^\n]*\{{\n.*?^    \}}", name)


def chat_part(pattern: str, label: str) -> str:
    """The chat page is split across ChatPage.swift and its ChatPage+*.swift extensions: find the one file with it."""
    files = sorted(READING.glob("ChatPage*.swift"))
    found = [path for path in files if re.search(pattern, path.read_text(), flags=re.MULTILINE | re.DOTALL)]
    if len(found) != 1:
        raise SystemExit(f"ChatPage: expected {label} in exactly one file, found {len(found)}")
    return extract(found[0], pattern, label)


def chat_member(name: str) -> str:
    return chat_part(rf"^    (?:private )?(?:static )?func {name}\([^\n]*\{{\n.*?^    \}}", name)


def fixture() -> str:
    chat = READING / "ChatPage.swift"
    phase = chat_part(r"^            \.onScrollPhaseChange \{ old, phase, context in\n.*?^            \}", "scroll-phase callback")
    phase_body = "\n".join(phase.splitlines()[1:-1])
    # Keep the source's Task and cancellation checks. Substitute only the sleep
    # call so tests can advance each delay without racing the runner's clock.
    schedule, sleeps = re.subn(r"\bTask\.sleep\(", "clock.sleep(", chat_member("followToEnd"))
    if sleeps != 1:
        raise SystemExit("ChatPage.followToEnd: update the clock fixture for the changed scheduling rules")
    template = (ROOT / "tools/tests/ChatFlowFixture.swift").read_text()
    model = ROOT / "App/Sources/Chat.swift"
    reply_text = extract(model, r"^        case \.text\(let piece\):\n.*?(?=^        case )", "live reply text handler")
    reply_reset = extract(model, r"^        case \.streamReset:\n.*?(?=^        case )", "live reply reset handler")
    fragments = {
        "PET_SURFACE": extract(
            ROOT / "App/Sources/Pet/PetPerch.swift",
            r"^    private final class Surface: UIWindow \{\n.*?^    \}",
            "pet window touch handler",
        ),
        "TURN_EVENT": extract(ROOT / "App/Sources/Team.swift", r"^enum TurnEvent \{\n.*?^\}", "turn events"),
        "KEPT_ROWS": member(model, "updateKeptRows"),
        "RESET_REPLY": member(model, "resetLiveReply"),
        "ADD_TEXT": "\n".join(reply_text.splitlines()[1:]),
        "STREAM_RESET": "\n".join(reply_reset.splitlines()[1:]),
        "TYPING_STEP": member(model, "step"),
        "STREAM_BLOCKS": extract(READING / "ProseView.swift", r"^struct StreamBlocks \{\n.*?^\}", "stream block scanner"),
        "DRAFT_INPUT": extract(chat, r"^enum DraftInput \{\n.*?^\}", "draft rules"),
        "BELOW": chat_member("below"),
        "END_ALIGNMENT": chat_member("endAlignment"),
        "END_ALIGNMENT_CHANGED": chat_member("endAlignmentChanged"),
        "SELECTION_CHANGED": chat_member("selectionChanged"),
        "PHASE": phase_body,
        "FOLLOW": schedule,
        "CLEAR_COMPOSER": chat_member("clearComposer"),
    }
    for label, source in fragments.items():
        template = template.replace(f"// RULE: {label}\n", source + "\n", 1)
    return template


def run(command: list[str], label: str, timeout: int) -> None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        if error.stdout:
            print(error.stdout.decode(errors="replace"), end="")
        if error.stderr:
            print(error.stderr.decode(errors="replace"), file=sys.stderr, end="")
        raise SystemExit(f"::error::{label} timed out after {timeout}s")
    print(result.stdout, end="")
    print(result.stderr, file=sys.stderr, end="")
    if result.returncode:
        # The check annotation is also available when the job log cannot be downloaded.
        detail = (result.stderr or result.stdout).strip()[:1800].replace("\n", "%0A")
        raise SystemExit(f"::error::{label} exited with {result.returncode}: {detail}")


def check_reckoner(swiftc: str, directory: Path) -> None:
    if sys.platform != "darwin":
        return
    template = (ROOT / "tools/tests/ReckonerFixture.swift").read_text()
    implementation = extract(
        ROOT / "App/Sources/Study/Workspace.swift",
        r"^enum Reckoner \{\n.*?^\}",
        "JavaScript watchdog",
    )
    source = directory / "ReckonerTests.swift"
    binary = source.with_suffix("")
    source.write_text(template.replace("// SOURCE: RECKONER", implementation))
    run([swiftc, "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)], "Compile JavaScript watchdog fixture", 90)
    run([str(binary)], "Run JavaScript watchdog fixture", 25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc", help="Swift compiler path")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="clio-chat-flow-") as directory:
        source = Path(directory) / "ChatFlowTests.swift"
        binary = source.with_suffix("")
        source.write_text(fixture())
        run([args.swiftc, "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)], "Compile chat flow fixture", 90)
        run([str(binary)], "Run chat flow fixture", 30)
        check_reckoner(args.swiftc, Path(directory))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read-only converter from App/Pets/{xiaoke,roubao}/pack.json & sprite PNGs to prototype/pet-sprites.js."""

import base64
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PETS_ROOT = ROOT / "App" / "Pets"
OUT_FILE = ROOT / "design" / "design-system-2.0" / "prototype" / "pet-sprites.js"


def load_pet_payload(pet_id: str, fallback_name: str) -> tuple[dict, int, int]:
    pet_dir = PETS_ROOT / pet_id
    pack_path = pet_dir / "pack.json"
    pack = json.loads(pack_path.read_text(encoding="utf-8"))

    sheets = {}
    animations = pack.get("animations", {})
    for anim in animations.values():
        sheet_name = anim.get("sheet")
        if not sheet_name or sheet_name in sheets:
            continue
        png_path = pet_dir / sheet_name
        raw = png_path.read_bytes()
        b64 = base64.b64encode(raw).decode("ascii")
        sheets[sheet_name] = f"data:image/png;base64,{b64}"

    payload = {
        "id": pack.get("id", pet_id),
        "name": pack.get("name", fallback_name),
        "canvas": pack.get("canvas", {"w": 48, "h": 48}),
        "anchor": pack.get("anchor", {"x": 24.5, "baseline": 48}),
        "contentBox": pack.get("contentBox", {"x": 7, "y": 0, "w": 34, "h": 48}),
        "animations": animations,
        "states": pack.get("states", {}),
        "reactions": pack.get("reactions", {}),
        "sheets": sheets,
    }
    return payload, len(animations), len(sheets)


def main() -> None:
    packs = {}
    summary = []
    for pet_id, fallback_name in [("xiaoke", "小克"), ("roubao", "肉包")]:
        payload, n_anims, n_sheets = load_pet_payload(pet_id, fallback_name)
        packs[pet_id] = payload
        summary.append(f"{pet_id}({n_anims} anims/{n_sheets} sheets)")

    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    header = "// Auto-generated read-only from App/Pets/{xiaoke,roubao}/pack.json & PNGs. Do not hand-edit.\n"
    body = (
        f"window.CLIO_PET_SPRITES = {json.dumps(packs['xiaoke'], ensure_ascii=False, separators=(',', ':'))};\n"
        f"window.CLIO_PET_PACKS = {json.dumps(packs, ensure_ascii=False, separators=(',', ':'))};\n"
    )
    OUT_FILE.write_text(header + body, encoding="utf-8")
    print(f"Wrote {OUT_FILE} ({OUT_FILE.stat().st_size} bytes): {', '.join(summary)}")


if __name__ == "__main__":
    main()

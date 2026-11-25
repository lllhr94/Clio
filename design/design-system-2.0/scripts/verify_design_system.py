#!/usr/bin/env python3
"""Automated verification for all 21 Clio Design System 2.0 deliverables and zero-production-mutation guard."""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DS = ROOT / "design" / "design-system-2.0"

REQUIRED_FILES = [
    DS / "README.md",
    # Research & Evidence (Deliverables 1-2)
    DS / "research" / "00-evidence-audit-log.md",
    DS / "research" / "01-china-indie-craft.md",
    DS / "research" / "02-china-ai-productivity.md",
    DS / "research" / "03-mobile-os-systems.md",
    DS / "research" / "04-international-benchmarks.md",
    DS / "research" / "05-matrix-and-clio-mapping.md",
    DS / "research" / "06-extended-global-china-and-standards.md",
    # Audit & Feature Map (Deliverables 3-4)
    DS / "audit" / "01-current-ui-audit.md",
    DS / "audit" / "02-feature-inventory-map.md",
    # IA & Settings & Click Paths (Deliverables 5-7)
    DS / "ia" / "01-information-architecture-and-navigation.md",
    DS / "ia" / "02-settings-taxonomy.md",
    DS / "ia" / "03-user-flows-and-click-paths.md",
    # Three Design Languages (Deliverable 8)
    DS / "languages" / "06-three-design-languages.md",
    # 7 Standalone Specs + Tokens (Deliverables 11-17)
    DS / "specs" / "tokens.v2.json",
    DS / "specs" / "01-typography.md",
    DS / "specs" / "02-color.md",
    DS / "specs" / "03-layout.md",
    DS / "specs" / "04-component.md",
    DS / "specs" / "05-motion.md",
    DS / "specs" / "06-haptics.md",
    DS / "specs" / "07-accessibility.md",
    # Engineering & Roadmap & Device QA (Deliverables 18-21)
    DS / "engineering" / "01-component-source-mapping.md",
    DS / "engineering" / "02-swiftui-uikit-implementation.md",
    DS / "engineering" / "03-phased-refactoring-roadmap.md",
    DS / "engineering" / "04-device-qa-and-acceptance-rubric.md",
    # Scripts & Prototype v5 (Deliverables 9-10)
    DS / "scripts" / "build_pet_sprites.py",
    DS / "scripts" / "verify_design_system.py",
    DS / "prototype" / "index.html",
    DS / "prototype" / "styles.css",
    DS / "prototype" / "tokens.js",
    DS / "prototype" / "pet-sprites.js",
    DS / "prototype" / "app.js",
]

REQUIRED_COVERAGE = {
    "01-china-indie-craft.md": [
        "潮汐", "微信读书", "小宇宙", "即刻", "谜底时钟", "OffScreen",
        "CapWords", "flomo", "iDaily", "iMuseum", "有知有行", "滴答清单",
        "格志日记", "轻芒杂志", "谜底黑胶", "Cubox", "锤子便签",
    ],
    "02-china-ai-productivity.md": [
        "豆包", "Kimi", "Manus", "DeepSeek", "秘塔", "飞书", "ima", "语雀", "夸克",
    ],
    "03-mobile-os-systems.md": [
        "OriginOS", "HarmonyOS", "ColorOS", "HyperOS", "iOS 26",
    ],
    "04-international-benchmarks.md": [
        "Bear", "Day One", "Ulysses", "Stoic", "Structured", "Finch",
        "Duolingo", "Headspace", "Endel", "Portal", "Reeder", "Darkroom",
        "Fantastical", "Things 3", "Flighty", "Gentler Streak", "Linear Mobile", "Not Boring",
    ],
}

TIER_TAGS = ("🏆 官方获奖产品", "📐 业内设计参考", "✨ 主观审美与体验推荐")
PET_ANIMS = [
    "idle", "thinking", "working", "notification", "attention",
    "error", "sleeping", "waking", "react-left", "react-right", "tickle",
]


def lin(c: int) -> float:
    s = c / 255.0
    return s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4


def lum(hx: str) -> float:
    h = hx.lstrip("#")
    return 0.2126 * lin(int(h[0:2], 16)) + 0.7152 * lin(int(h[2:4], 16)) + 0.0722 * lin(int(h[4:6], 16))


def contrast(fg: str, bg: str) -> float:
    l1, l2 = lum(fg), lum(bg)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)


def main() -> int:
    errors = []

    for f in REQUIRED_FILES:
        if not f.exists():
            errors.append(f"Missing file: {f}")
        elif f.stat().st_size < 200:
            errors.append(f"File suspiciously small ({f.stat().st_size}B): {f}")

    matrix_text = (DS / "research" / "05-matrix-and-clio-mapping.md").read_text(encoding="utf-8")
    for fname, terms in REQUIRED_COVERAGE.items():
        text = (DS / "research" / fname).read_text(encoding="utf-8")
        if not any(tag in text for tag in TIER_TAGS):
            errors.append(f"Missing tier classification tags in {fname}")
        for term in terms:
            if term not in text:
                errors.append(f"Missing product/OS '{term}' in {fname}")
            if term not in matrix_text:
                errors.append(f"Missing product/OS '{term}' in 05-matrix-and-clio-mapping.md")

    # Tokens + Section 14 motionTiers + Section 15 defaultButtonHaptic + 117 WCAG AA >= 4.5:1 checks
    tokens = json.loads((DS / "specs" / "tokens.v2.json").read_text(encoding="utf-8"))
    for tier in ("instant", "quick", "standard", "expressive"):
        if tier not in tokens.get("motionTiers", {}):
            errors.append(f"Missing motionTier '{tier}' in specs/tokens.v2.json")
    if tokens.get("hapticsPolicy", {}).get("defaultButtonHaptic") != "none":
        errors.append("specs/tokens.v2.json hapticsPolicy.defaultButtonHaptic must be 'none'")

    wcag_checked = 0
    for lang_id in ("AC", "A", "B", "C"):
        lang = tokens["languages"][lang_id]
        color_sets = [("", lang["colors"])]
        for p_id, p_obj in lang.get("palettes", {}).items():
            color_sets.append((f"-{p_id}", {m: p_obj[m] for m in ("light", "dark", "oled")}))
        for p_suffix, modes_dict in color_sets:
            for mode_id, c in modes_dict.items():
                pairs = [
                    ("ink/bg", c["ink"], c["bg"]),
                    ("ink/surface", c["ink"], c["surface"]),
                    ("inkSecondary/surface", c["inkSecondary"], c["surface"]),
                    ("inkTertiary/bg", c["inkTertiary"], c["bg"]),
                    ("inkTertiary/surface", c["inkTertiary"], c["surface"]),
                    ("inkTertiary/surfaceSubtle", c["inkTertiary"], c["surfaceSubtle"]),
                    ("accent/surface", c["accent"], c["surface"]),
                    ("onAccent/accent", c["onAccent"], c["accent"]),
                    ("seal/surfaceSubtle", c["seal"], c["surfaceSubtle"]),
                    ("onSeal/sealFill", c["onSeal"], c["sealFill"]),
                    ("ok/surface", c["ok"], c["surface"]),
                    ("warn/surface", c["warn"], c["surface"]),
                    ("danger/surface", c["danger"], c["surface"]),
                ]
                for label, fg, bg in pairs:
                    ratio = contrast(fg, bg)
                    wcag_checked += 1
                    if ratio < 4.5:
                        errors.append(f"WCAG AA fail {lang_id}{p_suffix}-{mode_id} {label}: {ratio:.2f} < 4.5")

    html = (DS / "prototype" / "index.html").read_text(encoding="utf-8")
    if re.search(r'<(script|link)\b[^>]+https?://', html, re.IGNORECASE):
        errors.append("prototype/index.html contains external HTTP/HTTPS CDN links")

    pet_js = (DS / "prototype" / "pet-sprites.js").read_text(encoding="utf-8")
    for anim in PET_ANIMS:
        if f'"{anim}"' not in pet_js:
            errors.append(f"Missing xiaoke animation '{anim}' in prototype/pet-sprites.js")
    if "CLIO_PET_PACKS" not in pet_js or '"roubao"' not in pet_js:
        errors.append("Missing CLIO_PET_PACKS / roubao bundle in prototype/pet-sprites.js")
    if "data:image/png;base64," not in pet_js:
        errors.append("Missing embedded PNG data URI in prototype/pet-sprites.js")

    tokens_js = (DS / "prototype" / "tokens.js").read_text(encoding="utf-8")
    for req_field in ("defaultTone:", "sharpnessBias:", "motionTiers:"):
        if tokens_js.count(req_field) < 4:
            errors.append(f"prototype/tokens.js missing {req_field} on one or more AC/A/B/C languages")

    for js_file in ("tokens.js", "pet-sprites.js", "app.js"):
        chk = subprocess.run(
            ["node", "--check", str(DS / "prototype" / js_file)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if chk.returncode != 0:
            errors.append(f"node --check failed on prototype/{js_file}: {chk.stderr.strip()}")

    diff_res = subprocess.run(
        ["git", "diff", "--name-only", "--", ":!design/design-system-2.0"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    if diff_res.stdout.strip():
        errors.append(f"Production files outside design/design-system-2.0 modified:\n{diff_res.stdout}")

    if errors:
        print("VERIFICATION FAILED:")
        for e in errors:
            print(f" - {e}")
        return 1

    print(
        f"VERIFICATION PASSED: {len(REQUIRED_FILES)} deliverables/assets present, "
        f"{sum(len(v) for v in REQUIRED_COVERAGE.values())} core + extended benchmarks verified, "
        f"{wcag_checked} WCAG 2.1 AA pairs >= 4.5:1, 11 xiaoke anims embedded, "
        f"all JS syntax clean, 0 tracked files modified."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

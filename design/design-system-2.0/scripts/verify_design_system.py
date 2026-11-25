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
    # Scripts & Prototype v14 (Deliverables 9-10)
    DS / "scripts" / "build_pet_sprites.py",
    DS / "scripts" / "test_prototype_behavior.mjs",
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


def blend_hex(fg_hex: str, bg_hex: str, alpha: float) -> str:
    """Alpha-composite fg over bg in sRGB CSS space."""
    f = fg_hex.lstrip("#")
    b = bg_hex.lstrip("#")
    rgb = [
        round(int(f[i:i+2], 16) * alpha + int(b[i:i+2], 16) * (1.0 - alpha))
        for i in (0, 2, 4)
    ]
    return "#{:02X}{:02X}{:02X}".format(*[max(0, min(255, c)) for c in rgb])


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

                # P2 Real rendered alpha-composited & state checks
                glass_bg = blend_hex(c["surfaceElevated"], c["bg"], 0.76)
                glass_wash = blend_hex(c["surfaceElevated"], c["accentWash"], 0.76)
                taint_bg = blend_hex(c["warn"], c["surface"], 0.13)
                pressed_ink = blend_hex(c["ink"], c["surface"], 0.85)
                pressed_on_accent = blend_hex(c["onAccent"], c["accent"], 0.85)
                composited_pairs = [
                    ("glass76(ink/glassBg)", c["ink"], glass_bg),
                    ("glass76(inkSec/glassBg)", c["inkSecondary"], glass_bg),
                    ("glass76(ink/glassWash)", c["ink"], glass_wash),
                    ("taint13(warn/taintBg)", c["warn"], taint_bg),
                    ("taint13(ink/taintBg)", c["ink"], taint_bg),
                    ("pressed85(ink/surface)", pressed_ink, c["surface"]),
                    ("pressed85(onAccent/accent)", pressed_on_accent, c["accent"]),
                    ("codeBlock(inkSec/codeBg)", c["inkSecondary"], c["codeBg"]),
                    ("myBubble(ink/myBubble)", c["ink"], c["myBubble"]),
                    ("myBubble(inkSec/myBubble)", c["inkSecondary"], c["myBubble"]),
                    ("accentWash(accent/accentWash)", c["accent"], c["accentWash"]),
                    ("stopWash(danger/stopWash)", c["danger"], c["stopWash"]),
                ]
                for label, fg, bg in composited_pairs:
                    ratio = contrast(fg, bg)
                    wcag_checked += 1
                    if ratio < 4.5:
                        errors.append(f"Composited/State AA fail {lang_id}{p_suffix}-{mode_id} {label}: {ratio:.2f} < 4.5")

                if mode_id == "oled":
                    if c["bg"].upper() != "#000000":
                        errors.append(f"OLED bg must be #000000 in {lang_id}{p_suffix}")
                    if not (lum(c["surfaceElevated"]) > lum(c["surface"]) > lum(c["bg"])):
                        errors.append(f"OLED elevation hierarchy fail in {lang_id}{p_suffix}")
                elif mode_id == "dark":
                    if not (lum(c["surfaceElevated"]) > lum(c["surface"]) > lum(c["bg"])):
                        errors.append(f"Dark elevation hierarchy fail in {lang_id}{p_suffix}")

    # P2 Cross-device relative markdown links check (0 file:/// URLs, 0 broken relative targets)
    link_pat = re.compile(r'\]\(([^)]+)\)')
    rel_links_checked = 0
    for md in sorted(DS.rglob("*.md")):
        md_text = md.read_text(encoding="utf-8")
        if "file://" in md_text.lower():
            errors.append(f"Forbidden file:// URL in {md.relative_to(ROOT)}")
        for m in link_pat.finditer(md_text):
            raw_t = m.group(1).strip()
            if raw_t.startswith(("http://", "https://", "mailto:", "#")):
                continue
            rel_path = raw_t.split("#", 1)[0]
            if not rel_path:
                continue
            target = (md.parent / rel_path).resolve()
            rel_links_checked += 1
            if not target.exists():
                errors.append(f"Broken relative markdown link in {md.relative_to(ROOT)}: {raw_t}")

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

    # Verify @font-face bundled App/Fonts/*.ttf references exist on disk
    styles_css = (DS / "prototype" / "styles.css").read_text(encoding="utf-8")
    expected_ttfs = (
        "App/Fonts/ClioKai-Regular.ttf",
        "App/Fonts/ClioKai-Medium.ttf",
        "App/Fonts/MapleMono-Regular.ttf",
        "App/Fonts/MapleMono-SemiBold.ttf",
        "App/Fonts/ClioMonoCN-Regular.ttf",
        "App/Fonts/ClioSeal-Regular.ttf",
    )
    for rel_ttf in expected_ttfs:
        if rel_ttf not in styles_css:
            errors.append(f"prototype/styles.css missing @font-face reference: {rel_ttf}")
        elif not (ROOT / rel_ttf).is_file():
            errors.append(f"Missing real font target on disk: {rel_ttf}")

    # Verify DS 2.0 v2.3.0 structural invariants in tokens.v2.json
    tokens_v2 = json.loads((DS / "specs" / "tokens.v2.json").read_text(encoding="utf-8"))
    if tokens_v2.get("schemaVersion") != "2.3.0":
        errors.append(f"Expected tokens.v2.json schemaVersion 2.3.0, got {tokens_v2.get('schemaVersion')}")
    if tokens_v2.get("streamingReveal", {}).get("planSelected") != "C":
        errors.append("tokens.v2.json streamingReveal.planSelected must be 'C'")
    single_truth = tokens_v2.get("typography", {}).get("fontOpticalCalibration", {}).get("singleTruthSpacing", {})
    if single_truth.get("lineSpacing") != 0 or single_truth.get("maximumLineHeight") != 0:
        errors.append("tokens.v2.json fontOpticalCalibration.singleTruthSpacing must enforce lineSpacing=0 & maximumLineHeight=0")

    # Execute comprehensive Node behavioral regression test suite
    beh = subprocess.run(
        ["node", str(DS / "scripts" / "test_prototype_behavior.mjs")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if beh.returncode != 0:
        errors.append(f"test_prototype_behavior.mjs failed:\n{beh.stdout}\n{beh.stderr}")

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
        f"{wcag_checked} direct + composited/state WCAG 2.1 AA pairs >= 4.5:1, "
        f"{rel_links_checked} repo-relative links verified, "
        f"all JS syntax clean, 0 production files modified."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

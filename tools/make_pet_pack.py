#!/usr/bin/env python3
"""Turn a folder of pet animations into a Clio pet pack (schema 1: pack.json + PNG sprite sheets) and a zip.

Input folder, one animation per state:
    idle.gif  thinking.png(apng)  working/01.png 02.png ...  react-left.gif  idle-yawn.gif ...
Names: idle thinking working notification attention error sleeping waking sweeping carrying roam
       react-left react-right tickle annoyed drag, and idle-<anything> for little idle flourishes.

    python3 tools/make_pet_pack.py design/incoming/pet/scroll-whale --name "书卷鲸鱼" --author "…" --license "…"

Needs Pillow (pip install pillow). Written for Clio; the format matches DSH Go / Clawd on Desk schema 1.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import zipfile

from PIL import Image, ImageSequence

STATES = ["idle", "thinking", "working", "notification", "attention", "error", "sleeping", "waking",
          "sweeping", "carrying", "roam"]
REACTIONS = {"react-left": "tapLeft", "react-right": "tapRight", "tickle": "tickle", "annoyed": "annoyed", "drag": "drag"}
ONCE = {"attention", "error", "waking", "react-left", "react-right", "tickle", "annoyed"}
MAX_SIDE = 4096


def frames_of(path, default_ms):
    """[(RGBA image, ms)] from a GIF / APNG / PNG file or a folder of numbered PNGs."""
    if os.path.isdir(path):
        names = sorted(n for n in os.listdir(path) if n.lower().endswith(".png"))
        return [(Image.open(os.path.join(path, n)).convert("RGBA"), default_ms) for n in names]
    image = Image.open(path)
    out = []
    for frame in ImageSequence.Iterator(image):
        ms = frame.info.get("duration") or default_ms
        out.append((frame.convert("RGBA"), max(20, int(ms))))
    return out


def bbox(images):
    box = None
    for img in images:
        b = img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
        if not b:
            continue
        box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    return box


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("--out", help="output folder (default: <input>-pack)")
    ap.add_argument("--id")
    ap.add_argument("--name")
    ap.add_argument("--author", default="")
    ap.add_argument("--license", default="")
    ap.add_argument("--source", default="")
    ap.add_argument("--ms", type=int, default=100, help="milliseconds per frame when the file does not say")
    ap.add_argument("--smooth", action="store_true", help="hand-drawn art: smooth scaling instead of sharp pixels")
    ap.add_argument("--faces", default="left", choices=["left", "right", "front"], help="which way the roam drawing faces")
    args = ap.parse_args()

    src = args.input.rstrip("/")
    name = args.name or os.path.basename(src)
    pid = args.id or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "pet"
    out = args.out or src + "-pack"
    os.makedirs(out, exist_ok=True)

    anims = {}
    for entry in sorted(os.listdir(src)):
        stem, ext = os.path.splitext(entry)
        full = os.path.join(src, entry)
        if os.path.isdir(full) or ext.lower() in (".gif", ".png", ".apng", ".webp"):
            frames = frames_of(full, args.ms)
            if frames:
                anims[stem.lower()] = frames
    if "idle" not in anims:
        sys.exit("需要一个 idle（空闲）动画")

    # One canvas for everything: the largest frame; smaller ones sit bottom-centre on it.
    cw = max(f.width for fr in anims.values() for f, _ in fr)
    ch = max(f.height for fr in anims.values() for f, _ in fr)
    for key, fr in anims.items():
        placed = []
        for img, ms in fr:
            if img.size != (cw, ch):
                canvas = Image.new("RGBA", (cw, ch))
                canvas.paste(img, ((cw - img.width) // 2, ch - img.height))
                img = canvas
            placed.append((img, ms))
        anims[key] = placed

    content = bbox([img for img, _ in anims["idle"]]) or (0, 0, cw, ch)
    box_of = lambda b: {"x": b[0], "y": b[1], "w": b[2] - b[0], "h": b[3] - b[1]}

    animations = {}
    for key, fr in anims.items():
        b = bbox([img for img, _ in fr]) or (0, 0, cw, ch)
        fw, fh = b[2] - b[0], b[3] - b[1]
        cells, index, frames = [], {}, []
        for img, ms in fr:
            crop = img.crop(b)
            digest = hashlib.sha1(crop.tobytes()).hexdigest()
            if digest not in index:
                index[digest] = len(cells)
                cells.append(crop)
            frames.append({"i": index[digest], "ms": ms})
        cols = max(1, min(len(cells), MAX_SIDE // fw))
        rows = (len(cells) + cols - 1) // cols
        if rows * fh > MAX_SIDE:
            sys.exit(f"「{key}」帧太多或太大，一张图放不下（边长超过 {MAX_SIDE}）")
        sheet = Image.new("RGBA", (cols * fw, rows * fh))
        for n, cell in enumerate(cells):
            sheet.paste(cell, ((n % cols) * fw, (n // cols) * fh))
        file = re.sub(r"[^a-z0-9-]+", "-", key) + ".png"
        sheet.save(os.path.join(out, file), optimize=True)
        animations[key] = {"sheet": file, "frameW": fw, "frameH": fh, "cols": cols, "box": box_of(b),
                           "loop": key not in ONCE and not key.startswith("idle-"), "frames": frames}

    states = {s: [s] for s in STATES if s in animations}
    states.setdefault("idle", ["idle"])
    reactions = {r: k for k, r in REACTIONS.items() if k in animations}
    pool = [{"anim": k, "ms": sum(f["ms"] for f in a["frames"]) * 2, "weight": 1}
            for k, a in animations.items() if k.startswith("idle-")]
    pack = {
        "schema": 1, "id": pid, "name": name, "author": args.author, "license": args.license, "source": args.source,
        "pixelArt": not args.smooth, "scale": 1,
        "canvas": {"w": cw, "h": ch},
        "anchor": {"x": (content[0] + content[2]) / 2, "baseline": content[3]},
        "contentBox": box_of(content),
        "animations": animations, "states": states, "reactions": reactions,
        "idlePool": {"everyMs": {"mean": 120000, "min": 45000, "max": 300000}, "anims": pool},
        "timings": {"minDisplay": {"attention": 3000, "error": 3000, "notification": 2000}, "wakeMs": 1200},
        "sleep": {"afterMs": 60000},
    }
    if "roam" in animations:
        pack["roam"] = {"anim": "roam", "faces": args.faces}
    with open(os.path.join(out, "pack.json"), "w", encoding="utf-8") as f:
        json.dump(pack, f, ensure_ascii=False, indent=1)

    zip_path = out.rstrip("/") + ".zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for n in sorted(os.listdir(out)):
            z.write(os.path.join(out, n), n)
    print(f"做好了：{zip_path}（{len(animations)} 段动画）")


if __name__ == "__main__":
    main()

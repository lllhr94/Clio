#!/usr/bin/env python3
"""把 AI 生成的「像素风」图收拾成真像素图：去背景、对齐到网格、只留调色板里的颜色、脚贴底线。

AI 出的像素风图通常是大图，格子不齐、边缘有抗锯齿、颜色几十上百种。这个工具：
1. 去掉背景（透明背景直接用；纯色背景从四角取色抠掉）。
2. 所有帧共用一个外框，缩到目标画布（默认 32×32），每格取出现最多的颜色，不做插值。
3. 颜色吸附到 Clio 调色板（或用 --palette auto 按原图自己的颜色收成 --colors 种），半透明一律变成全透明或不透明。
4. 去掉轮廓外一圈发虚留下的浅灰毛边（--raw 关掉）。
5. 角色水平居中、脚贴画布底部，所有帧位置一致。
6. 另存一张放大 8 倍的预览，方便看。

用法：
  python3 tools/pixelize.py 输入 输出目录 [--size 32] [--preview 8]
输入可以是一张图、一个装着逐帧 PNG 的文件夹，或一个装着「状态名/逐帧 PNG」的文件夹（整只宠物）。
整只宠物一起处理，保证所有状态大小、位置一致。之后用 tools/make_pet_pack.py 做成宠物包。
需要 Pillow：pip install pillow
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

from PIL import Image

# Clio 像素调色板（与 docs/DESIGN-BRIEF.md 一致）。
PALETTE = [
    "2B2622",  # 墨：轮廓
    "4A423B",  # 深墨
    "7A7068",  # 灰墨
    "B8AEA3",  # 淡墨
    "F4EEE2",  # 纸白
    "E2D8C6",  # 纸影
    "F2C9A0",  # 肤色
    "6F8A4E",  # 月桂
    "4E6638",  # 深月桂
    "4E6A85",  # 黛
    "B5524A",  # 胭
    "D9B36C",  # 缃
    "7FA3D1",  # 鲸蓝
    "5A7DB0",  # 深鲸蓝
]
RGB = [tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) for h in PALETTE]
IMAGE_EXT = {".png", ".gif", ".webp", ".jpg", ".jpeg"}


def nearest(c):
    return min(RGB, key=lambda p: (p[0] - c[0]) ** 2 * 3 + (p[1] - c[1]) ** 2 * 4 + (p[2] - c[2]) ** 2 * 2)


def frames_of(path: Path):
    """一张图（GIF 取每一帧）。"""
    im = Image.open(path)
    out = []
    for i in range(getattr(im, "n_frames", 1)):
        im.seek(i)
        out.append(im.convert("RGBA").copy())
    return out


def drop_background(im: Image.Image, tolerance=40):
    """已经有透明就不动；否则把和四角颜色相近、且与边缘连通的像素抠掉。"""
    px = im.load()
    w, h = im.size
    if any(px[x, y][3] < 128 for x, y in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]):
        return im
    bg = Counter(px[x, y][:3] for x, y in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]).most_common(1)[0][0]
    close = lambda c: sum(abs(a - b) for a, b in zip(c[:3], bg)) <= tolerance
    seen = set()
    stack = [(x, y) for x in range(w) for y in (0, h - 1)] + [(x, y) for y in range(h) for x in (0, w - 1)]
    while stack:
        x, y = stack.pop()
        if (x, y) in seen or not (0 <= x < w and 0 <= y < h) or not close(px[x, y]):
            continue
        seen.add((x, y))
        px[x, y] = (0, 0, 0, 0)
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    return im


def bbox(images):
    boxes = [im.getchannel("A").point(lambda a: 255 if a >= 128 else 0).getbbox() for im in images]
    boxes = [b for b in boxes if b]
    if not boxes:
        sys.exit("所有帧都是空的：背景没抠对，或者图是全透明的。")
    return min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)


def snap(im: Image.Image, box, size):
    """把外框里的内容缩到 size×size 画布里，每格取最多的颜色。"""
    x0, y0, x1, y1 = box
    bw, bh = x1 - x0, y1 - y0
    cell = max(bw, bh) / size  # 每个像素格对应原图多少像素
    gw, gh = max(1, round(bw / cell)), max(1, round(bh / cell))
    src = im.load()
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dst = out.load()
    left, top = (size - gw) // 2, size - gh  # 居中，脚贴底
    for gy in range(gh):
        for gx in range(gw):
            sx0, sy0 = x0 + int(gx * cell), y0 + int(gy * cell)
            sx1, sy1 = max(sx0 + 1, x0 + int((gx + 1) * cell)), max(sy0 + 1, y0 + int((gy + 1) * cell))
            votes = Counter()
            for sy in range(sy0, min(sy1, y1)):
                for sx in range(sx0, min(sx1, x1)):
                    c = src[sx, sy]
                    votes[None if c[3] < 128 else nearest(c)] += 1
            colour = votes.most_common(1)[0][0] if votes else None
            if colour is not None:
                dst[left + gx, top + gy] = colour + (255,)
    return out


def deburr(im: Image.Image):
    """去毛边：贴着透明、又贴着墨线外侧的浅灰像素，是原图发虚留下的，删掉。"""
    px = im.load()
    w, h = im.size
    ink = {RGB[0] + (255,), RGB[1] + (255,)}
    fuzz = {RGB[2] + (255,), RGB[3] + (255,), RGB[5] + (255,)}
    for _ in range(2):
        drop = []
        for y in range(h):
            for x in range(w):
                if px[x, y] not in fuzz:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ox, oy, ix, iy = x - dx, y - dy, x + dx, y + dy
                    out_clear = not (0 <= ox < w and 0 <= oy < h) or px[ox, oy][3] == 0
                    if out_clear and 0 <= ix < w and 0 <= iy < h and px[ix, iy] in ink:
                        drop.append((x, y))
                        break
        for x, y in drop:
            px[x, y] = (0, 0, 0, 0)
    return im


def collect(src: Path):
    """返回 {状态名或空: [帧路径...]}。"""
    if src.is_file():
        return {"": [src]}
    files = sorted(p for p in src.iterdir() if p.suffix.lower() in IMAGE_EXT)
    dirs = sorted(p for p in src.iterdir() if p.is_dir())
    animated = [f for f in files if getattr(Image.open(f), "n_frames", 1) > 1]
    if dirs or animated:
        # 一整只宠物：每个子文件夹是一个状态的逐帧 PNG，或每个动图文件是一个状态。
        groups = {d.name: sorted(p for p in d.iterdir() if p.suffix.lower() in IMAGE_EXT) for d in dirs}
        groups.update({f.stem: [f] for f in files})
        return {k: v for k, v in groups.items() if v}
    return {"": files}  # 一个状态的逐帧 PNG


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--size", type=int, default=32)
    ap.add_argument("--preview", type=int, default=8)
    ap.add_argument("--raw", action="store_true", help="不去毛边")
    ap.add_argument("--palette", choices=["clio", "auto"], default="clio",
                    help="clio：吸到 Clio 调色板；auto：按原图自己的颜色收成 --colors 种")
    ap.add_argument("--colors", type=int, default=16)
    a = ap.parse_args()

    groups = collect(a.src)
    loaded = {k: [f for p in paths for f in frames_of(p)] for k, paths in groups.items()}
    loaded = {k: [drop_background(f) for f in fs] for k, fs in loaded.items()}
    if a.palette == "auto":
        global RGB
        opaque = [c[:3] for fs in loaded.values() for f in fs for c in f.getdata() if c[3] >= 128]
        strip = Image.new("RGB", (len(opaque), 1))
        strip.putdata(opaque)
        flat = strip.quantize(colors=a.colors, method=Image.Quantize.MEDIANCUT).getpalette()[: a.colors * 3]
        RGB = sorted({tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)}, key=sum)
        a.raw = True  # 去毛边只认得 Clio 调色板里的墨色
        print(f"自动调色板：{len(RGB)} 色")
    box = bbox([f for fs in loaded.values() for f in fs])  # 所有状态共用一个外框，大小位置一致

    a.out.mkdir(parents=True, exist_ok=True)
    sheet = []
    for state, frames in loaded.items():
        folder = a.out / state if state else a.out
        folder.mkdir(parents=True, exist_ok=True)
        for i, f in enumerate(frames, 1):
            px = snap(f, box, a.size) if a.raw else deburr(snap(f, box, a.size))
            px.save(folder / f"{i:02d}.png")
            sheet.append(px)
        print(f"{state or '帧'}: {len(frames)} 帧 → {folder}")

    # 预览：所有帧排成一行，放大，垫纸色底。
    cols = min(len(sheet), 8)
    rows = (len(sheet) + cols - 1) // cols
    s, k = a.size, a.preview
    prev = Image.new("RGBA", (cols * s * k, rows * s * k), (0xF4, 0xEE, 0xE2, 255))
    for i, f in enumerate(sheet):
        big = f.resize((s * k, s * k), Image.NEAREST)
        prev.alpha_composite(big, ((i % cols) * s * k, (i // cols) * s * k))
    prev.save(a.out / "preview.png")
    print(f"预览：{a.out / 'preview.png'}")


if __name__ == "__main__":
    main()

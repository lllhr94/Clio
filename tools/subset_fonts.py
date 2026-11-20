#!/usr/bin/env python3
"""把霞鹜文楷、马善政裁小成 App/Fonts/ 里的 Clio Kai（常规、加粗）、Clio Seal（见 App/Fonts/README.md）。

用法：python3 tools/subset_fonts.py LXGWWenKai-Regular.ttf LXGWWenKai-Medium.ttf MaShanZheng-Regular.ttf
需要：pip install fonttools
霞鹜文楷的保留字体名（霞鹜、LXGW 等）不能留在裁小后的字体名里，这里统一改名。
"""
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

OUT = os.path.join(os.path.dirname(__file__), "..", "App", "Fonts")


def simplified():
    """GB2312 全部（简体 6763 字 + 符号）、英文数字、常用全角标点。"""
    chars = set()
    for b1 in range(0xA1, 0xF8):
        for b2 in range(0xA1, 0xFF):
            try:
                chars.add(bytes([b1, b2]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    chars |= {chr(c) for c in range(0x20, 0x7F)}
    chars |= set("，。、；：？！“”‘’（）《》〈〉【】「」『』—…·～　％＋－＝×÷＠＃￥")
    return chars


def make(src, out, family, style, text):
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    font = TTFont(src)
    sub = subset.Subsetter(opts)
    sub.populate(text="".join(sorted(text)))
    sub.subset(font)
    ps = family.replace(" ", "") + "-" + style
    for rec in font["name"].names:
        if rec.nameID in (1, 16):
            rec.string = family
        elif rec.nameID in (2, 17):
            rec.string = style
        elif rec.nameID == 4:
            rec.string = family + ("" if style == "Regular" else " " + style)
        elif rec.nameID == 6:
            rec.string = ps
        elif rec.nameID == 3:
            rec.string = ps + ";subset"
    font.save(out)
    print(out, os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    chars = simplified()
    make(sys.argv[1], os.path.join(OUT, "ClioKai-Regular.ttf"), "Clio Kai", "Regular", chars)
    make(sys.argv[2], os.path.join(OUT, "ClioKai-Medium.ttf"), "Clio Kai", "Medium", chars)
    make(sys.argv[3], os.path.join(OUT, "ClioSeal-Regular.ttf"), "Clio Seal", "Regular", {"克"})

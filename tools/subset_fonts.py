#!/usr/bin/env python3
"""把霞鹜文楷、马善政裁小成 App/Fonts/ 里的 Clio Kai、Clio Seal（见 App/Fonts/README.md）。

用法：python3 tools/subset_fonts.py LXGWWenKai-Medium.ttf MaShanZheng-Regular.ttf
需要：pip install fonttools
霞鹜文楷的保留字体名（霞鹜、LXGW 等）不能留在裁小后的字体名里，这里统一改名。
"""
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

OUT = os.path.join(os.path.dirname(__file__), "..", "App", "Fonts")


def common_chars():
    chars = set()
    for b1 in range(0xB0, 0xD8):  # GB2312 一级常用字
        for b2 in range(0xA1, 0xFF):
            try:
                chars.add(bytes([b1, b2]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    chars |= {chr(c) for c in range(0x20, 0x7F)}
    chars |= set("，。、；：？！“”‘’（）《》〈〉【】「」『』—…·～　％＋－＝×÷＠＃￥")
    return chars


def make(src, out, family, text):
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    font = TTFont(src)
    sub = subset.Subsetter(opts)
    sub.populate(text="".join(sorted(text)))
    sub.subset(font)
    ps = family.replace(" ", "") + "-Regular"
    for rec in font["name"].names:
        if rec.nameID in (1, 4, 16):
            rec.string = family
        elif rec.nameID in (2, 17):
            rec.string = "Regular"
        elif rec.nameID == 6:
            rec.string = ps
        elif rec.nameID == 3:
            rec.string = ps + ";subset"
    font.save(out)
    print(out, os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    make(sys.argv[1], os.path.join(OUT, "ClioKai-Regular.ttf"), "Clio Kai", common_chars())
    make(sys.argv[2], os.path.join(OUT, "ClioSeal-Regular.ttf"), "Clio Seal", {"克"})

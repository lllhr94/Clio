# 字体

两款都是 SIL Open Font License 1.1（OFL）开源字体的**裁小版**，授权全文在同目录的 `OFL-*.txt`。

| 文件 | 来源 | 裁成了什么 |
|---|---|---|
| `ClioKai-Regular.ttf`（字体名 Clio Kai） | 霞鹜文楷 Medium（LXGW WenKai，https://github.com/lxgw/LxgwWenKai） | GB2312 一级常用字 3755 个 + 英文数字 + 常用标点 |
| `ClioSeal-Regular.ttf`（字体名 Clio Seal） | 马善政毛笔楷书（Ma Shan Zheng，https://github.com/google/fonts/tree/main/ofl/mashanzheng） | 只有一个「克」字，朱印用 |

- 霞鹜文楷的授权里「霞鹜」「LXGW」等是保留字体名：裁小后的字体**不能用这些名字**，所以改名 Clio Kai。版权、作者信息照原样保留。
- 用到的地方：题词、引导页和批准单的标题（`Ink.kai`），朱印（`ClioSeal`）。正文不用。
- 重新生成：`python3 tools/subset_fonts.py <霞鹜文楷 Medium.ttf> <马善政.ttf>`。

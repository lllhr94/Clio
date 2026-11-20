# 字体

两款都是 SIL Open Font License 1.1（OFL）开源字体的**裁小版**，授权全文在同目录的 `OFL-*.txt`。

| 文件 | 来源 | 裁成了什么 |
|---|---|---|
| `ClioKai-Regular.ttf`、`ClioKai-Medium.ttf`（字体名 Clio Kai） | 霞鹜文楷 1.530 Regular、Medium（LXGW WenKai，https://github.com/lxgw/LxgwWenKai） | GB2312 全部（简体 6763 字）+ 英文数字 + 常用标点，各约 3.5 MB |
| `ClioSeal-Regular.ttf`（字体名 Clio Seal） | 马善政毛笔楷书（Ma Shan Zheng，https://github.com/google/fonts/tree/main/ofl/mashanzheng） | 只有一个「克」字，朱印用 |

- 霞鹜文楷的授权里「霞鹜」「LXGW」等是保留字体名：裁小后的字体**不能用这些名字**，所以改名 Clio Kai。版权、作者信息照原样保留。
- 用到的地方：「字体」页里可以选它当正文（`Ink.body`）或标题和题词（`Ink.mark`，默认就是它）；朱印（`ClioSeal`）。
- 重新生成：`python3 tools/subset_fonts.py <霞鹜文楷 Regular.ttf> <霞鹜文楷 Medium.ttf> <马善政.ttf>`。

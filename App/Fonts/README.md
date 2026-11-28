# 字体

四款都是 SIL Open Font License 1.1（OFL）开源字体的**裁小版**，授权全文在同目录的 `OFL-*.txt`。

| 文件 | 来源 | 裁成了什么 |
|---|---|---|
| `ClioKai-Medium.ttf`（字体名 Clio Kai） | 霞鹜文楷 GB 1.530 Medium（LXGW WenKai GB，按中国大陆国家标准字形修订的版本，https://github.com/lxgw/LxgwWenkaiGB） | GB2312 全部（简体 6763 字）+ 英文数字 + 常用标点，约 3.5 MB |
| `MapleMono-Regular.ttf`、`MapleMono-SemiBold.ttf` | Maple Mono 7.9（https://github.com/subframe7536/maple-font），从可变字体取出常规、半粗两档 | 只有英文数字符号；去掉了连字（`=>` 不会变成箭头），各约 130 KB |
| `ClioMonoCN-Regular.ttf`（字体名 Clio Mono CN） | Maple Mono CN 的中文底（cn-base，https://github.com/subframe7536/maple-font；汉字来自 Resource Han Rounded，OFL，保留名「Source」未使用），授权见 `OFL-ClioMonoCN.txt` | 只留 GB2312 简体汉字和全角标点（约 5 MB），每个汉字正好两个英文宽；代码、终端里中文跟在 Maple Mono 后面用，列能对齐 |
| `ClioSeal-Regular.ttf`（字体名 Clio Seal） | 马善政毛笔楷书（Ma Shan Zheng，https://github.com/google/fonts/tree/main/ofl/mashanzheng） | GB2312 一级常用字 3755 个（约 3 MB），朱印用：每位旅伴盖自己名字的第一个字；字体里没有的字退回 Clio Kai |

- 霞鹜文楷 GB 的授权里「霞鹜」「LXGW」等是保留字体名：裁小后的字体**不能用这些名字**，所以改名 Clio Kai。版权、作者信息照原样保留。
- Maple Mono 的授权没有保留字体名，沿用原名；中文底裁小后改名 Clio Mono CN，免得和官方 Maple Mono CN 混淆。
- 用到的地方：代码、终端、命令、模型名（`Ink.mono`、`Ink.uiMono`，「字体」页可换回系统等宽）；「字体」页里可以选它当正文（`Ink.body`）或标题和题词（`Ink.mark`，默认就是它）；朱印（`ClioSeal`）。
- 重新生成：`python3 tools/subset_fonts.py <LXGWWenKaiGB-Regular.ttf> <LXGWWenKaiGB-Medium.ttf> <马善政.ttf>`。

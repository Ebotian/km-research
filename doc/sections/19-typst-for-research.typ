== Typst 用于科研文档的最佳实践

本机实测环境：`typst 0.15.1 (9dfd3a08)`（`/usr/bin/typst`，用 `typst --version` 核实于 2026-09-14）；包查找路径 `~/.local/share/typst/packages`、缓存 `~/.cache/typst/packages`，`html`/`bundle`/`a11y-extras` 三个实验特性默认为 off（`typst info` 输出）。官方 0.15.0 发布于 2026-06-15、0.15.1 于 2026-07-17，两个版本条目见 #link("https://typst.app/docs/changelog/0.15.0/")[typst.app changelog]。本机字体 282 项，含 `Noto Sans/Serif CJK SC`、`Source Han Sans/Serif`，中文段落不加任何配置即可编译（实测无 warning），但显式指定字体族可保证排版一致。

=== 项目结构：主文件 + 模板 + 分章

Typst 的多文件机制由模块系统定义：`#include "ch.typ"` 把文件求值为内容并插入，`#import "ch.typ": a, b` 只取定义、返回模块 #link("https://typst.app/docs/reference/scripting/")[typst.app scripting]。本机实测的一条关键差异是：

- `#include` 会把被包含文件里的 `#set` 规则*泄漏*到后续整篇文档（实测：被包含文件设 `#set text(fill: red)` 后，include 之后的正文也变红）。
- `#import` 完全不泄漏（同实验下 include 后出现 13 处红色填充，import 版仅 1 处白色背景）。

因此约定：*分章文件只写内容与局部 `#let`，任何 `#set`/`#show` 一律放模板文件*。推荐的骨架：

```typ
// main.typ
#import "template.typ": conf
#show: conf.with(
  title: [攻击开放问题的算法研究],
  authors: ((name: "…", affiliation: "…", email: "…"),),
  abstract: lorem(80),
)
#include "sections/01-intro.typ"
#include "sections/02-methods.typ"
```

模板本身就是一个函数，用 everything show rule 包住整篇文档，这是官方教程给出的标准「文档类」写法 #link("https://typst.app/docs/tutorial/making-a-template/")[typst.app making-a-template]：

```typ
// template.typ
#let conf(title: [], authors: (), abstract: [], doc) = {
  set page(paper: "a4", numbering: "1", margin: 2.5cm)
  set text(font: ("Libertinus Serif", "Noto Serif CJK SC"), size: 11pt)
  set par(justify: true)
  set heading(numbering: "1.1")
  set math.equation(numbering: "(1)")
  show heading.where(level: 1): set page(header: title)
  doc
}
```

编译命令用 `--root` 固定项目根，路径解析与 `/`-前缀路径都以它为基准；源文件必须落在根内，否则报错（实测 `error: source file must be contained in project root`）。构建侧可让 Typst 自己输出依赖表，便于增量重编译（实测输出 `{"inputs":["refs.bib","main.typ","chapters/ch1.typ"],"outputs":["out.pdf"]}`）：

```bash
typst compile --root . --deps deps.json main.typ out/main.pdf
typst watch  --root . main.typ out/main.pdf
```

本地包（离线复现的推荐做法）：目录布局为 `<package-path>/<namespace>/<name>/<version>/`，配 `typst.toml`（`name`/`version`/`entrypoint`）后用 `TYPST_PACKAGE_PATH` 指向该目录，即可 `#import "@local/mylib:0.1.0": note`。本机用该方式实测编译通过。

=== 数学排版要点

`$...$` 内联、`$ ... $`（两侧留空格）为行内，含换行则为行间公式；`#set math.equation(numbering: "(1)")` 开启公式编号，`<label>` 与 `@label` 建立交叉引用（实测引用渲染为 `Equation (2)`）。本机验证可用的核心构造：

```typ
$ mat(1, 2; 3, 4) quad mat(delim: "[", 1, 0; 0, 1) quad vec(1, 2) $

$ f(n) = cases(
  1 & "if" n = 0,
  n f(n-1) & "otherwise",
) $

$ x &= 1 + 2 \
    &= 3 $
```

- 常用符号：`sum_(i=1)^n`、`integral_0^oo … dif x`、`lim_(n -> oo)`、`sqrt(pi)`、`a\/b`、`in RR`、`cal(A)`、`bb(N)`、`upright(d)`，`&` 控制对齐点（以上均在本机编译通过）。
- 分节编号公式：官方没有「按节重置」的内置开关，需在标题 show rule 里重置 counter，并把编号函数接到 `math.equation.numbering` 上。本机实测脚本输出 `(1.1)`、`(1.2)`、`(2.1)`：

```typ
#set heading(numbering: "1.")
#show heading: it => { counter(math.equation).update(0); it }
#set math.equation(numbering: (..n) => numbering(
  "(1.1)", counter(heading).get().first(), n.pos().first(),
))
```

- 同一写法套到 `figure` 上，本机实测*没有*按节重置：第 2 节首图渲染为 `Figure 2.2`（同刻 `counter(figure).get()` 已回到 `(0,)`，因而编号函数拿到的是 `arguments(2)`）。原因 `UNVERIFIED`，要生成「第 x.y 图」必须实测一遍再定稿。
- 公式清单：`#outline(title: [Equations], target: math.equation)` 可列出全部公式（实测渲染为 `Equation (1)`、`Equation (2)`）。

=== 定理 / 引理环境与编号

Typst *没有*内置定理环境，两条路：用包（`theorion`、`frame-it`，见下节），或用 `figure(kind: …)` 自建。自建时必须绕过两个坑：

- `{ counter.step(); figure(…) }` 这类返回多元素序列的函数，紧随其后的 `<label>` 会绑到序列本身，编译报 `error: cannot reference sequence`；用 `context { … }` 包同样报 `error: cannot reference context`。
- 正解是把 counter 步进放进 `#show figure.where(kind: …)` 里，让「返回单个 figure」成立。本机完整验证通过（自定义渲染 + 独立计数器 + 定理目录 + 交叉引用，输出 `Theorem 1` / `See Theorem 1 and Theorem 2`）：

```typ
#let c = counter("theorem")
#show figure.where(kind: "theorem"): it => {
  c.step()
  block(inset: (left: 1em, top: 0.5em, bottom: 0.5em), stroke: (left: 1.2pt + blue))[
    *Theorem #context c.display().* #h(0.6em) #it.body
  ]
}
#let theorem(body) = figure(kind: "theorem", supplement: [Theorem],
  numbering: "1", outlined: true, caption: none, body)

#outline(title: [Theorems], target: figure.where(kind: "theorem"))
#theorem[There are infinitely many primes.] <thm:euclid>
```

`outlined: true` 让定理进入 `outline`；`supplement` 与 `numbering` 共同决定 `@thm:euclid` 渲染出的文字。定理正文要跨页时给承载块加 `breakable: false`（本机编译通过），避免定理被拦腰截断。

=== 参考文献

`#bibliography` 支持两类文件：Hayagriva `.yaml`/`.yml` 与 BibLaTeX `.bib`，可传数组混用（本机实测 `#bibliography(("refs.bib", "refs.yml"), style: "ieee")` 编译通过，IEEE 风格输出 `[1]`、`[2]`）；默认 `style` 是 `"ieee"`，内置 CSL 样式上百种，含中文国标 `"gb-7714-2015-numeric"`，也可直接给 CSL 文件路径 #link("https://typst.app/docs/reference/model/bibliography/")[typst.app bibliography]。

```typ
We follow @knuth1984 and cite #cite(<lagarias>) explicitly.
This has been proven. @distress[p.~7]
#bibliography(("refs.bib", "refs.yml"), style: "ieee")
```

- `@key` 与 `#cite(<key>)`、`#cite(label("DBLP:books/lib/Knuth86a"))` 等价；`supplement` 用 `@key[p.~7]` 写；`form` 可取 `"normal"`/`"prose"`/`"full"`/`"author"`/`"year"`，设为 `none` 时条目仍进文献表但不显示引用 #link("https://typst.app/docs/reference/model/cite/")[typst.app cite]。
- 默认只列被引用过的条目，`full: true` 列出文件里全部条目。
- Hayagriva YAML 的字段形如 `type`/`title`/`author`/`date`/`page-range`/`serial-number.doi`/`parent`（期刊用 `parent: {type: Periodical, title: …, volume: …, issue: …}`） #link("https://github.com/typst/hayagriva/blob/main/docs/file-format.md")[github hayagriva file-format]；`.bib` 由内置的 hayagriva 库解析，库本身在 crates.io 上为 0.10.1（2026-06-14 更新，`UNVERIFIED`：Typst 0.15.1 具体打包的版本号）。
- 0.15 起单篇文档可含*多份* bibliography（0.15.0 changelog 的 Highlights 之一）；需要更细粒度时另有 `alexandria`（0.2.2）、`citrus`（0.2.1）等包。
- 最常见的报错是 `error: label <key> does not exist in the document`：键不在已加载文件里，或文献文件路径/顺序写错（本机复现）。

=== 交叉引用、图目录、脚注、代码高亮

- 标签与引用：`= Introduction <intro>` 后写 `@intro`；页码引用 `#ref(<intro>, form: "page")`，但必须已 `#set page(numbering: "1")`，否则报 `error: cannot reference without page numbering`（实测）。补充词可用 `@intro[Chapter]` 或 `#show ref.where(form: "normal"): set ref(supplement: it => …)` 统一改写 #link("https://typst.app/docs/reference/model/ref/")[typst.app ref]。
- 图目录 / 表目录：`#outline(title: [List of Figures], target: figure.where(kind: image))`、`target: figure.where(kind: table)`；本机实测二者正确渲染为 `Figure 1 …`、`Table 1 …` 两节 #link("https://typst.app/docs/reference/model/outline/")[typst.app outline]。
- 脚注：`#footnote[内容]` 自动贴到前一个词；`#set footnote(numbering: "*")` 换编号；带标签的脚注可复用（`#footnote[…]<fn>` 与 `@fn`）。官方明确警示：*调用处的 set/show 规则可能不作用于脚注内容*，科研文档里别依赖脚注继承正文样式 #link("https://typst.app/docs/reference/model/footnote/")[typst.app footnote]。
- 代码高亮：三反引号加语言 tag；Typst 语言本身用 `typ`（标记）、`typc`（代码）、`typm`（公式）；`#raw("…", lang: "rust")` 可编程构造；`theme:` 换配色，`#show raw.line: …` 加行号。单反引号只能内联、无法带 tag #link("https://typst.app/docs/reference/text/raw/")[typst.app raw]。本机实测 `typ` 与 `typst` 都能编译通过（官方只承诺 `typ`/`typc`/`typm`，故统一写 `typ`）。
- 0.15 新增 `divider` 元素与 `within` 选择器，写「距上一节」式编号时可少写 counter 手写逻辑（0.15.0 changelog Highlights）。

=== 科研常用包：名字与版本核实

版本来自官方包索引快照 `packages.typst.org/preview/index.json`（2026-09-14 抓取，最新条目更新于 2026-09-11）；索引中的 `compiler` 字段是该包要求的*最低* Typst 版本，本机 0.15.1 满足下列全部。

#table(
  columns: (auto, auto, 1fr),
  [包], [当前版本], [用途与备注],
  [`lilaq`], [0.6.0], [科学绘图主力，导入用 `#import "@preview/lilaq:0.6.0" as lq`，文档在 lilaq.org],
  [`cetz`], [0.5.2], [TikZ 风格绘图，要求 compiler `>=0.14.0`；`cetz-plot` 0.1.4 做函数/数据图],
  [`fletcher`], [0.5.8], [图论 / 箭头图（automata、状态机）],
  [`algorithmic`], [1.0.7], [algorithmicx 风格伪代码，`style-algorithm` + `algorithm-figure` 出浮动算法块],
  [`lovelace`], [0.3.1], [另一种不带观点的伪代码包],
  [`theorion`], [0.6.0], [定理环境，多语言、可重述（restatement）、实验性 HTML 支持],
  [`frame-it`], [2.0.0], [通用 frame 环境（例题/特性/语法块），索引是 2.0.0 而 README 示例仍写 1.2.0，务必显式锁版本],
  [`glossarium`], [0.5.10], [术语表 / 缩写表，`make-glossary` + `register-glossary` + `print-glossary` + `gls`],
  [`drafting`], [0.2.2], [边注 / 行内批注，写 rebuttal 与逐条回复很有用],
  [`zero`], [0.7.0], [科学计数、单位、不确定度与表格数字对齐（`num`、`format-table`）],
  [`codly`], [1.3.0], [代码块行号、跳行、图标；配 `codly-languages` 0.1.10。注意索引为 1.3.0 而 README 写 1.3.1],
  [`subpar`], [0.2.2], [子图（内置无 subfigure）],
  [`equate`], [0.3.3], [公式对齐与「同组多行共用编号」等增强],
)

*表格不要用 `tablex`*：它最后更新停在 0.0.9（2024-10-25），作者在包页首行写明「请改用 Typst 内置表格」，per-cell 定制、合并单元格、可重复表头等特性已在 Typst 0.11 上游化，官方另有 #link("https://typst.app/docs/guides/tables/")[Table Guide]。`physica`（0.9.8）只在写物理量符号时才需要。

=== 本机 CLI：版本与常用参数

`typst 0.15.1` 的子命令为 `compile`(c)、`watch`(w)、`init`、`eval`、`fonts`、`completions`、`info`、`help`；`watch` 与 `compile` 参数集基本一致。

#table(
  columns: (auto, 1fr),
  [参数], [说明 / 实测结论],
  [`-f, --format`], [`pdf`/`png`/`svg`/`html`/`bundle`，默认按输出扩展名推断；写 `-` 输出到 stdout 时*必须*显式给 `-f`],
  [`--root`], [项目根，决定绝对路径解析；超出根报 `source file must be contained in project root`],
  [`--input k=v`], [字符串键值进 `sys.inputs`；实测 `typst eval 'sys.inputs' --input a=b` 输出 `{"a":"b"}`，适合模板参数化],
  [`--font-path`], [额外字体目录，可多路径；对应环境变量 `TYPST_FONT_PATHS`],
  [`--package-path`], [本地包目录，对应 `TYPST_PACKAGE_PATH`；配合 `typst.toml` 使用 `@local/...` 导入],
  [`--deps` / `--deps-format`], [输出本次编译依赖（`json`/`zero`/`make`），供构建工具做增量；不能与 stdout 输出同时用],
  [`--diagnostic-format short`], [机读诊断，实测输出 `e2.typ:4:8: error: unknown variable: y`，最适合插件解析],
  [`--pdf-standard`], [可叠加 `a-2b`、`a-3b`、`ua-1` 等做归档/无障碍投递],
  [`--creation-timestamp`], [固定 PDF 创建时间（等价 `SOURCE_DATE_EPOCH`），做可复现构建],
  [`--features`], [启用实验特性 `html`、`bundle`、`a11y-extras`；本机默认全 off],
  [`--pages` / `--ppi` / `--jobs`], [按页导出、PNG 分辨率（默认 144）、并行度],
  [`--timings` / `--open`], [导出 perfetto 可视化耗时；编译后用默认查看器打开],
)

结构化查询：`typst query` 已弃用，实测会警告 `the "typst query" subcommand is deprecated`，替代写法是 `typst eval 'query(<label>)' --in file.typ`（本机返回 JSON 数组，可用来抽取定理、公式、benchmark 表等）。

=== 常见编译错误与排查

#table(
  columns: (1fr, 1fr),
  [报错信息（触发条件）], [处理],
  [`file not found (searched at …)`：路径写错，且路径相对*当前文件*而非项目根], [用 `--root` 固定根，全项目统一写相对根路径],
  [`source file must be contained in project root`：入口文件在 `--root` 之外], [把入口移进根，或改 `--root`],
  [`unknown variable: y`：拼写错误 / 忘了 `#let`], [用 `--diagnostic-format short` 拿行列号],
  [`unresolved import`：`#import` 了模块里不存在的名字], [检查导出名；被导入的模块要用 `#let` 导出],
  [`cyclic import`：两个文件互相 include/import], [改成单向包含，公共部分下沉到独立模块],
  [`label <x> does not exist in the document`：`@x` 无对应 `<x>`，或 `@key` 不在已加载的 bib 里], [补 label / 把 bib 文件加进 `#bibliography` 的 sources 数组],
  [`cannot reference sequence` / `cannot reference context`：`<label>` 落在函数返回的多元素序列上], [让函数只返回单个元素；counter 步进放进 show rule],
  [`cannot reference without page numbering`：用了 `#ref(<x>, form: "page")` 但没设 `#set page(numbering:)`], [补页码设置；HTML 导出下同样报错],
  [`the document does not contain a bibliography`：先 `#cite` 却没有 `#bibliography`], [文档里至少放一处 `#bibliography`],
  [`package not found (searched for @preview/…:…)`：包名或版本写错，或离线], [锁版本；离线场景改 `@local` + `TYPST_PACKAGE_PATH`],
  [`unclosed delimiter`：`$` 或括号不配对], [成对检查 `$`、`(`、`[`],
  [`warning: unknown font family`：字体族名写错（仅警告，会静默回退）], [用 `typst fonts` 核对族名],
  [`outline is not allowed at the top-level in bundle export`：bundle 导出对顶层元素有限制], [非必须不要用 `--features bundle`],
)

排查顺序建议：先 `--diagnostic-format short` 拿到机读行列；再用 `typst eval 'query(...)' --in file.typ` 做无渲染探针；怀疑环境时用 `typst info` 看特性开关与包路径、`typst fonts` 看字体；编译慢用 `--timings` 出火焰图。HTML 导出本机可用（`typst compile --features html h.typ h.html -f html` 实测产出合法 HTML），但会提示 `html export is under active development and incomplete`，不要用于交付。

=== 评估

- *抄*：「模板函数 + 分章片段」结构。插件生成的章节文件只允许 `== `/`=== `/`- ` 列表与局部 `#let`，把 `#set`/`#show` 全部收进 `template.typ`，主文件用 `#import` + `#show: conf.with(...)` 应用。理由是本机实测 `#include` 会泄漏 set 规则、`#import` 不会——生成器一旦往章节里塞 `#set`，后续所有章节的排版会被静默污染。
- *抄*：插件内部的编译与反馈循环用 `typst compile --diagnostic-format short` 取 `file:line:col: error: msg`，用 `--deps json` 做依赖缓存；需要读回文档结构（定理清单、公式清单、benchmark 表）时用 `typst eval 'query(<label>)' --in doc.typ` 而不是已弃用的 `typst query`。
- *抄*：把 `lilaq`/`cetz`/`algorithmic`/`glossarium` 以写死版本 vendored 进插件目录，通过 `TYPST_PACKAGE_PATH` + `@local/<name>:<ver>` 导入（本机已实测该路径可用）。这样离线可编译、版本可复现，也不会写用户的 `~/.cache/typst/packages`。README 与包索引版本常不一致（`frame-it` 2.0.0 vs README 1.2.0、`codly` 1.3.0 vs README 1.3.1），所以一律以 `packages.typst.org/preview/index.json` 为准并显式锁版本。
- *抄*：定理类环境一律用「单个 `figure` 返回 + `#show figure.where(kind: …)` 内 step counter」的写法（本机已验证可同时得到自定义渲染、独立计数器、定理目录与交叉引用），把「函数返回序列 → `<label>` 报 `cannot reference sequence`」这个坑写进 skill 的检查清单。
- *避免*：`tablex` 作为表格默认方案（作者已建议改用内置 `table`，最后更新停在 2024-10-25）；也避免把 HTML/bundle 导出当交付路径（本机 `typst info` 显示二者为 off 的实验特性，且 `--features html` 下 `#ref(form: "page")` 直接报错）。
- *避免*：照抄跨节编号写法而不做一次编译验证。`math.equation` 的「标题处重置 counter」本机实测生效（`(1.1)`/`(1.2)`/`(2.1)`），但同一写法套到 `figure` 上实测得到 `Figure 2.2`（非 2.1），原因 `UNVERIFIED`；凡涉及「第 x.y 图/表」的生成逻辑，插件必须先编译一次并把结果回读再报告成功。

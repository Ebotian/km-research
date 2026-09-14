== 猜想/反例管理、笔记本与可读报告

本节回答：研究者现在实际用什么载体管理猜想与反例；「猜想台账」的字段从哪里来；literate programming 与可执行论文的现状；实验产物如何变成 Typst 里的表与图；以及 Formal Conjectures / Erdős Problems 两个先例能给出什么可复用的数据模型。凡未标注「推断」的陈述均来自官方文档、公开仓库或论文原文；本机工具链数字为 2026-09-14 于本机实测（`typst 0.15.1`、`python3 3.14.6`、`node v26.7.0`、`julia 1.12.6`、`.elan` 下的 `lean`/`lake`（Lean 4.33.1，Lake 5.0.0-src）、`pdflatex`、`pandoc 3.6.1`、`git` 可用；`z3`/`cvc5`/`sage`/`gap`/`gp`/`cargo` 均不存在；`nproc` = 12）。

=== 研究者实际在用的载体

对每个载体，下表给出「一手证据」与「对本插件的含义」。

#table(
  columns: 2,
  [*载体*], [*一手证据（要点）→ 对本插件的含义*],
  [Lean 文件 + 仓库],
  [formal-conjectures 每条猜想一个 `.lean` 文件、一句 `theorem … := by sorry`，元数据靠 Lean *属性*而非外部表；目录按来源分（`ErdosProblems/`、`Wikipedia/`…）；`FormalConjecturesUtil` 提供属性与 linter（#link("https://github.com/google-deepmind/formal-conjectures/blob/main/CONTRIBUTING.md")[CONTRIBUTING]）。→ 「声明即数据」，插件应对 `.lean` 文件做机械校验，而不是维护一份平行表。],
  [Blueprint（leanblueprint）],
  [`\lean`、`\leanok`、`\uses`、`\notready`、`\mathlibok`、`\discussion`、`\proves` 七类宏把 TeX 叙述绑到 Lean 声明；依赖图节点默认着色为 `stated`/`can_state`/`not_ready`/`proved`/`can_prove`/`defined`/`fully_proved`/`mathlib`；`leanblueprint checkdecls` 校验文中 Lean 名确实存在（#link("https://github.com/PatrickMassot/leanblueprint")[仓库]）。→ 「形式化状态」是首类字段，可可视化、可校验，台账字段应能直接喂给这样一张状态图。],
  [自建结构化数据库],
  [teorth/erdosproblems 以 `data/problems.yaml` 为唯一真源，配 `schema/problems.schema.json`（JSON Schema）、`scripts/validate.py` 与 CI；README 表与进度 SVG 由 `scripts/generate_readme.py` 生成，明令禁止手改（#link("https://github.com/teorth/erdosproblems")[仓库]）。→ 这是与「本地插件」最接近的形态：YAML/JSON + schema + 生成脚本 + 校验钩子，全部可离线跑。],
  [Jupyter / Jupytext],
  [`.ipynb` 是 JSON、按 cell 顺序执行；Jupytext 把 notebook 与 `py:percent` 的 `.py` 或 Markdown 文本配对（`jupytext.toml` 里 `formats = "ipynb,py:percent"`），`jupytext --sync` 双向同步，`.py` 进版本控制、`.ipynb` 只留本地输出（#link("https://github.com/mwouts/jupytext")[README]）。→ 科研里真正被 Git 管理的是文本版，插件读写实验记录应优先文本/JSON。],
  [Quarto],
  [以花括号语言名（如 `{python}`）标注的代码块在 render 时执行；`execute: cache`/`freeze` 可避免重跑长计算；`format: typst` 生成 PDF，`keep-typ: true` 保留中间 `.typ`，`{=typst}` 原始块可直写 Typst，`quarto typst compile` 独立编译（#link("https://quarto.org/docs/computations/python.html")[执行] #link("https://quarto.org/docs/output-formats/typst.html")[Typst 输出]）。→ 「跑实验 + 出 PDF」是成熟路径，代价是要装 Quarto；插件可复刻其缓存/冻结语义。],
  [marimo / Pluto.jl],
  [两者都以「响应式 + 无隐藏状态」为卖点：marimo notebook 存为纯 `.py`、确定性执行、可 `pytest` 跑；Pluto 声明「任一时刻程序状态完全由你看到的代码描述」，并内置包管理（#link("https://docs.marimo.io/")[marimo] #link("https://plutojl.org/")[Pluto]）。→ 实验记录不能只存输出快照。],
  [org-mode + Babel],
  [`#+begin_src julia :results value`、`:session`、`:tangle`、Noweb `<<block>>`、`#+TBLFM` 表格公式；表格可作为代码输入、代码输出可回落为 Org 表；官方导论直接以 Knuth 的 literate programming（weave/tangle）与 Donoho 的可复现研究立纲（#link("https://orgmode.org/worg/org-contrib/babel/intro.html")[Babel 导论]）。→ 「表 → 代码 → 表」正好对应参数表驱动批量实验、结果回填。],
  [Mathematica / Wolfram],
  [`.nb` 自 1988 年即为「基于 Wolfram 语言表达式语法的 ASCII 格式」，`Import["f.nb","Plaintext"]` 可取纯文本；第三方 WLJS Notebook 以「极小明文 notebook、易 diff、可被 LLM 解析、内建 MCP server」为卖点（#link("https://reference.wolfram.com/language/ref/format/NB.html")[NB 格式] #link("https://wljs.io/")[WLJS]）。→ 台账文件应对 diff 友好：一题一文件，避免单一大文件。],
  [wiki 型问题库],
  [Open Problem Garden 用 `Area » Topic » Subtopic` 三级分类加 Authors/Keywords 与 RSS，条目靠 wiki 页维护（#link("https://www.openproblemgarden.org/structure")[结构说明]）。→ 字段不可机检，只值得借它的分类维度。],
)

三条跨载体的共同实践（一手）：

- *单一真源 + 生成物*：erdosproblems 的 README 表、进度图、`formalized` 字段全部脚本生成，直接手改会 PR 校验失败。
- *反例是一等公民*：erdosproblems 状态枚举里 `disproved` 与 `proved` 并列；bbchallenge 的 BB(5) 结论以 Coq 证明「没有更长的停机机」这种否定式结论收尾。#link("https://wiki.bbchallenge.org/wiki/BB(5)")[BusyBeaverWiki]
- *猜想库不装长证明*：formal-conjectures 明文规定「超过 25–50 行的证明不要放进本仓库」，用 `formal_proof` 属性外链。

=== 「猜想台账」应有的字段

以下字段草案以 erdosproblems 的 JSON Schema 与 formal-conjectures 的属性为骨架（一手），加两处本项目需要的扩展（标注「推断」）。

#table(
  columns: 2,
  [*字段*], [*语义 → 出处*],
  [`id` / `number`], [稳定标识（字符串）。→ erdosproblems 要求 `number` 为 string，正则 `^[0-9\-]+$`],
  [`statement`], [自然语言陈述；英文问句用 `answer(sorry)` 形式形式化。→ formal-conjectures 风格指南],
  [`source`], [来源类型（论文/题集/wiki/OEIS）+ URL + 取回日期。→ formal-conjectures 用 `FormalConjectures/<Source>/` 目录编码来源；erdosproblems 在每个文件内标 URL],
  [`informal_status`], [状态 + 更新日期 + 备注，*忽略形式化*。→ erdosproblems schema，`$comment` 原文「ignoring formalization」],
  [`formal_statement`], [*陈述*是否已形式化、位于何处。→ erdosproblems `formalized` 字段，由 `scripts/update_formalization_status.py` 从 formal-conjectures 自动同步],
  [`formal_solution`], [*解答*是否已在证明助手中验证（含 `url`/`note`）。→ erdosproblems `formal_status`，取值 `unformalized`/`Lean`],
  [`status`], [由上面两者派生，形如 `disproved (Lean)`，禁止手改。→ erdosproblems `status` 字段 + `scripts/derive_status.py`],
  [`tags` / `ams`], [学科标签 / MSC2020 主学科号。→ erdosproblems `tags`；formal-conjectures 每条陈述至少一个 `@[AMS n]`],
  [`verified_range`], [「已测试范围」：覆盖区间、方法、产物。→ *推断*（见下文缺口）],
  [`known_bounds`], [已知最好上/下界及其出处。→ *推断*],
  [`counterexamples`], [反例列表（取值、发现者、日期、产物）。→ *推断*],
  [`provenance`], [作者、是否 AI 参与、是否人工复核。→ erdosproblems CONTRIBUTING 的 AI 条款、OEIS 禁止 AI 提交],
)

*缺口*（这是本插件最该补的一环）：erdosproblems 的 schema 只有 `informal_status`、`formal_status`、`status`、`oeis`、`formalized`、`comments`、`tags`、`prize`，*没有*边界、已验证范围、反例的结构化字段，且 CONTRIBUTING 明确要求「当前技术状态、搜索界、文献」放到站点评论页而非数据文件。也就是说，社区库刻意只做「状态台账」，把范围证据留在散文里。对本插件而言，范围与界恰好是最可机检的部分，应当结构化。

状态枚举（一手，逐字取自 erdosproblems）：`open`、`proved`、`disproved`、`solved`、`falsifiable`（若假可由有限反例否证）、`verifiable`（若真可由有限验证证明）、`decidable`（两者兼有但未解）、`not provable`、`not disprovable`、`independent`。后三者覆盖 ZFC 独立性。`falsifiable`/`verifiable`/`decidable` 这三个正是「反例搜索 / 证明搜索」的可计算性刻画，对算法型插件价值最高。

验证范围的公开先例（可作报告的引用锚点）：

#table(
  columns: 2,
  [*结论*], [*来源*],
  [三元 Goldbach 猜想验证到 $8.875 times 10^30$], [#link("https://arxiv.org/abs/1305.3062")[Platt, arXiv:1305.3062]],
  [Riemann 假设用区间算术验证到高度 $3 times 10^{12}$], [#link("https://arxiv.org/abs/2004.09765")[Platt–Trudgian, arXiv:2004.09765]],
  [BB(5) = 47,176,870，2024 年由 bbchallenge 合作证明，Coq 验证], [#link("https://arxiv.org/abs/2509.12337")[arXiv:2509.12337] #link("https://github.com/ccz181078/Coq-BB5")[Coq-BB5]],
  [Boolean Pythagorean Triples 不可二着色：DRAT 证明约 200 TB，压缩证书 68 GB], [#link("https://arxiv.org/abs/1605.00723")[Heule 等, arXiv:1605.00723]],
  [Erdős 库规模：1217 题；334 proved / 139 disproved / 101 solved / 591 completely open；298 题有 Lean 形式化解], [同上 erdosproblems 仓库 README 生成表],
)

最后一行说明一个实践要点：*大规模搜索的产物本身是「证书」，不是「日志」*。200 TB→68 GB 的压缩证书、Coq 脚本，都是可以独立重放的 artifact —— 插件的实验记录必须能指向这种可重放产物。

=== literate programming 与可执行论文

- Knuth 的 weave/tangle 是这条线的起点，org-babel 与 Quarto 都直接继承：文档叙述与可执行代码同处一文件，导出时「织」出报告、「缠」出代码。#link("https://orgmode.org/worg/org-contrib/babel/intro.html")[Babel 导论]
- Quarto 的 Typst 输出是目前「Markdown 前端 + Typst 排版」最省事的组合：`format: typst`、`keep-typ: true` 保留中间 `.typ`、`{=typst}` 原始块直写 Typst、`quarto typst compile` 单独编译；`execute.cache`/`freeze` 控制重跑。#link("https://quarto.org/docs/output-formats/typst.html")[来源]
- 证明助手一侧，Lean 官方文档工具 Verso 支持「literate facet」：`lake build MyLib:literate` 产出 `.lake/build/literate`，再 `lake exe verso-html … html` 生成 HTML；docstring/moduledoc 在源码内（`doc.verso := true`）即被渲染，且证明状态可内嵌显示、跨文档引用走 `xref.json`。#link("https://github.com/leanprover/verso")[Verso]
- blueprint 一侧则是「先写蓝图、再补形式化」：`\uses` 生成依赖图，`\leanok` 标注已形式化，`\notready` 标注尚未准备好形式化 —— 这份状态机可直接映射成插件台账的枚举。
- 反模式提醒（一手佐证）：marimo 与 Pluto 都把「消除隐藏状态、确定性执行顺序」写进首要卖点，Pluto 甚至说「不像 Jupyter 或 Matlab，没有可变 workspace」。因此报告的可信度应来自可重放的 artifact 与确定性执行，而不是 notebook 里遗留的输出。

=== 从实验产物自动生成表格与图

Typst 内置了数据读取，实验侧只要产出 CSV/JSON/YAML 即可：#link("https://typst.app/docs/reference/data-loading/")[data-loading 文档] 列出 `cbor`、`csv`、`json`、`read`、`toml`、`xml`、`yaml`。以下片段已在本机 `typst 0.15.1` 实际编译通过（`csv` 的 `row-type: dictionary` 让每行变字典；`yaml()`/`json()` 直接取字段；注意 Typst 的 `array.map` 只接受单参数，需要索引时用 `enumerate()`）：

```typst
#let rows = csv("results.csv", row-type: dictionary)
#table(
  columns: 4,
  [*case*], [*bound*], [*time (s)*], [*status*],
  ..rows.map(r => ([#r.case], [#r.bound], [#r.seconds], [#r.status])).flatten(),
)

#let c = json("conjectures/erdos-17.json")
#c.id, #c.informal_status.state

#let d = yaml("conjectures/erdos-17.yaml")
#table(columns: 2, ..d.tags.enumerate().map(((i, t)) => ([#i], [#t])).flatten())
```

绘图与画布：

- lilaq 0.6.0（`#import "@preview/lilaq:0.6.0" as lq`）自带文本加载模块：`src/loading/txt.typ` 导出的 `load-txt(data, delimiter: ",", comments: "#", skip-rows: 0, usecols: auto, header: false, converters: float)` 接收 `read()` 读入的字符串，*按列*返回数组；`header: true` 时返回以表头为键的字典，`converters` 默认把值转成 `float`，可指定单列转换器或 `rest` 兜底。#link("https://raw.githubusercontent.com/lilaq-project/lilaq/main/src/loading/txt.typ")[源码] #link("https://typst.app/universe/package/lilaq/")[Universe 页]
- cetz 0.5.2 负责画布/示意图，cetz-plot 0.1.4 在其上提供 `plot` 与 `chart`（饼图、堆叠柱、金字塔等）。#link("https://typst.app/universe/package/cetz/")[cetz] #link("https://typst.app/universe/package/cetz-plot/")[cetz-plot]
- *不要*再用 tablex：其 Universe 页首行即「Please use built-in Typst tables instead of tablex」，强调自 Typst 0.11.0 起大部分能力（逐单元格定制、合并、`table.hline`/`table.vline`、可重复表头）已上游进内置 `table`/`grid`。#link("https://typst.app/universe/package/tablex/")[来源]
- 数值精度要写进报告元数据：erdosproblems 的 CONTRIBUTING 专门警告 OEIS 的 `cons`（十进制展开）条目按*截断*存储，而 `mpmath.nstr`、f-string、`format` 默认四舍五入，会翻转末位数字并造成「静默假阴性」，因此他们提供 `scripts/oeis_cons_compare.py` 统一截断。#link("https://github.com/teorth/erdosproblems/blob/main/CONTRIBUTING.md")[CONTRIBUTING]
- 流程建议（推断）：实验进程只写结构化产物（CSV/JSON + 一段命令 + 环境信息），Typst 只做读取与排版；报告随时可整篇重渲染，绝不依赖 notebook 的历史输出。

=== 已有先例：Formal Conjectures 与 Erdős Problems 的元数据

*Formal Conjectures*（一手，来自 CONTRIBUTING 与生成站点）：

- 每条陈述恰有一个分类：`@[category research open]`、`research solved`、`textbook`、`API`、`test`。
- 每条陈述至少一个 `@[AMS 11]`、`@[AMS 5 11]` 形式的 MSC2020 主学科。
- 解答的形式化位置用独立属性记：`@[formal_proof using formal_conjectures|lean4|other_system at "link"]`，与分类正交（可 `research solved` 但 `unformalized`，也可 `research open` 却已有 Lean 形式化解 —— 后者正是「机器已验证但人还没消化」）。
- 需要用户填答案的开放问句写成 `answer(sorry)`，解决后替换为 `answer(True)`/`answer(False)`。
- 目录即来源维度；benchmark 快照用不可变 tag `bench-v{N}-lean4.{X}.{Y}`，`v{N}` 在任何题增删或误形式化修正时递增，修正只进 `v{N+1}`、不回填旧快照。
- 站点 `#link("https://google-deepmind.github.io/formal-conjectures/")[formal-conjectures]` 直接按来源与学科汇总计数（如 Erdős Problems 671 个文件 / 2064 条陈述；OEIS 227 / 1530；Wikipedia 147 / 672），说明属性足以自动生成索引页。

*Erdős Problems 数据库*（一手，来自 schema 与 CONTRIBUTING）：

- 唯一真源是单个 YAML；`status` 是派生字段（`<informal>` + 若有形式化解则追加 ` (Lean)`），由 `scripts/derive_status.py` 在每次 push 时重算，手改会令 PR 校验失败。
- *陈述*形式化与*解答*形式化是两个独立字段，前者由外部仓库变动自动同步，后者含可选 `url` 与 `note`。
- `oeis` 字段除序列号外允许 `possible`、`submitted`、`in progress`、`N/A` 标记，把「还没算出来/正在算」这类中间态也写进数据。
- `comments` 只放短标签（如 `ambiguous statement`、`literature review sought`），禁止散文。
- AI 政策可操作：AI 生成的代码必须独立核验、建议「先让 AI 做简化版、人工看懂后再自己改到完整版」、禁止让 LLM 直接生成序列，且 OEIS 明文禁止 AI 提交。
- 另一个可借鉴的「自动发现猜想」先例：Ramanujan Machine 把算法产出的公式当猜想公开发布、征集证明。#link("https://www.ramanujanmachine.com/")[官网]

=== 对本插件数据模型的具体建议

目录与职责分离（推断，但沿用上述先例的分工）：`data/conjectures/<id>.json` 一题一文件（diff 友好，对应 `FormalConjectures/<Source>/<id>.lean` 的粒度）；`data/experiments/<exp-id>.json` 一次实验一文件；`artifacts/<exp-id>/` 存 CSV/JSON/证书；`report/` 存 Typst 片段，只读数据、不写数据。

`conjecture.json` 草案：

```json
{
  "id": "erdos-17",
  "statement": { "informal": "cluster primes …", "latex": "…" },
  "source": { "kind": "problem-list", "url": "https://www.erdosproblems.com/17", "retrieved": "2026-09-14" },
  "tags": ["number theory", "primes"],
  "ams": [11],
  "informal_status": { "state": "open", "last_update": "2026-09-14", "note": "" },
  "formal_statement": { "state": "yes", "system": "lean4", "url": "…" },
  "formal_solution": { "state": "unformalized", "system": null, "url": null },
  "status": "open",
  "verified_range": { "lo": 2, "hi": 1000000000, "method": "brute-force", "artifact": "artifacts/exp-2026-09-14-a/" },
  "known_bounds": { "upper": null, "lower": null, "source": null },
  "counterexamples": [],
  "experiments": ["exp-2026-09-14-a"],
  "provenance": { "author": "human", "ai_assisted": false, "human_reviewed": true }
}
```

`experiment.json` 草案（关键是把「方法、范围、工具、环境、可重放命令」写全，否则数字无法复现）：

```json
{
  "id": "exp-2026-09-14-a",
  "conjecture_id": "erdos-17",
  "question": "是否存在 n ≤ 1e9 的反例",
  "method": "brute-force",
  "tool": { "name": "python3", "version": "3.14.6" },
  "command": ["python3", "scripts/search.py", "--bound", "1e9", "--seed", "1"],
  "range": { "lo": 2, "hi": 1000000000, "covered": true, "exhaustive": true },
  "environment": { "host": "local", "cores": 12, "wall_seconds": 4312.7 },
  "result": { "status": "no-counterexample", "witness": null },
  "artifacts": [ { "path": "artifacts/exp-2026-09-14-a/hits.csv", "bytes": 18342 } ],
  "replay": "make exp-2026-09-14-a",
  "provenance": { "author": "agent", "model": "…", "human_reviewed": false }
}
```

落地注意（推断 + 本机实测）：

- 派生字段一律由脚本生成：`status`、`formal_statement.state`（可从 Lean 文件里搜 `sorry`/属性得出）、以及所有 Markdown/Typst 索引页 —— 复制 erdosproblems 的「生成物禁止手改 + PR 校验」纪律。
- 每个 artifact 记录路径、字节数与 `sha256`；`replay` 必须是一条能直接跑的命令。本机已无 `z3`/`cvc5`/`sage`/`gap`/`pari`/`cargo`，SAT/SMT 与 Coq 路径不可默认可用；`lean`+`lake`、`julia`、`python3`、`node`、`typst`、`pandoc`、`pdflatex` 可用 —— 台账里不写清「哪台机器、哪个求解器版本、几个核」，实验结论就没有复现价值。
- MCP server 侧建议暴露最小工具集：`conjecture.upsert`、`conjecture.query`（按 status/tag/来源过滤）、`experiment.record`、`experiment.replay`、`report.render`（Typst → PDF）。
- hooks 侧在写入 `data/conjectures/`、`data/experiments/` 之后跑一次 JSON Schema 校验 + 派生字段重算，等价于 erdosproblems 的 `scripts/validate.py` + `derive_status.py`。
- 插件清单文件名以本机实际加载的为准：本机 `~/.kimi-code/plugins/managed/` 下各插件用的是插件根目录的 `kimi.plugin.json`（字段 `name`/`version`/`description`/`keywords`/`mcpServers`/`interface`），与本项目计划的 `<plugin>/.kimi-plugin/plugin.json` 不同，实现时需确认加载器认哪一种。

=== 评估

- *抄*：把「非形式化状态」与「形式化状态」拆成两个独立字段再派生 `status` —— erdosproblems 用同一机制表达出 `open (Lean)`（机器已证、人未消化）这种关键中间态，单枚举写不出这个语义。
- *抄*：一题一文件 + 属性/字段即元数据 + 索引页与统计脚本生成且禁止手改（formal-conjectures 的 `@[category]`/`@[AMS]`/`@[formal_proof]`，erdosproblems 的 YAML→README 表 + 进度 SVG）；本插件的「猜想台账视图」应当是生成物而非人工维护的第二份真源。
- *抄*：`verified_range` / `known_bounds` / `counterexamples` 三个结构化子对象，并把 `falsifiable`/`verifiable`/`decidable` 这类可计算性状态写进枚举 —— 这正是算法插件的主战场，而 erdosproblems 恰好留空。
- *抄*：实验记录强制携带「工具名+版本、范围、核数、耗时、可重放命令、artifact 校验和」，并在疑似反例上要求独立核验后再改状态（erdosproblems 的 AI 条款、OEIS 禁 AI 提交）。
- *避免*：在 Typst 里跑计算或依赖会过期的第三方表格包 —— 报告只读 CSV/JSON/YAML；内置 `table` 已够用，tablex 官方页明确让人改用内置表格。
- *避免*：把 notebook 的输出当作证据。marimo/Pluto 以「无隐藏状态、确定性执行」为卖点恰好说明这是公认的缺陷；报告必须能从 artifact 整篇重渲染。

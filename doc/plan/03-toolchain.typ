= 工具链与组合契约

#text(size: 10pt, fill: luma(90))[
  同步状态（截至插件 `0.6.0`）：`M0`–`M4` 已交付并有回归覆盖（`M4` = `opl-evolve-*` 四个命令加 `opl-evolve` 技能），
  `M5`（`opl-stat` 与 `opl-benchmark` 技能）和 `M6`（`opl-report`）未开始；命令 12 个、技能 5 个，
  与原定的 13 个命令并不重合（差异见「命令清单」）。实现中还长出五处原计划没有的机制：
  签名层（`opl-sign`：记录内嵌签名、证据旁挂 `<path>.sig`）、台账的事务式整笔校验（不自洽就一个字段都不写）、
  评估器退出码与指标矛盾时不下判决（`UNKNOWN`，标签 `verdict_conflict`）、`opl-evolve-init` 先在暂存目录把新实验建完再整体切换、
  成绩只跟随产生它的那次评估（`programs.metrics_evaluation_id`，来源不明者被排除并单独计数）。
]

== 为什么不是单体 `MCP` 服务器

早期方案把 13 个能力塞进一个 Node stdio `MCP` 服务器。调研与实测都指向同一条反驳，因此改为单一职责的可执行文件。
*与原计划的差异*：13 个是计划口径，插件 `0.6.0` 实际交付 12 个命令，且集合有出入——多出原计划未设想的签名层 `opl-sign`，缺少 `opl-stat` 与 `opl-report`。

*一、保留 `MCP` 的主要理由不成立。* 原方案的论证是「`MCP` 工具只能按工具名做权限匹配，所以工具要拆窄，让 deny 能落在具体工具上」。但权限规则系统的一手事实是：`pattern` 字段接受 `ToolName` 或 `ToolName(arg-pattern)`，按顺序匹配、第一条命中即生效。既然 Bash 命令行也能被静态 allow/deny 精确约束，把能力藏在 `MCP` 方法后面就不再带来权限优势。

*二、工具定义常驻上下文，而命令行工具不常驻。* 参照实测：某 `MCP` 服务器 38 个工具约 13,448 tokens 每请求，这是纯开销。命令行工具的定义成本为零，只有技能正文被读取时才付费。调研对此的建议原话是「同时提供 skill 加本地 CLI 这条约 98 tokens 的廉价入口」。

*三、可组合、可替换、可单独测试。* 管道里每个阶段都能独立替换——换求解器、换校验器、换统计脚本——而不触碰其余部分。`MCP` 服务器改一个方法要重新加载整个服务器。每个可执行文件还能脱离 `JSON-RPC` 会话单独跑，这正是本项目全部验证的依据。

*四、进程边界天然隔离。* stdio `MCP` 的 stdout 被 JSON-RPC 独占，任何子进程把 stdout 写脏就断掉整个会话。独立可执行文件的 stdout 只属于它自己。

代价是放弃 `MCP` 的 `structuredContent`，改为约定退出码与 JSON。这个代价是值得的，理由见下一节。

== 退出码是判决通道

本项目的头号风险是把 `unknown` 折叠成「已证」。与其写进技能正文反复叮嘱，不如让它*在数值上无法混淆*：

#table(
  columns: (auto, auto, 1fr),
  table.header([*码*], [*判决*], [*含义*]),
  [`0`], [`PASS`], [这一步跑完并给出正面结果。*不等于「已被独立复核」*——判决强度看结构化字段与档位],
  [`1`], [`REJECT`], [断言被推翻：找到见证，或证书被判定无效],
  [`2`], [`USAGE`], [参数或输入错误],
  [`3`], [`UNKNOWN`], [无法判定，必须附原因。*绝不与 `1` 合并*],
  [`4`], [`MISSING`], [所需后端不存在，*也包含没有签名器*。此时不许回退到估算，也不许产出无签名的证据],
  [`5`], [`EMPTY`], [正常运行但无结果：0 个候选、0 次执行、重复提交、查询无匹配。对齐 `pytest` 退出码 5 的设计],
)

退出码只表达「这条命令完成了它那一步」；研究判决看结构化字段与档位，`0` 不等于已被独立复核。与最初的设计相比，`4` 与 `5` 的含义已经变宽，实况如下：

- `4 MISSING` 现在还涵盖*没有签名器*：`opl-certcheck`、`opl-encode --eval-witness`、`opl-leancheck` 三个证据产出命令在找不到 `ssh-keygen` 或本机密钥时，不但不产出证据，还会删掉刚写下的那份；`opl-conj` 写台账同样是 `4`——不产出无签名的记录。
- `5 EMPTY` 还用于「正常跑完但没有新增」：`opl-evolve-eval` 命中 `code_hash` 的重复提交、`opl-conj list` 查询无匹配。
- `--evidence-out` 指向已存在的路径（或它的 `.sig`）时以 `2` 拒绝：证据不许被覆盖。

由此得到三条硬性质：

- `unsat` 是 0，`unknown` 是 3。shell 里的 `if` 不可能把两者弄混。
- `REJECT` 只在*主动推翻*时出现。「我读不懂这份证书」只能走 `UNKNOWN`，否则就是伪证。
- 空结果有独立码，因此「没跑出东西」不会伪装成「通过」。

== 流约定

#table(
  columns: (auto, 1fr),
  table.header([*流*], [*内容*]),
  [`stdout`], [只允许机器可解析内容：一行 `s <判决> [附注]`，或一个 JSON 对象。成功时静默（silence is golden）],
  [`stderr`], [人读诊断、进度、被包装工具的原始输出。`--verbose` 只影响这里],
  [`文件`], [一切体积不可控的东西：证书、日志、运行快照、程序库],
)

判决行沿用 SAT 竞赛与 `drat-trim` 的既有约定（`s VERIFIED` / `s NOT VERIFIED`），不自造格式——因为管道下游就是这些工具，复用它们的词汇才能直接拼接。

== 命令清单

按管道阶段组织，每个命令一个职责。`[已实现]` 表示插件 `0.6.0` 里已交付并有回归覆盖，`[未实现]` 表示仍停在计划里。

原计划 13 个命令，实际交付 12 个，且集合并不重合：多出原计划未设想的签名层 `opl-sign`，缺少 `opl-stat` 与 `opl-report`（连带 `opl-benchmark` 技能）。这处出入先记在这里，两个缺口保持在计划中待裁。

#table(
  columns: (auto, auto, 1fr),
  table.header([*阶段*], [*命令*], [*一个职责*]),
  [探测], [`opl-capabilities`], [后端可用性与版本 → JSON。含功能探测，不只看存在性。`[已实现]`],
  [登记], [`opl-conj`], [猜想台账读写。一题一文件，状态变更强制带证据指针。`[已实现]`],
  [复核], [`opl-certcheck`], [证书独立复核：调度 `drat-trim` / `lrat-check`，翻译成退出码。`[已实现]`],
  [编码], [`opl-encode`], [猜想加定义域 → CNF 或 SMT-LIB。编码错误的主要来源，需双后端交叉验证。`[已实现]`],
  [搜索], [`opl-search`], [跑后端，产出见证或证明。三态输出由退出码承载。`[已实现]`],
  [证明], [`opl-leancheck`], [Lean 编译加公理审计：白名单、`sorry`、`native_decide`。`[已实现]`],
  [实验], [`opl-run`], [运行快照：`cmd` / `env` / `capabilities` / `metrics`。`[已实现]`],
  [统计], [`opl-stat`], [删失统计与 performance profile。`[未实现]`],
  [进化], [`opl-evolve-init` / `-suggest` / `-eval` / `-show`], [程序搜索的四个 plumbing，共用一份 `SQLite`。`[已实现]`],
  [报告], [`opl-report`], [台账加运行目录 → Typst 源码与 PDF。`[未实现]`],
  [签名], [`opl-sign`], [本机签名密钥与验签（SSHSIG，命名空间 `open-problem-lab`）：记录的签名内嵌在 JSON 顶层 `signature`，证据的签名旁挂为 `<path>.sig`。原计划未列，实现中新增。`[已实现]`],
)

== 三个命令的契约

`opl-capabilities`、`opl-certcheck`、`opl-conj` 三份契约是本文的基准；其余已实现的九个命令（`opl-encode`、`opl-search`、`opl-leancheck`、`opl-run`、`opl-evolve-*` 四个、`opl-sign`）用法以其 `--help` 为准。

=== `opl-capabilities`

探测每个后端的可用性与版本，产出 `capabilities.json`。两条来自实测的要求：

- *所有版本探测带硬超时*。elan 的 `stable` 指向未安装版本，裸 `lean --version` 会触发联网下载工具链并挂住。超时按「不可用」处理并记 `probe_timeout`。
- *`decompress` 必须做功能探测，不能只查存在性*。上游 master 在 `read_lit` 里有一句遗留的 `printf`，把每个原始字节混进 stdout，输出不是合法 LRAT。本机实测：7 行的合法输入还原出 49 行垃圾。它因此是本机唯一一个「存在但坏了」的后端，只查 `command -v` 会把它当可用。

退出码：`0` 必需层齐全；`4` 必需层有缺失。

=== `opl-certcheck`

把「求解器说 UNSAT」变成「第三方可以在不信任求解器的前提下复核」。它自己不判断数学，只调度校验器并回答一个问题：*证书被完整读入了吗*。答不上来就走 `UNKNOWN`。

三条守卫，各对应一种被实测确认的失败：

#table(
  columns: (auto, 1fr),
  table.header([*路径*], [*完整性判据*]),
  [`drat`],
  [校验器自报 `read N bytes from proof file`，与实际字节数比对。不相等说明格式误判],
  [`lrat`],
  [校验器自报 `Last line checked = N`。`N = 0` 说明一行证明都没读进去],
  [`clrat`],
  [`decompress` 的输出先过 LRAT 语法。不合法即判解压器有问题，*绝不把解压器的毛病算成证书的毛病*],
)

第三条守卫是必须的：`decompress` 坏掉时，下游 `lrat-check` 会老老实实报 `NOT VERIFIED`。若照单全收，就会把一份好证书判成假的——这正是本项目最不能犯的错。

`--evidence-out` 产出证据记录（`opl.evidence/1`）：后端、格式、三个 SHA-256、字节数、解析完整性、耗时。它可以直接作为 `opl-conj set --evidence` 的指针。

=== `opl-conj`

猜想台账，一条记录一个 JSON 文件。总状态由 `informal_status` 与 `formal_status` 两个独立字段派生，因此「机器已证、人未消化」这类中间态有位置安放（派生为 `open (Lean)`）。

*状态变更必须带 `--evidence`，否则拒绝写入。* 这条不是文档里的约定，而是工具层面的拒绝操作：

```text
$ opl-conj set C-0001 --formal-status refuted
退出码 2：拒绝写入：状态变更必须带 --evidence <指针>。
```

把纪律做成工具行为而非提示词，是这套设计的一贯做法：提示词会被忽略，退出码不会。

== 组合示例

以下是一次真实跑通的往返（输出经过裁剪）：

```bash
# 1. 登记一个猜想
opl-conj add --id C-0002 --title "uuf-100-1 可满足性" \
  --statement "CNF uuf-100-1 存在可满足赋值" --no-falsifiable

# 2. 独立复核证书；判决走退出码，证据落盘
opl-certcheck --formula uuf-100-1.cnf --cert uuf-100-1.drat \
  --evidence-out lab/evidence/C-0002.json

# 3. 用证据指针变更状态
opl-conj set C-0002 --formal-status refuted \
  --evidence lab/evidence/C-0002.json --verification-level exact_certificate

# 4. 台账能被通用工具直接消费
opl-conj list --jsonl | jq -r '"\(.id)\t\(.status)"'
```

实测结果：证书是真的 → `0`；把证书里一个文字翻转 → `1`；空证书 → `3`；后端缺失 → `4`；`R_4_4_18`（153 变量 / 6120 子句 / 8.4 MB `.bz2`）→ `0`，460 毫秒。台账最终状态 `refuted`，`verification_level` 为 `exact_certificate`。

`MCP` 在本设计中退为*可选的薄适配层*：若某些环境确实需要 `MCP` 入口，只装 0 到 2 个工具（一个执行命令、一个轮询分离的长任务），它们不做任何业务判断，只是 `exec` 加上退出码翻译。业务逻辑一律留在可执行文件里。

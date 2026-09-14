= 架构

== 三个组件与一条边界

插件由三个组件构成，它们之间的边界是整套设计的核心约束：*`MCP` 服务器内不出现任何大模型调用*。

- *清单* `kimi.plugin.json`：声明技能目录、`MCP` 服务器、入口技能。选这个位置而非 `.kimi-plugin/plugin.json`，是因为调研确认前者优先，后者是兼容布局；两者同时存在时后者会被静默遮蔽，只在诊断里留一条 `shadowedManifestPath`。
- *技能* `skills/<name>/SKILL.md`：载明「何时触发、按什么判据判断、失败如何处置」。技能不写确定性逻辑，只写判据与流程。
- *服务器* `bin/opl-mcp.mjs`：单文件零依赖 Node stdio 服务器，持有台账、评估器、沙箱与外部求解器封装。

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*关注点*], [*归属*], [*理由*]),
  [LLM 生成 / 变异算子], [宿主 agent], [`MCP` 内调用模型会锁死 API key 管理与模型切换，且让「服务器只做数据库与评估器」的职责边界失效],
  [确定性计算], [`MCP` 服务器], [可测试、可复现、可被权限规则按工具名拦截],
  [判据与流程], [技能正文], [需要随研究经验迭代，且要能被模型读到并遵守],
  [一次性脚本], [插件内 `scripts/`], [避免为每个小工具增加一个 `MCP` 工具、稀释工具面],
  [长时任务], [沙箱子进程 + `job_id`], [stdio 的 `tools/call` 是请求响应往返，长任务必须返回句柄而非阻塞],
)

== 一次研究回合的时序

端到端流程固定为以下九步，任何一步失败都不允许跳到结论：

+ *能力探测*。`opl_capabilities` 落盘 `capabilities.json`，记录每个后端的可用性与版本。探测命令一律带超时（本机 `lean --version` 会触发 elan 联网自更新并开始下载工具链）。
+ *台账登记*。`opl_conjecture_upsert` 写入猜想条目，陈述、来源、可证伪性、当前状态与已测试范围。
+ *形式化*。`opl_formalize` 产出 Lean 陈述骨架与诊断，同时输出*忠实度检查清单*；`formalization_status` 停在 `compiles` 而非 `faithfulness_checked`，除非人工确认。
+ *验证器就位*。在搜索之前确定「什么算解决」：Lean 内核接受、证书复核通过、或固定截断下的实测数字。
+ *有界搜索*。`opl_search_counterexample` 在显式有限域内搜索，返回三态与假设级 `unsat core`。
+ *独立复核*。`opl_check_certificate` 用与生成路径不同的代码复核证书。
+ *放大与统计*。通过后放大搜索空间，或用 `seed` 多次重跑；结果进入删失统计。
+ *台账更新*。只有验证器通过才改 `formal_status`；否则保持 `open` 或降级为 `WITNESS_UNCERTIFIED`。
+ *报告*。`opl_report_build` 从运行目录整篇重渲染 Typst 报告，报告只读 `CSV` / `JSON` / `YAML`。

== 进程模型与隔离

候选代码来自模型，必须按不可信代码处理。调研确认三套主流开源进化框架都假定候选代码是「合作者而非敌人」：OpenEvolve 在同进程内加载并执行候选代码，其默认配置自述内存与 CPU 限制「尚未实现」；ShinkaEvolve 的本地作业只是一条裸 `subprocess.Popen`。

本机的可用手段与限制：

#table(
  columns: (auto, 1fr),
  table.header([*手段*], [*本机实测状态*]),
  [`bwrap`], [可用，非特权 user namespace。禁网、独立 PID/IPC/UTS、`--die-with-parent`、只读绑定系统库、`tmpfs` 写区],
  [`systemd-run --user --scope`], [可用且无需 root。一次给到 `MemoryHigh` / `MemoryMax` / `MemorySwapMax` / `CPUQuota` / `TasksMax` 与可寻址的 killswitch],
  [`Docker`], [29.7.2 存在。但 `--storage-opt size=` 在本机不可用（overlay2 落在 ext4，需 xfs 加 pquota），磁盘限额只能在应用层做],
  [`subprocess` + rlimit], [兜底路径。注意 `ulimit -a` 显示 cpu time 与 virtual memory 全为 `unlimited`，必须显式设置],
  [`/tmp`], [16 GiB tmpfs。跑飞的代码写 `/tmp` 会直接吃内存，沙箱内应挂独立 `tmpfs`],
)

默认执行路径取 `systemd-run --user --scope`，`bwrap` 用于需要禁网与命名空间隔离的场景，`subprocess` + rlimit 作零依赖兜底。三条路径都不把 `RLIMIT_AS` 当唯一内存手段：内存压不住时它既不精确，又会误伤 BLAS 的地址预留。

== 目录布局

#table(
  columns: (auto, 1fr),
  table.header([*路径*], [*内容*]),
  [`kimi.plugin.json`], [清单：`skills` 数组、`mcpServers.lab`、`sessionStart.skill`],
  [`skills/<name>/SKILL.md`], [技能正文；深材料放同级 `references/`，脚本放同级 `scripts/`],
  [`bin/opl-mcp.mjs`], [`MCP` 服务器入口，零运行时依赖],
  [`bin/lib/`], [后端封装：SMT、CP、Lean、CAS、区间算术、沙箱],
  [`lab/conjectures/<id>.json`], [猜想台账，一题一文件],
  [`lab/runs/<run_id>/`], [实验快照：`cmd.json`、`env.json`、`capabilities.json`、`metrics.json`、`artifacts/`],
  [`lab/programs/<run_id>/`], [进化搜索的程序库（`SQLite`）与血缘轨迹],
  [`lab/certificates/`], [证书文件：`DRAT` / 精确有理 / 区间 / Lean 源码],
  [`lab/report/`], [Typst 报告模板与生成产物],
)

`lab/` 是运行时数据，与插件代码分离：插件目录可能被 `/plugins` 更新覆盖，实验数据不能被覆盖。默认落在工作区的 `lab/`，可用环境变量 `KIMI_PLUGIN_ROOT` 之外的自定义变量指向其他位置。

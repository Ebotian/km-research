= 架构

== 四个组件与一条边界

#table(
  columns: (auto, 1fr),
  table.header([*组件*], [*职责与边界*]),
  [`kimi.plugin.json`],
  [清单：显式列出技能目录、`sessionStart` 入口技能。选这个位置而非 `.kimi-plugin/plugin.json`，是因为调研确认前者优先，两者并存时后者被静默遮蔽，只在诊断里留一条 `shadowedManifestPath`],
  [`skills/<name>/SKILL.md`],
  [判据与流程。不写确定性逻辑，只写「何时触发、按什么判据判断、失败如何处置」；深材料放同级 `references/`，脚本放同级 `scripts/`],
  [`bin/opl-*`],
  [单一职责的可执行文件。判决走退出码，`stdout` 只出机器可解析内容。这是整个设计的事实中心],
  [`lab/`],
  [运行时数据，与插件代码分离。插件目录会被 `/plugins` 更新覆盖，实验数据不能被覆盖],
)

组件之间的核心边界有两条：*`bin/` 里不出现任何大模型调用*（变异算子留给宿主 agent，工具链只做确定性计算）；*技能里不出现确定性逻辑*（凡脚本能做的都下沉到 `bin/`）。第二条是 Unix 分工「机制与策略分离」的直接应用——技能是策略，可执行文件是机制。

== 一次研究回合的时序

九步固定为命令序列，每步的判决都是退出码：

+ *能力探测*。`opl-capabilities` 落盘 `capabilities.json`。探测一律带超时，`decompress` 这类「存在但坏」的后端由功能探测而非存在性探测识别。
+ *台账登记*。`opl-conj add` 写入陈述、来源、可证伪性。
+ *形式化*。产出 Lean 陈述骨架与诊断，同时输出*忠实度检查清单*。形式化状态停在 `compiles`，除非人工确认。
+ *验证器就位*。在搜索之前确定「什么算解决」：Lean 内核接受、证书复核通过、或固定截断下的实测数字。
+ *编码*。`opl-encode` 把猜想与定义域转成 CNF 或 SMT-LIB。同一个猜想建议用两个后端各编码一遍，用不一致暴露编码错误。
+ *搜索*。`opl-search` 跑后端，产出见证或证明。三态由退出码承载。
+ *独立复核*。`opl-certcheck` 用与生成路径不同的代码复核证书。
+ *台账更新*。只有验证器通过才改状态；`opl-conj set` 无证据指针即拒绝写入。
+ *报告*。`opl-report` 从运行目录整篇重渲染 Typst。报告只读 `CSV` / `JSON` / `YAML`，不内嵌计算。

== 进程模型与隔离

候选代码来自模型，必须按不可信代码处理。调研确认三套主流开源进化框架都假定候选代码是「合作者而非敌人」：OpenEvolve 在同进程内加载并执行候选代码，其默认配置自述内存与 CPU 限制「尚未实现」；ShinkaEvolve 的本地作业只是一条裸 `subprocess.Popen`。

改为小可执行文件后，隔离问题简化了一半：每个阶段本来就是独立进程，stdout 不会被 `JSON-RPC` 争用。剩下的问题只有「候选代码本身怎么跑」。

#table(
  columns: (auto, 1fr),
  table.header([*手段*], [*本机实测状态*]),
  [`bwrap`], [可用，非特权 user namespace。禁网、独立 PID/IPC/UTS、`--die-with-parent`、只读绑定系统库、`tmpfs` 写区],
  [`systemd-run --user --scope`], [可用且无需 root。一次给到 `MemoryHigh` / `MemoryMax` / `MemorySwapMax` / `CPUQuota` / `TasksMax` 与可寻址的 killswitch],
  [`Docker`], [29.7.2 存在。但 `--storage-opt size=` 在本机不可用（overlay2 落在 ext4，需 xfs 加 pquota），磁盘限额只能在应用层做],
  [`subprocess` + rlimit], [兜底路径。`ulimit -a` 显示 cpu time 与 virtual memory 全为 `unlimited`，必须显式设置],
  [`/tmp`], [16 GiB tmpfs。跑飞的代码写 `/tmp` 会直接吃内存，沙箱内应挂独立 `tmpfs`],
)

默认执行路径取 `systemd-run --user --scope`，`bwrap` 用于需要禁网与命名空间隔离的场景，`subprocess` + rlimit 作零依赖兜底。三条路径都不把 `RLIMIT_AS` 当唯一内存手段：内存压不住时它既不精确，又会误伤 BLAS 的地址预留。

长任务不用句柄轮询，用文件：以 `--detach` 启动，写 `runs/<id>/status.json`，用 `opl-run --wait` 轮询。这是 Unix 的既有做法，也让「超时重发」天然变成续跑而非重跑。

== 目录布局

#table(
  columns: (auto, 1fr),
  table.header([*路径*], [*内容*]),
  [`kimi.plugin.json`], [清单：`skills` 数组、`sessionStart.skill`],
  [`skills/<name>/SKILL.md`], [技能正文；深材料与脚本放同级 `references/`、`scripts/`],
  [`bin/opl-*`], [单一职责命令集，零第三方依赖（Python 标准库 + POSIX shell）],
  [`lib/opl_common.py`], [共享契约：退出码常量、流约定、工具查找、带超时的探测],
  [`tests/fixtures/`], [功能探测用的小样本（如 `tiny.clrat` 用于验证 `decompress` 是否可用）],
  [`lab/conjectures/<id>.json`], [猜想台账，一题一文件],
  [`lab/evidence/<id>.json`], [证据记录：后端、格式、SHA-256、解析完整性、耗时],
  [`lab/runs/<run_id>/`], [实验快照：`cmd` / `env` / `capabilities` / `metrics` / `artifacts`],
  [`lab/programs/`], [进化搜索的程序库与血缘轨迹],
  [`lab/report/`], [Typst 报告模板与产物],
)

`lab/` 默认落在工作区，可用环境变量 `OPL_LAB` 指向别处。台账与证据是纯文本、一记录一文件，因此可以直接进版本控制、可以 `diff`、可以被 `grep` 与 `jq` 消费——这也是把「台账要不要入 git」这个待决问题解掉的答案：文字证据入 git，大产物（`lab/runs/`）不入。

= `MCP` 工具集

== 通用契约

以下七条对全部 13 个工具生效，先于任何单个工具的语义。

- *零依赖*。服务器只依赖 Node 标准库，照搬 `kimi-datasource` 的 `readline` + 方法 `switch` 骨架。协议版本回显客户端请求值，不硬编码。
- *三态输出*。任何求解类工具只返回 `sat` / `unsat` / `unknown`；`unknown` 必须附带 `reason_unknown` 原文，且*禁止折叠为 `unsat`*。
- *错误即文本*。工具内部错误用结果体的 `isError: true` 表达，而非 JSON-RPC 协议错误；只有参数校验失败才回协议错误。
- *有界返回*。每个可能吐大块文本的工具都有默认截断与尾部行数参数（对齐 `lean_build` 的 `output_lines: int = 20`），完整日志落盘并只回路径。默认上限取 12k 字符量级。
- *路径白名单*。写文件只允许落在 `lab/` 之下；返回值经 `resolve` 校验，与请求路径同源。
- *显式超时与可取消*。每个子进程记录进程组句柄，支持组杀与硬超时；`notifications/cancelled` 必须处理，长任务做成 `job_id` 句柄模式，状态落 JSON 使超时重发变成续跑而非重跑。
- *幂等*。写操作以内容哈希为键；`run_id` 由输入内容哈希决定，同一实验重跑不产生新目录。

== 工具清单

#table(
  columns: (auto, auto, 1fr),
  table.header([*工具*], [*组*], [*作用*]),
  [`opl_capabilities`], [环境], [探测本机后端可用性与版本，落盘 `capabilities.json`],
  [`opl_conjecture_upsert`], [台账], [写入或更新一条猜想记录，返回派生状态与校验告警],
  [`opl_conjecture_query`], [台账], [按状态、分类、可判定性、可证伪性筛选台账，分页返回],
  [`opl_formalize`], [形式化], [自然语言陈述转为 Lean 骨架，返回诊断与忠实度检查清单],
  [`opl_verify_proof`], [形式化], [编译 + `#print axioms` + `sorry` 检测，给出三值判定],
  [`opl_search_counterexample`], [搜索], [在显式有限域内做反例搜索，返回模型、`unsat core` 或 `unknown`],
  [`opl_check_certificate`], [搜索], [独立复核证书：`DRAT` 证明、精确有理、区间算术、Lean 源码],
  [`opl_evolution_init`], [进化], [初始化程序库、岛与特征格，返回运行句柄],
  [`opl_evolution_prompt`], [进化], [拼接父代、灵感样本与失败产物，返回待补全的 prompt],
  [`opl_evolution_submit`], [进化], [提交候选，隔离执行评估，落格或给出拒绝原因],
  [`opl_evolution_query`], [进化], [查询程序、血缘、岛统计、预算余量，并导出轨迹],
  [`opl_run_record`], [实验], [开启或结束一次运行，固化 `cmd` / `env` / `metrics` 快照],
  [`opl_report_build`], [实验], [从运行目录生成 Typst 报告源码并尝试编译],
)

== 环境组

`opl_capabilities` 是本插件的第一道防线。调研确认本机缺 `z3`、`cvc5`、`sage`、`gap`、`pari/gp`、`cargo`，且 `python3` 没有 `pip` 模块（`No module named pip`，且有 `EXTERNALLY-MANAGED`）。因此插件必须把「缺什么」变成运行时可查询的事实，而不是假设。

- 输入：`refresh`（布尔，强制重探）。
- 输出：`capabilities`（每个后端一项：`available`、`version`、`path`、`probe_ms`、`probe_error`）与 `path`。
- 每个探测命令带硬超时，超时视为不可用并记 `probe_timeout`。
- 提示语禁止出现 `pip install`。二选一：`pacman -S <pkg>` 或 `uv venv && uv pip install <pkg>`（本机 `uv` 0.12.3 可用）。

== 台账组

猜想记录的核心创新是把「非形式化状态」与「形式化状态」拆成两个独立字段再派生总状态。调研确认 `erdosproblems.com` 用同一机制表达出 `open (Lean)` 这种关键中间态——机器已证但人未消化——单一枚举字段写不出这个语义。

`opl_conjecture_upsert` 返回 `warnings` 数组而不是静默写入，用于拦截三类常见错误：把 `open` 标签当未解事实、引用了未核实来源、把疑似反例直接升格为 `REFUTED`。

== 形式化组

`opl_formalize` 的责任边界必须写死在工具契约里：*它只产出骨架与检查清单，不宣称陈述已被正确形式化*。调研数据是语义正确率约 76%，且低覆盖度下答案正确率仅 20%；编译率会系统性高估忠实度。

`opl_verify_proof` 是本项目的 soundness 门禁，照搬 `lean-lsp-mcp` 的 `lean_verify` 设计并加强：

#table(
  columns: (auto, 1fr),
  table.header([*检查项*], [*判据*]),
  [公理白名单], [只允许 `propext`、`Classical.choice`、`Quot.sound`；出现其他公理即降级],
  [`sorry` 检测], [以 `lean --stdin --json` 的 `kind` 字段中 `hasSorry` 为判据（`-E sorry` 实测无效）],
  [`native_decide`], [视为未证明。Lean 核心文档自述该机制向逻辑新增一条断言公理，且把编译器与 `@[implemented_by]` 定义拉进可信基],
  [工具链断言], [调用前断言当前目录或祖先存在 `lean-toolchain`。本机 elan 的 `stable` 指向未安装的版本，裸 `lean` 会触发下载],
  [判定三值], [`proved` / `sorry_ax` / `failed`，绝不把前两者合并],
)

== 搜索组

`opl_search_counterexample` 把「假设 + 核心」做成一等公民：Z3 的 `assert_and_track` 配合 `check` 与 `unsat_core`，cvc5 的 `checkSatAssuming` 与 `getUnsatCore`，都能在不重写公式的前提下回答「是哪几条前提冲突」。每条研究假设命名（如 `H1_pigeon_bound`）并原样回显。

后端选择受能力探测约束：

- 增量求解与 `unsat core` 用 CaDiCaL 或 Glucose 系；Kissat 非增量、无 assumptions、无 core，只用于一次性硬实例。
- 限时预算优先用 Glucose / MiniSat 系。
- 反例穷举与组合搜索优先用 OR-Tools 的 CP-SAT，并把「可开关约束 + 违反度目标 + `only_enforce_if` + `sufficient_assumptions_for_infeasibility`」做成一组建模模板。
- 整数溢出必须用显式 `BitVec n` 建模并写清位宽；非线性或含量词的问题先截断成有限域，并在返回体里写明「有限域内无反例不等于定理成立」。

`opl_check_certificate` 承担「生成者与验证者分离」的落地。证据分级按可靠度排序：SAT 层 `DRAT` 文件（本机可编译 `drat-trim` 复核）优于 `UNSAT core`（假设级解释），优于裸模型（需独立复核）。

== 进化和实验组

`opl_evolution_*` 四件套的存储与状态设计照搬调研中已验证的做法：单文件 `SQLite` 存程序与只追加事件表，大产物（`stderr`、profiling）落文件而库里只存路径；`metrics_json` 必须含 `combined_score`，缺失时显式报错而不是退化成「所有数值指标的平均」。

成败一律走 `structuredContent` 的 `ok` 与 `rejected_reason`。评估永远在独立进程组中执行，服务器进程自身绝不加载候选代码——候选代码若把承载 JSON-RPC 的 `stdout` 写脏，整个会话就断了。

`opl_run_record` 与 `opl_report_build` 的字段规范见数据模型章。

= 实现与计划的差异

前八章是*写下来时的设计*，其中不少条目后来没有做，或者做成了另一个样子。这一章把差异集中列出来，按三条分：计划里*没有实现*的、实现与计划*不一致*的、以及计划里*没有*而实现加上的。

原则与前面各章一致：计划口径*留在原处不删*，差异在这里如实记账。每一条都对着代码核过（截至插件 `0.6.0`）。

== 未实现的计划项

#table(
  columns: (auto, 1fr),
  table.header([*计划*], [*现状*]),
  [M5：`opl-stat`（删失统计与 performance profile）], [命令不存在，`bin/` 里没有它。路线图的 M5 标 `[未实现]`],
  [M5：`skills/opl-benchmark`], [技能目录不存在。`skills/` 下只有 5 个：`opl-entry` / `opl-refute` / `opl-formalize` / `opl-prove` / `opl-evolve`],
  [M6：`opl-report`（台账 + 运行目录 → Typst 与 PDF）], [命令不存在；`lab/report/` 也不存在],
  [M6：`skills/opl-report`], [技能目录不存在],
  [数据模型的 `events(run_id, ts, kind, payload_json)` 表], [未建。实际用的是 `evaluations` 表（程序身份与运行分列，见数据模型章）],
  [沙箱的 CPU 配额], [未设。`lib/opl_run.py` 里写明了理由：要加 `+cpu` 得写进整个用户会话的 `cgroup.subtree_control`，那是改动不属于本项目的 cgroup 树；快照里如实记 `cpu_quota: {"enforced": false, "reason": …}`，不假装设了],
  [目录字节配额 + `RLIMIT_FSIZE` 兜底], [未实现。代码里既没有目录累计，也没有 `RLIMIT_FSIZE`；预算只有 `timeout_s` 与 `mem_max_mb`],
  [`opl-entry` 的任务到技能路由表], [只落了一条（找反例 → `opl-refute`）。`opl-formalize` / `opl-prove` / `opl-evolve` 没有路由入口],
  [验证纪律章「以下七条作为 `opl-entry` 核心内容注入」], [只部分落地：三条不可协商的纪律注入，七条里一条由工具行为承担、一条在 `opl-formalize` 逐字存在，其余在技能正文里没有落点。清单按原样留在该章，差异就地标出],
  [`skills/<name>/references/` 与 `scripts/`], [五个技能目录都只有 `SKILL.md`，两个同级目录都不存在],
  [`lab/programs/` 作为程序库位置], [实际在实验目录内：`<lab>/evolve/programs.sqlite`，候选目录 `<lab>/evolve/candidates/`],
  [`lab/evidence/` 由工具落盘证据], [台账不建这个目录：证据路径由 `--evidence-out` 显式给出，`lab/evidence/<id>.json` 只是技能里的约定写法],
  [`lab/evolve/candidates/` 这个目录本身], [被 `init_lab` 创建，但*没有任何代码往里写*——目前是个空目录],
  [“程序库是可重建的派生索引”], [没有命令能从 `runs/` 重建库。源码与指标只存在于库和运行目录里，重建目前只是手工层面的说法],
  [M6 交付里的 `README`], [README 已存在并按实况维护到 `0.6.x`，但它不在 M6 的三条验收标准里；M6 整体仍标 `[未实现]`],
)

== 与计划不一致的实现

#table(
  columns: (auto, auto, 1fr),
  table.header([*事项*], [*计划口径*], [*实现口径*]),
  [退出码 `0` 的含义],
  [「断言成立，且已被独立复核」],
  [「这一步完成了它那一步」。判决强度看结构化字段与档位；一个没有随附第三方证书的 `s UNSAT` 只是「求解器说了 UNSAT」],
  [档位（`verification_level`）取值],
  [五项，含 `UNVERIFIED`],
  [四项：`empirical` / `exact_certificate` / `lean_checked` / `human_peer_reviewed`。`UNVERIFIED` 只作为*反例*的 `verified_by` 取值出现，档位本身落回 `empirical`],
  [三态判决的名字],
  [`WITNESS_UNCERTIFIED`、`reason_unknown`],
  [两个名字在代码里都不存在。`opl-search` 的判决行是 `SAT` / `UNSAT` / `WITNESS_INVALID`；台账用小写 `refuted` / `no_counterexample_in_range` / `inconclusive`],
  [指标字段名],
  [写死 `combined_score`],
  [由*冻结的实验定义*点名：`feasible` / `objective` / `required` 三个字段。换实验不必改代码],
  [状态变更的必带项],
  [`run_id` 与 `evidence` 两者],
  [只硬校验 `evidence`；`--run-id` 可以省（省了就在 history 里为空）],
  [沙箱形态],
  [`systemd-run --user --scope`],
  [自建 per-run cgroup 套住 `bwrap`。理由是实测 `systemd-run -p IPAddressDeny=any` *不禁网也不报错*——那是「看着设了隔离、其实没有」],
  [内存归因的命名],
  [`memout`],
  [`oom` / `oom_inferred`（后者是没有 cgroup 记账时的降级标注），与 `timeout` / `signal` 并列],
  [命令总数],
  [13 个],
  [*12* 个：多出原计划没有的 `opl-sign`，少了 `opl-stat` 与 `opl-report`],
  [技能总数],
  [7 个],
  [*5* 个：缺 `opl-benchmark` 与 `opl-report`],
  [`capabilities.json` 的产出方式],
  [「产出 `capabilities.json`」],
  [`opl-capabilities` 默认把 JSON 写到 stdout，`--out` 才落文件。文件名是这个 JSON 的约定叫法],
  [流约定「stdout 只允许机器可解析内容」],
  [一行 `s <判决>` 或一个 JSON 对象],
  [`opl-conj list` 不带 `--jsonl` 时打印人读定宽表格——为的是在终端里能直接看。带 `--jsonl` 时才是机器接口],
  [运行目录的位置],
  [`lab/runs/<run_id>/`],
  [`opl-run` 默认 `$OPL_LAB/runs`（无 `OPL_LAB` 时 `<cwd>/runs`）；进化实验在 `<lab>/evolve/runs/<code_hash[:16]>/{extract,verify}/`],
  [`opl-run` 的归属],
  [只在工具链章的命令清单里出现，路线图没把它单列进任何里程碑],
  [已实现，并且是 `opl-evolve-eval` 的执行底座。路线图仍不给它里程碑——这是计划的疏漏，不是实现的取舍],
)

== 计划里没有、实现加上的

这些不是差异而是*增量*，各章已就地说明，这里只列名以便对照：

- *签名层* `opl-sign`（记录内嵌签名、证据旁挂 `<path>.sig`）——挡的是「手写一份自洽的假证据」；
- *台账事务式校验*——改动先在副本上全部应用，再校验改完的整条记录，不自洽整笔拒绝；
- *证据不许覆盖*——`--evidence-out` 指向已存在的路径（或它的 `.sig`）时以 `2` 拒绝；
- *评估器退出码契约*，以及退出码与指标矛盾时不下判决（`verdict_conflict`）；
- *`opl-evolve-init` 的事务*——先在 sibling 暂存目录里把整个新实验建完，再整体切换；归档的是整个旧实验目录；
- *运行索引相对实验目录存储*，以及*成绩与产生它的那次评估绑定*（`metrics_evaluation_id`；来源不明的成绩被排除并单独计数）；
- *工程配套*：`scripts/`（类型检查、回归、打包、验证压缩包）与 `hooks/pre-commit`——计划里没有这一层，它是「回归项数」能持续被信任的原因。

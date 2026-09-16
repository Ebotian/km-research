= 数据模型

数据模型的作用是让「自欺」在结构上无法表达。以下三个记录是插件的骨架。

== 猜想记录

非形式化状态与形式化状态分开存储，总状态是由两者派生的只读字段——这样 `open (Lean)`、`proved_by_hand` 等中间态才有位置安放。

```json
{
  "id": "C-0001",
  "title": "短标题",
  "statement_nl": "自然语言陈述，含全部前提",
  "statement_formal": {
    "file": "lab/lean/C0001.typ",
    "decl": "Opl.C0001.main",
    "toolchain": "leanprover/lean4:v4.x.y",
    "lake_manifest_sha": "…"
  },
  "informal_status": "open | disproved | proved_by_hand",
  "formal_status": "open | refuted | proved | no_counterexample_in_range | inconclusive",
  "formalization_status": "none | draft | compiles | faithfulness_checked",
  "status": "派生：open (Lean) / proved / refuted / open 等",
  "falsifiable": true,
  "decidable": "yes | no | unknown",
  "verified_range": {
    "lo": 1, "hi": 1000000,
    "method": "exhaustive | smt | cp",
    "run_id": "3f9a…",
    "statement": "仅在该有限域内无反例"
  },
  "known_bounds": [
    {"claim": "上界", "value": "1.014…", "source": "https://…"}
  ],
  "counterexamples": [
    {"witness": "n = 906150257", "certificate": "lab/certificates/…",
     "verification_level": "exact_certificate", "verified_by": "independent"}
  ],
  "source": {"url": "https://…", "attribution": "原始提出者", "retrieved_at": "2026-09-14"},
  "verification_level": "empirical | exact_certificate | lean_checked | human_peer_reviewed",
  "history": [
    {"at": "…", "field": "formal_status", "from": "open", "to": "refuted",
     "run_id": "3f9a…", "evidence": "lab/certificates/…", "evidence_sha256": "…"}
  ],
  "evidence": {                        // 原计划没有：记录自带的依据
    "path": "lab/evidence/C-0001.json",
    "sha256": "…", "kind": "cert", "subject": "C-0001",
    "verdict": "VERIFIED", "range": "1..1000000",
    "file": null, "decls": null, "witness": null, "at": "…"
  },
  "signature": {                       // 原计划没有：内嵌签名
    "format": "sshsig-embedded",
    "namespace": "open-problem-lab",
    "value": "-----BEGIN SSH SIGNATURE----- … -----END SSH SIGNATURE-----"
  }
}
```

`evidence` 与 `signature` 都是原计划没有、后来补上的两层。`evidence` 是记录*自带的依据*：路径、文件哈希，以及从证据里摘下的种类、对象、判决、范围、被绑定的文件，只在重新确立结论或升档时写入；校验时读的不是这份摘要，而是*当场重新加载*的那份证据。`signature` 是*内嵌签名*，签的是去掉它之后的规范序列化——把「写入」与「签名」合成一次原子提交。两者分工不同：哈希证明「现在的字节是什么」，签名证明「这份字节是谁写的」。哈希是自证的，手写一份自洽的假证据可以让它全对。

三条写入规则：

- `counterexamples` 只能由独立复核追加，不接受搜索工具的直接输出。搜索得到的是候选见证，复核通过后才成为反例。
- `verified_range.statement` 是固定措辞「仅在该有限域内无反例」，由工具自动填写，不允许模型改写为更强的表述。
- 任何状态变更必须带 `evidence` 指针，否则拒绝写入。原计划这条还要求带 `run_id`，*实际实现的硬校验只强制 `evidence`*：`--run-id` 可省，`history` 条目里该字段写 `null`。差在哪见本章末。

== 运行记录

运行记录采用 ASlib 的双表结构（`algorithm_runs` 与 `instance_features`）并补两个删失统计必需的字段。ASlib 面向离线算法选择，把「谁解出来了」与「用了多久」拆成不同文件；本项目需要同一条记录里同时拿到这两项。

```json
{
  "run_id": "3f9a…",           // 输入内容哈希，非时间戳
  "conjecture_id": "C-0001",
  "created_at": "2026-09-14T17:00:00+08:00",
  "cmd": ["python3", "scripts/search.py", "--n", "1000000"],
  "seed_root": 0,
  "seeds": [{"worker": 0, "seed": 12345}],
  "env": {
    "nproc": 12, "mem_gib": 30,
    "governor": "powersave", "cpu_affinity": "0-11",
    "container": null, "timezone": "Asia/Shanghai"
  },
  "tool_versions": {"python": "3.14.6", "lean": "…", "ortools": "…"},
  "dataset": {
    "name": "MIPLIB 2017", "solufile": "…", "retrieved_at": "2026-09-14",
    "sha256": "…"
  },
  "algorithm_runs": [
    {"instance": "i0007", "algorithm": "baseline", "seed": 12345,
     "runtime_s": 12.31, "runstatus": "ok",
     "event_observed": true, "cutoff_s": 60}
  ],
  "instance_features": [
    {"instance": "i0007", "features": {"n_vars": 120, "density": 0.03}}
  ],
  "analysis": {"test": "wilcoxon", "correction": "holm", "paired": true, "seed": 0},
  "metrics": {"n_runs": 10, "n_censored": 2, "cutoff_s": 60, "success_rate_at_T": 0.8},
  "artifacts": [{"path": "artifacts/log.txt", "sha256": "…", "bytes": 4096}],
  "verdict": "INCONCLUSIVE | REFUTED | NO_COUNTEREXAMPLE_IN_RANGE | IMPROVED"
}
```

`runstatus` 用受控词表：`ok`、`timeout`、`memout`、`crash`、`unsupported`、`presolved`。把超时与内存耗尽做成显式枚举值，是删失统计能成立的前提——`event_observed` 与 `cutoff_s` 必须与它同处一条记录。

配套的 `capabilities.json` 与 `env.json` 是运行快照的一部分，不可变。调研给出了两条直接理由：SMAC 文档明确「涉及时间就无法保证可复现」；NumPy 的 NEP 19 已放弃跨版本位级流兼容，不固定版本则反例搜索结果无法复核。

== 幂等与目录约定

`run_id` 由*输入内容哈希*决定而非时间戳，这样同一实验重跑天然幂等，目录不会分裂。哈希输入包含：命令、种子、数据集摘要、工具版本、以及猜想记录的 `statement_nl` 哈希。

`lab/runs/<run_id>/` 内固定四件套加一个产物目录：

- `cmd.json`、`env.json`、`capabilities.json`、`metrics.json`
- `artifacts/`

运行失败时元数据仍必须落盘。因此报告生成不嵌入运行期——它读已落盘的元数据，这样「运行崩了连记录都没有」不会发生。这条计划对应的 `opl-report` 命令*未实现*（见章末）。

== 程序库与血缘

进化搜索的程序库存 `SQLite`，单文件：

#table(
  columns: (auto, 1fr),
  table.header([*表 / 字段*], [*说明*]),
  [`programs(id, parent_id, generation, island, cell_key, code_hash, hash_mode, code, metrics_json, operation, created_at, metrics_evaluation_id)`],
  [`cell_key` 是特征格坐标（MAP-Elites 一格只留更优者）；`code_hash` 是归一化代码哈希，用于精确去重。`hash_mode` 也是原计划列里没有的，它记这串哈希按 `tokens` 还是 `text` 归一化而来（语法错的候选也能入库，但必须标明用的是文本哈希）],
  [`programs.metrics_evaluation_id`],
  [原计划没有这一列，是后来补上的：*当前头条指标是哪一次运行跑出来的*。成绩跟着*产生它的那次评估*走——失败运行（超时、评估器故障）只追加运行史，指标与来源两处都不动，于是「一次补测把旧定义的成绩洗成新定义」这条路被堵死。来源说不清的（旧库没回填上、或被手工改过）被排除在比较之外并单独计数],
  [`events(run_id, ts, kind, payload_json)`],
  [原计划表，*未实现*。实际承担这份职责的是下面的 `evaluations`],
  [`evaluations(id, program_id, run_dir, kind, feasible, metrics_json, problem_sha256, evaluator_sha256, budget_json, note, created_at)`],
  [一次评估一行，只追加。一份程序可以跑很多次（补测、换预算、换评估器），「这个数字是哪一次跑出来的、当时什么预算」在这里查得到。`run_dir` *相对实验目录*存储，读出时才解析成绝对路径：实验目录整体归档后，索引跟着归档走，不会指向活实验],
  [`metrics_json`],
  [必须含该实验定义点名的指标。缺失或类型不对时显式报错，不退化为「所有数值指标的平均」。原计划写死 `combined_score`，*实现里没有这个字段名*——指标契约由冻结的实验定义（`problem.json` 的 `feasible_field` / `objective_field` / `required`）给出，插件不认识任何具体指标名],
)

血缘去重必须防「迁移副本再次迁移」这类环路：调研记录了 183 个后代拷贝的事故，拷贝数会呈指数增长，且同源代码落入同一格点后被反复丢弃，白烧评估预算。去重做两重——归一化代码哈希做精确去重，评估结果按行为签名（逐测试得分元组）复用，避免重复评估。

=== 证据记录

证书复核产出一份独立的证据记录（`opl.evidence/1`），一条记录一个文件，落在 `lab/evidence/<id>.json`。产出它有*三条*命令——`opl-certcheck --evidence-out`、`opl-encode --eval-witness --evidence-out`、`opl-leancheck --evidence-out`——并由 `opl-conj set --evidence` 以指针方式引用；接口就是文件路径，不需要共享代码。原计划只设想了第一条。

```json
{
  "schema": "opl.evidence/1",
  "kind": "cert",                       // 原计划没有：这份证据讲的是哪一类事实
  "subject": "C-0001",                  // 原计划没有：为哪个猜想出的
  "range": "1..1000000",                // 原计划没有：这次覆盖的范围
  "backend": "drat-trim",
  "format": "drat",
  "formula": "/abs/path/uuf-100-1.cnf",
  "formula_sha256": "…",
  "certificate": "/abs/path/uuf-100-1.drat",
  "certificate_sha256": "…",
  "certificate_bytes": 17019,
  "parsed_bytes": null,
  "parse_complete": null,
  "duration_ms": 21,
  "verdict": "VERIFIED",
  "verification_level": "exact_certificate",
  "checked_at": "2026-09-14T17:35:00+08:00"
}
```

`kind`、`subject`、`range` 是原计划没有、后来补上的三件绑定：`kind` 说这份记录讲的是哪一类事实（`cert` / `witness_eval` / `lean_audit`），`subject` 说是为哪个猜想出的，`range` 说这次覆盖了哪个范围。缺了它们，一份*真*证据可以被拿去给另一个猜想背书，或者拿「见证求值通过」去支撑「该范围内没有反例」。加载证据时按种类*必填*对应的绑定字段——`cert` 要证书与公式，`witness_eval` 要见证与规格，`lean_audit` 要那个 `.lean` 文件——并重算它们当前的哈希；对不上的记录一律拒收。

证据落盘时还会*当场签出 `<path>.sig`*（旁挂签名，走系统自带的 `ssh-keygen -Y sign`，SSHSIG、命名空间 `open-problem-lab`）。找不到签名器或本机没有密钥时，这条命令不但不产出证据，还会把刚写下的那份删掉，以 `4 MISSING` 结束；写台账同样是 `4`。理由与「找不到验证器就不降级」是同一条：哈希是自证的，`verdict` 只是文件里的一行字，签名才是「这句话是谁说的」。

证据是*一次写出的产物*：`--evidence-out` 指到已存在的路径（或它的 `.sig`）时以 `2` 拒绝。台账记录按哈希引用证据，悄悄覆盖同一路径会让已经引用它的记录当场核不过；要重做就显式删掉旧的那份，那个 `rm` 就是「我知道旧的那份将被丢弃」的确认动作。

`parse_complete` 是这份记录里最值得看的字段，它回答「证书是否被完整读入」：`true` 表示校验器自报读入的字节数与文件一致；`false` 表示不完整，此时任何 `NOT VERIFIED` 都不可信，记录里的 `verdict` 会被改写成 `UNKNOWN`；`null` 表示该后端不提供这个信息（例如 `drat-trim` 只在部分模式下打印字节数），此时不予推断。

=== 纯文本作为真源

台账与证据都是「一记录一文件」的纯文本，`SQLite` 只用作可重建的派生索引（程序库与血缘）。因此：删掉数据库不丢信息；台账可以直接进版本控制；记录可以被 `diff`、`grep`、`jq` 与任何既有 Unix 工具消费，插件不需要为此提供专门的查询接口。

记录与证据都带签名（记录是内嵌 `signature` 字段，证据是旁挂 `<path>.sig`），但签名盖的是*规范序列化*而不是盘上那串字节——所以 `diff` / `grep` 照旧可用，而*手改*过的文件会被工具认定核不过：`opl-conj get` / `list` 如实标注，`set` 拒改（退出码 `2`），人工确认内容无误后可以用 `--adopt --confirmed-by` 收编。

大产物走另一条路：`lab/runs/` 与 `lab/programs/` 里的一切都只留路径与校验和，不入版本控制。这解掉了「台账要不要入 git」这个待决问题——文字证据入，运行产物不入。

== 同步状态

截至插件 `0.6.0`：M0–M4 已交付并有回归覆盖（本章涉及的 M4 = `opl-evolve-*` 四个命令加 `opl-evolve` 技能）；*M5（`opl-stat` + `opl-benchmark`）与 M6（`opl-report`）未实现*。命令共 12 个：`opl-capabilities`、`opl-conj`、`opl-encode`、`opl-search`、`opl-certcheck`、`opl-leancheck`、`opl-run`、`opl-evolve-init`、`opl-evolve-suggest`、`opl-evolve-eval`、`opl-evolve-show`、`opl-sign`。

以下三处是*设计与其后实现相冲突*的地方，这里只记录差异，不替设计做主：

- *命令与技能集合*：原计划 13 个能力/命令，实际 12 个且集合不同——*多的是 `opl-sign`*（原计划没有它），*少的是 `opl-stat` 与 `opl-report`*；技能 5 个（`opl-entry` / `opl-refute` / `opl-formalize` / `opl-prove` / `opl-evolve`），没有 `opl-benchmark` 与 `opl-report` 技能。
- *运行史表*：原计划的 `events` 表未实现，实际的运行史是 `evaluations` 表。
- *字段级*：`run_id` 未进硬校验（只见于「三条写入规则」）；`metrics_json` 不要求原计划的 `combined_score`，指标契约改由冻结的实验定义给出。

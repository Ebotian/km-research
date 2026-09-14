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
     "run_id": "3f9a…", "evidence": "lab/certificates/…"}
  ]
}
```

三条写入规则：

- `counterexamples` 只能由独立复核追加，不接受搜索工具的直接输出。搜索得到的是候选见证，复核通过后才成为反例。
- `verified_range.statement` 是固定措辞「仅在该有限域内无反例」，由工具自动填写，不允许模型改写为更强的表述。
- 任何状态变更必须带 `run_id` 与 `evidence` 指针，否则拒绝写入。

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

运行失败时元数据仍必须落盘。因此报告生成不嵌入运行期——它读已落盘的元数据，这样「运行崩了连记录都没有」不会发生。

== 程序库与血缘

进化搜索的程序库存 `SQLite`，单文件：

#table(
  columns: (auto, 1fr),
  table.header([*表 / 字段*], [*说明*]),
  [`programs(id, parent_id, generation, island, cell_key, code_hash, code, metrics_json, operation, created_at)`],
  [`cell_key` 是特征格坐标（MAP-Elites 一格只留更优者）；`code_hash` 是归一化代码哈希，用于精确去重],
  [`events(run_id, ts, kind, payload_json)`],
  [只追加。大产物只存路径，与 `artifacts/` 分工],
  [`metrics_json`],
  [必须含 `combined_score`。缺失时显式报错，不退化为「所有数值指标的平均」],
)

血缘去重必须防「迁移副本再次迁移」这类环路：调研记录了 183 个后代拷贝的事故，拷贝数会呈指数增长，且同源代码落入同一格点后被反复丢弃，白烧评估预算。去重做两重——归一化代码哈希做精确去重，评估结果按行为签名（逐测试得分元组）复用，避免重复评估。

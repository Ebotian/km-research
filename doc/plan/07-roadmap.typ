= 路线图

里程碑按「能否独立验收」切分，每个里程碑的验收标准必须是可执行的命令或可观察的输出，而不是形容词。

每个里程碑的产出都遵守同一条约束：先做窄，做通了再加宽。工具面在 M0 到 M6 之间从 1 个增长到 13 个，每一步都保持可安装、可运行。

== M0 骨架可安装

交付：`kimi.plugin.json`、`skills/opl-entry/SKILL.md`、`bin/opl-mcp.mjs`（只实现 `initialize`、`tools/list`、`tools/call`、`ping` 与 `opl_capabilities`）。

验收：

- 通过 `/plugins install` 安装后，`opl-entry` 出现在会话的技能列表 `Extra` 段，且 `sessionStart` 自动注入。
- 调用 `opl_capabilities` 得到 `capabilities.json`，其中 `z3`、`cvc5` 等缺失后端标为 `available: false` 且附 `probe_error`。
- 探测 `lean --version` 不挂起（必须带超时；本机裸调用会触发 elan 下载工具链）。

== M1 台账与溯源

交付：`opl_conjecture_upsert`、`opl_conjecture_query`、`opl_run_record`、`skills/opl-report/SKILL.md` 的台账部分。

验收：

- 写入 `C-0001` 后，`lab/conjectures/C-0001.json` 的派生 `status` 与两个独立状态字段一致。
- 同一实验重跑两次，`run_id` 相同、目录不分裂。
- 对一个空结果的运行，`metrics.json` 落盘且退出码非零、非 0。

== M2 反例搜索与证书复核

交付：`opl_search_counterexample`、`opl_check_certificate`、`skills/opl-refute/SKILL.md`。

验收（三项，缺一不可）：

- 对一个已知存在反例的猜想，工具返回 `sat` 且候选见证经独立复核后写成 `REFUTED`。
- 构造一个必然超时的搜索，返回 `unknown` 且带 `reason_unknown`；*断言它没有被报成 `unsat`*。
- `DRAT` 证书能被本机编译的独立校验器复核通过。

== M3 形式化与证明验证

交付：`opl_formalize`、`opl_verify_proof`、`skills/opl-prove/SKILL.md`。

验收：

- 对一个含 `sorry` 的文件，判定为 `sorry_ax` 而不是 `proved`。
- 对一个使用 `native_decide` 的文件，判定为未证明。
- 一个已知定理（Mathlib 中已有）通过验证，且 `#print axioms` 输出落在白名单内。
- 调用前若当前目录与祖先均无 `lean-toolchain`，工具报错而不是触发工具链下载。

== M4 进化式程序搜索

交付：`opl_evolution_init` / `prompt` / `submit` / `query`、`skills/opl-evolve/SKILL.md`。

验收：

- 在一个玩具问题（小规模在线装箱或排序网络）上跑出优于初始骨架的候选。
- 候选代码在 `bwrap` 或 `systemd-run` 沙箱内执行，禁网生效；一个故意死循环的候选被硬超时终止且不影响服务器进程。
- 提交一个把 `stdout` 写脏的候选，服务器会话不断开。
- 同一份候选重复提交两次，第二次因 `code_hash` 命中而被拒绝并给出 `rejected_reason`。

== M5 实证基准与统计

交付：`skills/opl-benchmark/SKILL.md`、统计脚本、`opl_report_build` 的表格部分。

验收：

- 两个算法的对比输出包含 `runstatus` 分布、`n_censored`、固定截断下的成功率、以及 performance profile 数据。
- 统计路径按固定决策树执行，`analysis` 字段记录了所用的检验与校正方法。
- 对元数据不一致（核数或 governor 不同）的两组运行，工具拒绝合并并说明原因。

== M6 报告与收口

交付：完整的 `opl_report_build`、`lab/report/` 模板、`references/` 深材料、README。

验收：

- 从 `lab/runs/` 整篇重渲染 Typst 报告并编译出 PDF；报告中每个数字都能追到某个 `artifacts/` 文件或 `metrics.json` 字段。
- 报告不含任何未标注 `verification_level` 的结论。
- 台账视图由脚本生成，人工编辑被覆盖。

== 排序理由

M0 到 M6 的顺序不是按技术难度排的，而是按「自欺的暴露面」排的：先把能力和台账做出来，研究者才能观察到自己的失败模式；再把验证器接上；最后才做搜索与改进。把搜索放前面会得到大量无法验证的中间结果，而这正是调研中 AI Scientist 多篇生成论文含幻觉数值的成因。

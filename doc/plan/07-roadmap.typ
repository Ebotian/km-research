= 路线图

里程碑按「能否独立验收」切分，每个里程碑的验收标准必须是可执行的命令或可观察的输出，而不是形容词。

每个里程碑的产出都遵守同一条约束：先做窄，做通了再加宽。命令集在 M0 到 M6 之间从 3 个增长到 13 个，每一步都保持可安装、可运行。

== M0 契约与骨架

*垂直切片已完成并通过实测*，用来先验证组合契约本身成立——退出码语义、流约定、能力探测的降级路径。

交付：`kimi.plugin.json`、`skills/opl-entry/SKILL.md`、`bin/opl-capabilities`、`bin/opl-conj`、`bin/opl-certcheck`、`lib/opl_common.py`。

验收（全部已实测通过）：

- 通过 `/plugins install` 安装后，`opl-entry` 出现在会话的技能列表 `Extra` 段，且 `sessionStart` 自动注入。
- `opl-capabilities` 产出 `capabilities.json`；`z3`、`cvc5` 等缺失后端标为不可用并附原因；`decompress` 经*功能*探测被判为 `broken`（只查存在性会漏掉它）。
- 探测 `lean --version` 不挂起（本机裸调用会触发 elan 下载工具链，必须带超时）。
- `opl-conj` 在缺少 `--evidence` 时以退出码 `2` 拒绝状态变更。
- `opl-certcheck` 对真证书返回 `0`、对内容篡改的证书返回 `1`、对空证书返回 `3`、对缺失后端返回 `4`；对 `R_4_4_18`（153 变量 / 6120 子句 / 8.4 MB `.bz2`）返回 `0`，460 毫秒。

收口项：把技能正文写实，补 `opl-entry` 与 `opl-refute` 两个技能；`kimi.plugin.json` 里显式列出全部技能目录。

== M1 编码与搜索

交付：`opl-encode`、`opl-search`、`skills/opl-refute/SKILL.md`。

验收：

- 同一个猜想用两种后端（SAT 编码与 CP 编码）各编一遍，能检出并报告两者的不一致——这是编码错误的主要暴露手段。
- `opl-search` 对可满足实例返回 `0` 且附带见证文件；对不可满足实例返回 `0` 且附证书文件；对超时返回 `3` 且附 `reason`。
- 缺后端时返回 `4`，不返回 `1`。

== M2 反例搜索闭环

交付：`opl-search` 与 `opl-certcheck` 的串联、`lab/evidence/` 落盘、技能里的完整流程。

验收（四项，缺一不可）：

- 对一个已知存在反例的猜想，工具返回 `0` 且候选见证经独立复核后，台账写成 `refuted`。
- 构造一个必然超时的搜索：退出码是 `3` 而不是 `1`。*断言它没有被报成「无反例」*。
- *负向对照必须破坏证书内容*，例如翻转一个文字：退出码 `1`。注意「截断证明」是无效的负向对照——实测把 `uuf-100-1` 的末行空子句删掉后 `drat-trim` 仍报 `VERIFIED`，因为正向传播自己就导出了冲突；在 `example-4-vars` 上做任何篡改也不足以翻案，因为那个 CNF 本身不可满足。若用截断做验收，会得到一个永远通过的假验收。
- 伪造格式误判时走 `3` 而不是 `1`：把一份压缩证书喂给按 DRAT 解析的路径，必须报「无法确认解析完整性」，不得报「证书无效」。

== M3 形式化与证明验证

交付：`opl-leancheck`、`skills/opl-formalize/SKILL.md`、`skills/opl-prove/SKILL.md`。

验收：

- 对一个含 `sorry` 的文件，判定为 `sorry_ax` 而不是 `proved`。
- 对一个使用 `native_decide` 的文件，判定为未证明。
- 一个已知定理（Mathlib 中已有）通过验证，且 `#print axioms` 输出落在白名单内。
- 调用前若当前目录与祖先均无 `lean-toolchain`，工具报错而不是触发工具链下载。

== M4 进化式程序搜索

交付：`opl-evolve-init` / `-suggest` / `-eval` / `-show`、`skills/opl-evolve/SKILL.md`。

验收：

- 在一个玩具问题（小规模在线装箱或排序网络）上跑出优于初始骨架的候选。
- 候选代码在 `bwrap` 或 `systemd-run` 沙箱内执行，禁网生效；一个故意死循环的候选被硬超时终止，且不影响调用方。
- 提交一个把 `stdout` 写脏的候选：由于候选代码本就在独立进程里跑，退出码仍是 `0`（污染只落在该进程的流上）。
- 同一份候选重复提交两次，第二次因 `code_hash` 命中而被拒绝并给出 `rejected_reason`。

== M5 实证基准与统计

交付：`opl-stat`、`skills/opl-benchmark/SKILL.md`。

验收：

- 两个算法的对比输出包含 `runstatus` 分布、`n_censored`、固定截断下的成功率、以及 performance profile 数据。
- 统计路径按固定决策树执行，`analysis` 字段记录了所用的检验与校正方法。
- 对元数据不一致（核数或 governor 不同）的两组运行，工具拒绝合并并说明原因。
- 跑基准前用 `cpupower` 固定 governor 并记录，否则结果标注为不可跨机器比较。

== M6 报告与收口

交付：`opl-report`、`lab/report/` 模板、`references/` 深材料、README。

验收：

- 从 `lab/runs/` 整篇重渲染 Typst 报告并编译出 PDF；报告中每个数字都能追到某个 `artifacts/` 文件或 `metrics.json` 字段。
- 报告不含任何未标注 `verification_level` 的结论。
- 台账视图由脚本生成，人工编辑被覆盖。

== 排序理由

M0 到 M6 的顺序不是按技术难度排的，而是按「自欺的暴露面」排的：先把契约、能力和台账做出来，研究者才能观察到自己的失败模式；再把验证器接上；最后才做搜索与改进。把搜索放前面会得到大量无法验证的中间结果，而这正是调研中 AI Scientist 多篇生成论文含幻觉数值的成因。

M0 之所以先做，还有一个工程理由：退出码语义是整个工具链的地基，它错了后面每一步都会继承这个错误。实测中它已经暴露了五次——包括一次「坏解压器导致好证书被判成假」的伪证路径（见风险章）。

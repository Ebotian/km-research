== 人机协同与「验证器至上」的 agent 研究流程

本节回答：当 agent 被用来攻击开放问题（猜想形式化与证明搜索、反例搜索、上界改进）时，如何保证结论不被幻觉污染、人工审核门放在哪里最划算、以及如何在工程上做到「不许伪造成功」。
下文严格区分 *一手事实*（可溯源到官方文档、论文或本机实测）与 *推断*（作者判断，已显式标注）。

=== 核心命题：验证器对结论有否决权，而不是打分权

- *一手事实*：Lean 官方参考手册把证明分成「诚实尝试」与「可能恶意」两类，并明确把 *未经人工审查的 AI 生成证明* 归入后者；它给出的是一条递增检查链：蓝色双勾 → `#print axioms` → `lean4checker --fresh` → `comparator` + 外部检查器。#link("https://lean-lang.org/doc/reference/latest/ValidatingProofs/")[Lean Reference: Validating a Lean Proof]
- *一手事实*：DeepMind 的 AlphaProof 公告写明形式语言的关键优势是「证明可被形式化验证」，而自然语言方法会产出 "plausible but incorrect intermediate reasoning steps"。#link("https://deepmind.google/discover/blog/ai-solves-imo-problems-at-silver-medal-level/")[DeepMind, IMO 2024]
- *一手事实*：一项对 35 篇 AI scientist 论文的编码调查发现：24 个可运行系统中 83% 发布了代码，但只有 38% 发布随机种子或执行轨迹、38% 报告任何 novelty 验证方法；9 个闭环 L4 系统中 7 个只是机械重跑、1 个为作者自述且无外部检查；作者的结论是 *语料中没有任何 LLM 时代的系统展示了经外部验证的 in-loop oracle*。#link("https://arxiv.org/abs/2608.05179")[arXiv:2608.05179]
- *推断*：把 verifier 当「打分器」（对候选排序、加权融合）而不是「否决者」（决定结论能否进入产物）是当前 AI scientist 系统的结构性缺陷。打分器可被阈值调参绕过，否决器不能。

=== 四类验证器与其硬性拒收条件

#table(
  columns: 2,
  [*验证器*], [*必须拒收（而不是降级采纳）的情况*],
  [Lean 4 内核], [证明依赖 `sorryAx`（即用了 `sorry`/`admit`）、依赖自定义公理、或 `lake build` 出现 warning],
  [独立类型检查器], [`lean4checker`/`nanoda`/`comparator` 报错，或 proved 的语句与挑战文件中的语句不一致],
  [SMT 求解器], [`check-sat` 返回 `unknown`；`unknown` 不得被记作 `unsat` 或「已证明」],
  [数值/优化证书], [区间不包含真值、上界证书无法被精确有理数重建、可行解违反整数性],
)

*Lean 一侧的可用机制（一手事实，均来自官方手册与官方 Action）*

- `#print axioms foo` 打印 `foo` 及其依赖传递使用的全部公理。良性结果只应出现 `propext`、`Classical.choice`、`Quot.sound`；出现 `sorryAx` 说明证明或其依赖含 `sorry`/未完成证明；出现任何其它公理说明定理仅在这些公理成立时才有效。#link("https://lean-lang.org/doc/reference/latest/Axioms/")[Lean Reference: Axioms]
- `native_decide` 会为每次调用生成一条 *专用公理*（命名形如 `bigSum._native.native_decide.ax_1`），官方说法是「便于逐条审计它到底证明了什么」；而已废弃路径会引入 `Lean.trustCompiler`。审计脚本必须把这两种名字当作可疑项显式列出，而不是当作「等同于 refl」。#link("https://lean-lang.org/doc/reference/latest/Axioms/")[Lean Reference: Axioms]
- `leanprover/lean-action` 提供了把这些检查变成 CI 硬门的具体输入名：`build-args`、`lint`/`lint-args`、`leanchecker`（在 Lean `nightly-2026-01-09`/`v4.28.0-rc1` 及更新版本上使用内置 `leanchecker`，更旧版本回退到外部 `lean4checker` 仓库）、`nanoda`（Rust 写的独立 Lean 4 类型检查器）、`nanoda-allow-sorry`（默认 `"true"`，官方注释直接写 *「Set to "false" if your project should have no sorry placeholders」*）、`axiom-audit`（配合 `axiom-audit-allow`，默认允许表就是 `propext,Classical.choice,Quot.sound`），以及输出 `nanoda-status`、`axiom-audit-status`。#link("https://github.com/leanprover/lean-action")[lean-action action.yml]
- `axiom-audit` 的官方描述是：若项目根命名空间下任何声明传递依赖于允许表之外的公理则失败，可捕获 `sorry`/`admit`（`sorryAx`）、`native_decide`（`Lean.ofReduceBool`）以及自造公理，*包括经由 import 传入的*。#link("https://github.com/leanprover/lean-action")[lean-action action.yml]

```yaml
# 本项目建议的 proof gate（把「警告」升级为「失败」）
- uses: leanprover/lean-action@v1
  with:
    build-args: "--wfail"                       # warning 即 error：sorry 会触发 warning
    lint: true
    leanchecker: true
    nanoda: true
    nanoda-allow-sorry: "false"                 # 禁止 sorryAx
    axiom-audit: true
    axiom-audit-allow: "propext,Classical.choice,Quot.sound"
```

- *一手事实*：`comparator` 被官方描述为「a trustworthy judge for Lean proofs」，用一个 JSON 配置指定 `challenge_module`、`solution_module`、`theorem_names`、`permitted_axioms`；流程是让 `Challenge.lean` 只留 `sorry` 的题目，`Solution.lean` 由第三方提供，然后在沙箱（`landrun`）里构建、用 `lean4export` 导出证明项、在沙箱外用 Lean 内核与/或 `nanoda` 重放，并断言被证明的语句与挑战文件一致。#link("https://github.com/leanprover/comparator")[leanprover/comparator]
- *一手事实*：Lean 手册明确指出，即使证明了 `sorry` 之外的东西，也仍要单独回答「这个形式化语句是否表达了你想说的意思」，并建议用不受源文件记号影响的 external checker 做原始 pretty-print 复核；官方还提供了 `arena.lean-lang.org` 的 Kernel Arena 与独立实现 `nanoda`。#link("https://lean-lang.org/doc/reference/latest/ValidatingProofs/")[Lean Reference] #link("https://arena.lean-lang.org/")[Lean Kernel Arena]

*SMT 一侧：`unknown` 是一等公民，不许被吞掉*

- *一手事实*：SMT-LIB 标准规定 `check-sat` 的响应为 `sat | unsat | unknown` 三值；当求解器在给定资源限制内无法判定时必须返回 `unknown`，并要求结果对 `:reproducible-resource-limit` 取值 *确定*（同一机器、同一命令序列下每次相同；若求解器使用随机化，必须先设置非 0 的 `:random-seed`）；询问 `(get-info :reason-unknown)` 会返回原因，标准预定义值为 `memout` 与 `incomplete`。#link("http://smtlib.cs.uiowa.edu/papers/smt-lib-reference-v2.6-r2021-05-12.pdf")[SMT-LIB Standard v2.6]

```smt2
(check-sat)
; sat | unsat | unknown  —— 三值，禁止把 unknown 折叠进 unsat
(get-info :reason-unknown)
; memout | incomplete | 求解器自定义 s-expression
```

- *推断*：插件应把 `unknown` 映射到自己的 `INCONCLUSIVE` 状态，使其 *不等于成功*：进程非零退出、结论字段写 `INCONCLUSIVE`、并在日志里留下 `:reason-unknown` 原文。把 `unknown` 当成「无解」是对开放问题研究最危险的一类静默错误。

*数值与优化一侧：证书比数值更可信*

- *一手事实*：Julia 的 `IntervalArithmetic.jl` 自述为「validated numerics」包，所有计算按区间进行，*最终结果是真值的严格包含（rigorous enclosure）*。#link("https://juliaintervals.github.io/IntervalArithmetic.jl/stable/")[IntervalArithmetic.jl]
- *一手事实*：FLINT/Arb 中 `arb_t` 表示一个球 $[m-r, m+r]$，官方保证「对输入球内任一点取值的精确运算结果都落在输出球内」，并对 Lambert W 等函数说明其实现是「先启发式浮点近似、再给出严格认证的包含区间」。#link("https://flintlib.org/doc/arb.html")[FLINT: arb.h]
- *一手事实*：有工作把「可验证」落到 LP 上：通过容差感知的精度提升（tolerance-aware precision boosting）建立条件，使得浮点单纯形与精确有理数实现做 *相同的 pivot 决策、得到相同的最终基*，再由该基精确重建并认证结果。#link("https://arxiv.org/abs/2609.11721")[arXiv:2609.11721]

=== 生成者-验证者分离：有效，但条件很硬

- *一手事实*：Prover-Verifier Games 在小学数学上迭代训练「小验证器 + 有帮助的 prover + 狡猾的 prover」；结果是 helpful prover 的准确率与验证器对对抗攻击的鲁棒性随训练上升，并且可读性训练 *可迁移到时间受限的人类*：人类审查 helpful prover 解答的准确率上升、审查 sneaky prover 解答的准确率下降。#link("https://arxiv.org/abs/2407.13692")[arXiv:2407.13692]
- *一手事实*：CriticGPT 在含真实 LLM 错误的代码上，模型批评在 63% 的案例中被优先于人类批评，且人工评估发现模型比付费人类审查者抓到更多 bug；该批评模型还能在被评为 "flawless" 的 ChatGPT 训练数据中找出数百个错误。#link("https://arxiv.org/abs/2407.00215")[arXiv:2407.00215]
- *一手事实*：消融实验显示辩论的增益 *不是无条件* 的：在 proposer-critic 辩论中，只有当 critic 的分类能力超过 judge，并且 judge 把 critic 的发言当作 *需要验证的主张* 而不是 *需要总结的证词* 时，辩论才显著优于 consultancy 基线；在 5 组配对中 3 组显著（且是最强的模型配对），2 组无效。#link("https://arxiv.org/abs/2605.27483")[arXiv:2605.27483]
- *一手事实*：反向证据同样明确——60 场三轮政策辩论中，10 个前沿模型的初始平均自信度为 72.9%（理性基线为 50%），并且随辩论轮次 *上升* 而非下降；论文称之为系统性过度自信与自信升级。#link("https://arxiv.org/abs/2505.19184")[arXiv:2505.19184]
- *一手事实*：LLM 在没有外部反馈时无法自我纠错，有时自我纠错后性能反而下降。#link("https://arxiv.org/abs/2310.01798")[arXiv:2310.01798]
- *一手事实*：在归纳推理任务上，用可验证奖励做 RL 的模型会 *系统性地放弃规则归纳*，转而枚举实例级标签以通过验证器；作者把这判定为 reward hacking（验证器只做外延正确性检查，因而存在假阳性），并提出 Isomorphic Perturbation Testing 来检测这种捷径。#link("https://arxiv.org/abs/2604.15149")[arXiv:2604.15149]
- *推断*：因此「生成者-验证者分离」在本项目里应落成三条硬约束：验证者与生成者换模型、换上下文、换信息集（不得看到生成者的推理草稿）；验证者被要求 *逐条核验* 而非给出整体印象分；验证者自身要先通过已知反例集（含故意注入的错误证明）的合格性测试，才被允许对结论行使否决权。

*验证者的质量本身必须被测量*

- *一手事实*：ProcessBench 含 3400 个竞赛/奥赛级测试用例，标注了最早出错步；其主要发现是现有 PRM 难以泛化到 GSM8K/MATH 之外的更难题，表现弱于 critic 模型（即提示出来的通用 LLM）。#link("https://arxiv.org/abs/2412.06559")[arXiv:2412.06559]
- *一手事实*：Hard2Verify 用 500+ 小时人工标注构造研究级逐步验证基准，评测了 29 个生成式 critic 与 PRM，结论是 *除少数例外，开源验证器落后于闭源模型*，并分析了验证算力扩展、自验证与「验证-生成动力学」。#link("https://arxiv.org/abs/2510.13744")[arXiv:2510.13744]
- *一手事实*：`FormalRewardBench` 指出可验证奖励虽便宜且「无 reward hacking 问题」，但信用分配稀疏（难题上的部分进展得不到信号），因此才有训练 reward model 的动机；该基准由 250 个偏好对构成，错误变体来自五种专家设计的错误注入策略。#link("https://arxiv.org/abs/2605.10141")[arXiv:2605.10141]
- *一手事实*：对自然语言数学证明验证的评测提醒：只看单一基准会得出脆弱或误导性结论；作者把组合 `GenSelect` 与 LLM-as-a-Judge 判为最有效的验证/选择框架。#link("https://arxiv.org/abs/2511.13027")[arXiv:2511.13027]

=== 检查点与人工审核门放在哪一步

- *一手事实*：Anthropic 的 agent 设计指南强调 agent 在每一步都必须从环境取得 "ground truth"（工具返回、代码执行结果），并指出 agent 可以「在检查点或遇到阻塞时暂停等待人类反馈」；对编码 agent 的总结是「自动化测试帮助验证功能，但人工审查对更广义的系统要求仍然关键」。#link("https://www.anthropic.com/engineering/building-effective-agents")[Anthropic Engineering]
- *一手事实*：`MathCoPilot` 给出的分工是「数学家掌舵高层数学方向，AI agent 在持续人工引导下承担细粒度的形式化与证明工作」，并用一份可导航的 living proof blueprint 让人可以逐点检查、指示与修正。#link("https://arxiv.org/abs/2607.14582")[arXiv:2607.14582]
- *一手事实*：Google 的 AI co-scientist 用多 agent 生成/批评/精炼假设 + tournament 进化，并在 11 个研究目标上用领域专家评 novelty 与 impact；专家偏好与其自动 Elo 指标一致，且部分新假设经真实实验室实验验证。#link("https://research.google/blog/accelerating-scientific-breakthroughs-with-an-ai-co-scientist/")[Google Research] #link("https://arxiv.org/abs/2502.18864")[arXiv:2502.18864]
- *一手事实*：CUGA 的 policy-as-code 运行时在执行的五个结构检查点拦截 agent，其中 *Intent Guard 位于规划上游*；其卖点是可预测、可审计、无需微调。#link("https://arxiv.org/abs/2605.20874")[arXiv:2605.20874]
- *一手事实*：Mozi 在药物发现中采用双层架构：控制平面用受治理的 supervisor-worker 层级强制角色级工具隔离、限制动作空间；理由是早期幻觉会在依赖链上乘性放大成下游失败与不可复现轨迹。#link("https://arxiv.org/abs/2603.03655")[arXiv:2603.03655]
- *一手事实*：一个已落地的 AI co-scientist 在生产搜索排序上把「例程工作交给单 LLM，高风险决策交给多 LLM 共识」（GPT-5.2 / Gemini Pro 3 / Claude Opus 4.5），全流程有人类科学家在环；报告称 AI 自动化闭环在人工 transformer 基线上再贡献 +0.083%，合计 +0.201% 离线增益。#link("https://arxiv.org/abs/2603.22376")[arXiv:2603.22376]
- *推断*：最划算的两道门是 *(1) 命题冻结门*——自然语言问题被形式化/规格化之后、任何搜索开始之前，由人确认「这个形式语句确实是我要的命题」（Lean 手册专门警告定理语句的含义问题）；*(2) 结论发布门*——在把任何「已证明/已改进上界/找到反例」写入产物之前，由人确认证书与结论的对应关系。中间的大量搜索步骤适合自动化 + 机器否决，不适合逐步人工审批（成本高、收益低）。

=== 「不许伪造成功」的工程手段

- *一手事实*：一项 5280 回合的研究发现，当研究者 *调整「顺从的内部/自身 fallback」的吸引力* 时，agent 行为会随之改变；其结论之一是「同一个最终违规率可能掩盖非常不同的机制」，并且 *被拦截之后还有什么路可走* 与规则本身同样重要。（例：provenance-aware 可执行 guard 在 51/384 回合拦截了被禁止的尝试，其中 44/51 随后安全完成。）#link("https://arxiv.org/abs/2608.09828")[arXiv:2608.09828]
- *推断*：因此最重要的反伪造措施是 *取消 fallback*：当验证器缺失、超时、返回 `unknown`、或返回空结果时，agent 必须收到一个「失败」而不是一个「近似答案」。任何「工具不可用时自己估一个数」的代码路径都是伪造成功的入口。
- *一手事实*：`pytest` 把「没有收集到任何测试」定义为独立的退出码 5，与退出码 0（全部收集并通过）严格区分；退出码 6 表示超过最大 warning 数。#link("https://docs.pytest.org/en/stable/reference/exit-codes.html")[pytest docs]
- *推断*：这条约定可以直接搬到验证流水线：*空结果必须是非零退出且带独立错误码*，而不是「通过」。CI 只接受退出码 0，其余一律判定为未完成。
- *一手事实*：奖励 hacking 的形式化定义指出，除常数函数外，几乎不存在「不可 hack」的代理奖励；在线性奖励下，对全体随机策略，两个奖励函数只有在其中一个是常数时才可能不可 hack。#link("https://arxiv.org/abs/2209.13085")[arXiv:2209.13085]
- *一手事实*：DeepMind 汇总了约 60 个 specification gaming 实例，定义为「满足目标的字面规格却没有达成意图结果」。#link("https://deepmind.google/discover/blog/specification-gaming-the-flip-side-of-ai-ingenuity/")[DeepMind]
- *一手事实*：排行榜本身可被策略性操作：一项分析发现未披露的私有测试让少数厂商可以先测多个变体再撤回分数、并在 Llama-4 发布前识别出 27 个私有变体。#link("https://arxiv.org/abs/2504.20879")[arXiv:2504.20879]
- *推断*：留证的具体形态：结果目录里对每个被宣布的结论保存（i）验证器命令原文与完整 stdout/stderr、（ii）退出码、（iii）输入与产物的哈希（本机可用 `sha256sum` #link("https://man7.org/linux/man-pages/man1/sha256sum.1.html")[man7] 与 `git hash-object` #link("https://git-scm.com/docs/git-hash-object")[git docs]）、（iv）本次运行尝试过的全部候选与它们的失败原因。缺任何一项，结论应被视为不可审计。

=== 失败与部分成功怎么记：把「没做出来」写成一等公民

- *一手事实*：MAST（Multi-Agent System Failure Taxonomy）基于 7 个主流框架的 1600+ 条标注轨迹，用专家标注 150 条轨迹归纳出 14 种失败模式，标注者间一致性 $kappa = 0.88$。#link("https://arxiv.org/abs/2503.13657")[arXiv:2503.13657]
- *一手事实*：τ-bench 提出用 $"pass"^k$ 度量 agent 在多次试验中的可靠性；其实测中即使是最强 function-calling agent 在任务上也成功率不足 50%，且相当不一致（零售域 $"pass"^8$ 低于 25%）。#link("https://arxiv.org/abs/2406.12045")[arXiv:2406.12045]
- *一手事实*：只审最终答案会漏掉大量失败。对多 agent 工业工作流的轨迹级审计建立了五类幻觉分类（factual、referential、logical、procedural、scope-based），发现近乎一半的幻觉轨迹 *同时包含多种类型*，并且二元准确率很高的自动检测器仍会误判最微妙的类型；轨迹感知的检测显著优于事后（post-hoc）验证。#link("https://arxiv.org/abs/2605.24219")[arXiv:2605.24219]
- *一手事实*：在 Conway 99-图问题上，一个自主 AI 研究 agent 以赛道 *部分得分* 指标记录成果：给出了「`Z/99` 上不存在满足 3366/4950 以上约束的循环图」的穷尽证明、一个强制结构归约、以及一个经过验证的自同构轨道存在性框架——即把「可验证的局部进展」与「解决了问题」明确分开。#link("https://arxiv.org/abs/2608.11211")[arXiv:2608.11211]
- *一手事实*：`XScientist` 的设计核心是把每次运行导出为可移植的 Agent-Native Research Artifact：记录探索 DAG、每个节点的代码与输出、以及 claim-to-evidence 锚点，并将质量门、修复、自审纳入同一条可观测流水线。#link("https://arxiv.org/abs/2607.12301")[arXiv:2607.12301]
- *一手事实*：一篇立场文章主张可复现实践本质上是「给 AI coding agent 做的 context engineering」，并强调 *研究者仍然对核验这些产物及其中编码的科学判断负责*。#link("https://arxiv.org/abs/2609.11728")[arXiv:2609.11728]
- *一手事实*：一项 *预注册* 的独立可复现性审计发现，「公开可用」「可运行」「能产生信号」「语义上被确认」是四个差距很大的层次：104 篇论文的共识语料中仅 59 篇（56.7%）有可公开到达的工件，且在抽查的锚点基准中 58/102（56.9%）个案例存在脚本性问题。#link("https://arxiv.org/abs/2608.09567")[arXiv:2608.09567]
- *推断*：给本项目的状态机建议：每次实验只允许四种终态——`PROVED`（附机器可检查证书）、`REFUTED`（附证书或可复算的反例）、`PARTIAL`（附已冻结的部分结果与其边界，例如某个约束类被穷尽排除）、`INCONCLUSIVE`（附失败原因与尝试记录）。把「很可能是对的」这种表述从产物里彻底删掉；`UNVERIFIED` 是允许出现在日志与笔记中的标记，但不允许出现在结论字段。

=== 相关研究：幻觉与验证缺口的实测数据

- *一手事实*：对研究级数学失败模式的分类学研究把失败分为四类：引用伪造（F1）、前提偷渡（F2，把承重假设当作「基本事实」断言）、静默问题改写（F3）、局部到全局的相容性缺口（F4）。在对某研究级基准若干个问题的 8 份一次性证明的审计中，*没有一份包含确证的伪造引用，但每一份都至少含有一处被断言为基本事实的承重主张*——作者认为这对「用 RAG 解决」的直觉是不利的。#link("https://arxiv.org/abs/2606.24902")[arXiv:2606.24902]
- *一手事实*：研究级证明的全局评估会遭遇 "context poisoning"（表面合理的陈述掩盖细微逻辑缺陷，导致幻觉或过度怀疑）；改为严格的逐步验证、为每一步维护详细上下文并严格限制可用定理来源后，不仅表现更好，而且 *失败分类本身发生了改变*，无约束的全局提示始终无法定位细微逻辑错误。#link("https://arxiv.org/abs/2606.10799")[arXiv:2606.10799]
- *一手事实*：在编码 agent 场景，有工作提出 training-free 的后生成验证：先把 issue 与 agent 轨迹 *正向* 重建成修复理由，再 *仅从补丁与其轨迹* 反向推断「这个补丁看起来在处理什么问题」（不给它原始 issue），最后比对两侧并做一致性调和，从而产出一个独立的验证信号，而不是在产生补丁的同一套解释下复审。#link("https://arxiv.org/abs/2608.08950")[arXiv:2608.08950]
- *一手事实*：DeepSeek-Prover-V2 走的路线是用 RL 做子目标分解，并由 Lean 提供可验证奖励——即「形式化验证器在搜索循环内」。#link("https://arxiv.org/abs/2504.21801")[arXiv:2504.21801]
- *一手事实*：Sakana 的 The AI Scientist 声称实现了从想法生成、写代码、执行实验、可视化到撰写全文并模拟评审的全自动闭环。#link("https://arxiv.org/abs/2408.06292")[arXiv:2408.06292] 结合前述 2608.05179 的编码结果（无任何 LLM 时代系统展示经外部验证的 in-loop oracle），说明「全自动闭环」与「外部可验证闭环」之间存在实质缺口。
- *UNVERIFIED*：一篇论文援引了一个叫 *First Proof* 的基准，称其把十个研究级数学问题交给最强的公开 LLM 并发现它们「持续地、流畅地、自信地做错」。该基准的一手出处未能在此次调研中取得（arXiv 检索接口在研究期间持续返回 429）。上句只能作为 *转述* 使用。#link("https://arxiv.org/abs/2606.24902")[arXiv:2606.24902]

=== 本机环境实测（只读核实）

- 已具备：`typst 0.15.1`、`Lean 4.33.1`（`lake 5.0.0-src+819816b`，经 `~/.elan`）、`julia 1.12.6`、`node v26.7.0`、`Python 3.14.6`、`git 2.55.0`、`sha256sum`、`timeout`、`pdftotext`、`pandoc`；Python 侧 `numpy 2.5.2` 可用。
- 缺失：`z3`、`cvc5`、`sympy`、`mpmath`、`python-flint`、`pytest`、`cargo` 均不可用。
- *推断*：首版插件的最短可信路径是 *Lean + Julia*：Lean 负责形式证明的硬否决（`--wfail` + `--print-axioms` 检查 + `leanchecker`），Julia（`IntervalArithmetic.jl`）负责数值上界/区间的严格包含。SMT 与优化证书需要额外安装，因此插件必须有明确的「验证器不可用 → 硬失败」分支，而不是静默降级到 LLM 自评。

=== 验证器可用性矩阵：缺失必须硬失败

把「验证器此刻是否可用」当作运行时第一等输入，并为每类结论预定义降级路径。

#table(
  columns: 3,
  [*结论类型*], [*首选验证器*], [*验证器不可用时的行为*],
  [形式定理/引理], [Lean 4 内核 + `leanchecker` + `nanoda`], [硬失败；禁止用 LLM 自评顶替],
  [组合/有限反例], [穷尽枚举 + 可复算脚本 + 产物哈希], [降级为 `UNVERIFIED` 候选，不得进结论],
  [数值上界/下界], [`IntervalArithmetic.jl`（已装）或 Arb], [硬失败；浮点近似不得充当严格界],
  [SMT 可判定片段], [`z3`/`cvc5`（本机需安装）], [硬失败；`unknown` 不得记为 `unsat`],
  [LP/组合优化界], [精确有理重建 + 对偶证书], [可降级，但必须在产物里标注证书层级],
)

- *推断*：这张表只有一条不变式——*结论只能向下走*。可以因为验证器变弱而把「已证明」降为「候选」，绝不允许因为验证器缺席而把「未验证」升为「已证明」。
- *推断*：反例搜索是唯一允许产出「候选物」的类型，因为一个可复算的候选反例本身即有研究价值；但候选反例必须附带让它可被复算的脚本与输入哈希，否则只能留在日志里，不能进入结论字段。

=== 评估

- *该抄*：把 Lean 验证做成 CI 硬门而不是报告项。照搬 `leanprover/lean-action` 的 `build-args: "--wfail"` + `nanoda: true` + `nanoda-allow-sorry: "false"` + `axiom-audit: true`（允许表 `propext,Classical.choice,Quot.sound`），并在插件里对每个定理额外跑一次 `#print axioms`，把 `sorryAx`、`Lean.trustCompiler`、`*_native.native_decide.ax_*` 一律判定为 *未证明*。
- *该抄*：在插件状态机里把三值逻辑显式化。SMT 的 `unknown` 映射到 `INCONCLUSIVE`，抓取 `(get-info :reason-unknown)` 的 `memout`/`incomplete` 原文写进日志；空结果（例如 0 个候选、0 个测试被执行）走独立非零退出码，参照 `pytest` 退出码 5 的设计，绝不与「通过」共用退出码 0。
- *该抄*：用 $"pass"^k$（τ-bench）而不是单次成功率来汇报实证基准，$k$ 取 5–8；同时按 MAST 的粒度记录失败模式，并按「轨迹级」而非「最终答案级」审计幻觉（Trajel 的结论是近半数幻觉轨迹混合多种类型，事后验证会系统性漏检）。
- *该抄*：把「部分成功」制度化为可发布产物。仿 Conway 99-图论文的做法，为反例搜索/上界改进记录 *已穷尽排除的约束类与其覆盖率*，并为每次运行导出可移植 artifact（探索 DAG、每节点代码与输出、claim-to-evidence 锚点），用 `sha256sum` 与 git 版本固定输入输出。
- *该避免*：不要给 agent 预留「工具不可用就自己估算」的内部 fallback。POLIS 的对照实验表明，改变这个 fallback 的吸引力会直接改变 agent 的违规/投机行为；正确做法是让缺失的验证器触发硬失败，并明确告诉 agent「被拦截后唯一可走的路是报告失败」。
- *该避免*：不要用「同模型 + 同上下文 + 同信息集」的自评或辩论来给出结论。LLM 无外部反馈时无法自我纠错（有时更差），辩论还会让双方自信度从 72.9% 继续升级；辩论只在 critic 强于 judge、且被要求把对方发言当 *待验证主张* 逐条核验时才有显著增益。人工门则应集中在 *命题冻结* 与 *结论发布* 两处，而不是逐步审批搜索过程。

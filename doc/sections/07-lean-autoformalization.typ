== Lean 4 自动形式化与证明搜索生态

本节回答：Lean 4 + Mathlib 的规模与本机安装状态、可用基准与数据集、主流系统与 agent 接口、statement 自动形式化的真实错误率，以及 agent 侧可落地的最小验证工作流。文中标注约定：`（实测）` 为本机 2026-09-14 通过只读命令核实；`（推断）` 为本文作者推断；`UNVERIFIED` 为未能验证。

=== (a) 本机工具链、Mathlib 规模与安装路径

*本机实测（2026-09-14）*

#table(
  columns: 2,
  table.header([检查项], [实测结果]),
  [`lean --version`], [`Lean (version 4.33.0-rc1, x86_64-unknown-linux-gnu, commit 62eed1db4d67327ec8120be05f1a1b0847d74561, Release)`],
  [`lake --version`], [`Lake version 5.0.0-src+62eed1d (Lean version 4.33.0-rc1)`],
  [`~/.elan/toolchains`], [`leanprover--lean4---v4.32.2` 与 `leanprover--lean4---v4.33.0-rc1` 两套],
  [`elan show` 的 active toolchain], [`leanprover/lean4:v4.33.1`，resolved from default `stable` —— 该版本并未安装],
  [`~/.elan/known-projects`], [`~/Downloads/emsx/leanproof`],
  [已存在的 mathlib 检出], [`.lake/packages/mathlib`，git rev `79d0395a1825a6264ad5d269e35e60537518955e`，tag `v4.33.0-rc1`，提交日 2026-07-16],
  [mathlib 构建产物], [`.lake/build` 6.5 GB，8,279 个 `.olean`，已可直接 import],
  [mathlib 源码规模], [`Mathlib/` 下 8,268 个 `.lean` 文件，合计 2,280,560 行],
  [mathlib 下载缓存], [`~/.cache/mathlib` 438 MB，8,643 个 `.ltar`],
  [该项目已取依赖], [`Cli`、`LeanSearchClient`、`Qq`、`aesop`、`batteries`、`importGraph`、`mathlib`、`plausible`、`proofwidgets`；*无* `repl`],
  [机器资源], [12 核、30 GiB 内存、根分区 145 GB 可用],
)

上游口径的库规模：Mathlib 统计页给出 136,946 个定义、288,081 条定理、772 位贡献者 #link("https://leanprover-community.github.io/mathlib_stats.html")[mathlib statistics]。

*安装与刷新路径*：Mathlib 官方 README 要求先 `lake exe cache get` 拉预编译 `olean`（跳过此步会让下一步极慢），再 `lake build`；单文件构建用 `lake build Mathlib.Algebra.Group.Defs`，新增文件后跑 `lake exe mk_all` #link("https://github.com/leanprover-community/mathlib4")[mathlib4 README]。`lean4-skills` 补充说明新版 Lake 提供 `lake cache get`（旧的 mathlib cache 可执行文件写作 `lake exe cache get`），且在 `lake clean` 之后或新 worktree 中必须先注水缓存 #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/references/sorry-filling.md")[sorry-filling.md]。本地 `lake --help`（实测）确认存在 `cache`、`shake`、`query --json`、`serve` 子命令。

*必须避开的陷阱（实测）*：`~/.elan/settings.toml` 的 `default_toolchain = "stable"`，而 `stable` 解析为 *未安装* 的 `leanprover/lean4:v4.33.1`。因此在没有 `lean-toolchain` 的目录里执行裸 `lean --version` 会触发 elan 下载该工具链。本次调研中该下载被触发并立即中止；它证明插件若在任何非 Lean 项目目录调用 `lean`/`lake`，会无意中改写用户工具链状态。（推断）正确做法有两种：始终在含 `lean-toolchain` 的项目根内调用，或直接以绝对路径 `~/.elan/toolchains/leanprover--lean4---v4.33.0-rc1/bin/lean` 调用已安装二进制。

*本机缺口*：`python3` 无 `lean_dojo`、无 `leanclient`；无 `pantograph`、无 `verus`、无 `repl` 包。已有 `rg`、`uv`、`uvx`、`docker`（实测）——这意味着 `lean-lsp-mcp` 可以用 `uvx` 直接起，但它的 REPL 快速路径（依赖项目内 `repl` 包）不可用，只能走 LSP 路径。

*该项目的实际配置（实测读出，可直接作为插件生成模板的样例）*：`lean-toolchain` 全文只有一行；`lakefile.toml` 如下。

```toml
name = "leanproof"
version = "0.1.0"
defaultTargets = ["Leanproof"]

[leanOptions]
pp.unicode.fun = true
relaxedAutoImplicit = false
weak.linter.mathlibStandardSet = true
maxSynthPendingDepth = 3

[[require]]
name = "mathlib"
scope = "leanprover-community"
rev = "v4.33.0-rc1"

[[lean_lib]]
name = "Leanproof"
```

该文件对应的 `lean-toolchain` 是 `leanprover/lean4:v4.33.0-rc1`。三点值得注意：mathlib 以 `rev = "v4.33.0-rc1"` 固定，与 `lean-toolchain` 的版本必须严格对齐，否则 Lake 会拒绝构建；`relaxedAutoImplicit = false` 关闭隐式变量自动声明，这对 agent 生成的代码是必要约束，否则拼错的标识符会被当成新变量而不报错；`weak.linter.mathlibStandardSet = true` 打开 mathlib 风格的 lint 集，等于给 agent 输出加了一层风格门。

=== (b) 基准与数据集

#table(
  columns: 2,
  table.header([基准], [规模与来源]),
  [miniF2F], [跨系统基准：Lean 与 Metamath 各 244 valid + 244 test，Isabelle 244，HOL Light 165；`v1` 于 2021-08 冻结。Lean 侧把陈述聚合进 `valid.lean` 与 `test.lean` 两个文件以求解析速度 #link("https://github.com/openai/miniF2F")[openai/miniF2F] #link("https://arxiv.org/abs/2109.00110")[arXiv 2109.00110]],
  [PutnamBench], [640 道 Putnam 定理的 1,692 份手工形式化，Lean 4 与 Isabelle 全覆盖、部分 Coq；NeurIPS 2024 Datasets and Benchmarks #link("https://arxiv.org/abs/2407.11214")[arXiv 2407.11214]],
  [ProofNet], [371 条样本，每条含 Lean 3 陈述 + 自然语言陈述 + 自然语言证明，取自本科教材；原仓库为 Lean 3，Lean 4 移植版放在 DeepSeek-Prover-V1.5 仓库内 #link("https://arxiv.org/abs/2302.12433")[arXiv 2302.12433] #link("https://github.com/zhangir-azerbayev/ProofNet")[ProofNet] #link("https://doi.org/10.5281/zenodo.8040109")[ProofNet 相关数据]],
  [FormalMATH], [5,560 道经 Lean 4 验证的题，覆盖高中奥数到本科；最强模型在实用采样预算下仅 16.46% 成功率；其人在回路自动形式化流程在人工复核前保留 72.09% 的陈述 #link("https://arxiv.org/abs/2505.02735")[arXiv 2505.02735]],
  [ProverBench], [325 道形式化题，含 15 道 AIME 2024–25，用于评测 DeepSeek-Prover-V2 #link("https://arxiv.org/abs/2504.21801")[arXiv 2504.21801]],
  [LeanWorkbook], [约 14 万题的大规模题库；Goedel-Prover 开源了其中 29.7K 条证明，接近此前 15.7K 的两倍 #link("https://github.com/Goedel-LM/Goedel-Prover")[Goedel-Prover]],
  [APPS], [10,000 道 Python 竞赛编程题，2021 年发布，约 1.3 GB，Hugging Face 上为 `codeparrot/apps` #link("https://arxiv.org/abs/2105.09938")[arXiv 2105.09938] #link("https://github.com/hendrycks/apps")[hendrycks/apps]],
)

*APPS 的定位需要说清楚*：它*不是* Lean 基准，而是 Python 代码生成基准，与形式化证明无共享评测口径。（推断）本项目若要用它，只能落在"算法设计与实证基准评测"这条支柱上，且需要自建 Lean 侧的对照物；Lean 生态里与之最近的是 LeanWorkbook 这类大规模题库，而非 APPS 的直接移植。

*miniF2F-test 上的公开数值*（整证生成，非 tactic 搜索）有助于校准预期：`DeepSeek-Prover-V1` 46.1%（`Pass@32`）、`V1.5-SFT` 48.2%、`V1.5-RL` 50.0%、`Goedel-Prover-SFT` 57.6%（同 `Pass@32`）；加大算力后 `Goedel-Prover-SFT` 达 62.7%（`Pass@3200`）与 64.7%（`Pass@25600`） #link("https://github.com/Goedel-LM/Goedel-Prover")[Goedel-Prover]。同表还显示 `ProofNet` 上的成绩仅 15.2%–16.0%，远低于 miniF2F——说明竞赛题集与本科教材题集是两个难度量级。

*基准与本项目四条支柱的对应关系（推断）*

#table(
  columns: 2,
  table.header([本项目支柱], [可用的 Lean 侧基准与缺口]),
  [数学猜想的形式化与证明搜索], [miniF2F、PutnamBench、FormalMATH、ProofNet 都可直接做回归集。刻意选择：miniF2F 陈述聚合于两个文件、便于批量 smoke test，但其问题是 2021 年冻结的、且已接近饱和（88.9%）；PutnamBench 与 FormalMATH 的难度分布更接近"真难题"，FormalMATH 上最强模型仅 16.46%，更适合作为不饱和的评测面],
  [反例搜索], [本机 mathlib 检出自带 `Counterexamples.lean` 与 `Counterexamples/` 目录（实测），可作为风格与格式参照；但未发现公开的、以"反例搜索成功率"为主指标的 Lean 基准——这一支柱基本需要本项目自建评测口径],
  [算法上界改进], [在本次检索范围内未发现公开的 Lean 基准或数据集，`UNVERIFIED` 是否存在。可行做法是自建"给定已知界 → 要求改进"的题集，并用 Lean 陈述承载上界本身],
  [算法设计与实证基准评测], [APPS 是 Python 基准，不能直接复用；Lean 侧最接近的是 LeanWorkbook（约 14 万题）这类题库，但它是题库不是算法评测。这一支柱需要自建：Lean 侧写算法与其正确性/复杂度陈述，运行时指标另行采集],
)

=== (c) 系统、模型与 agent 接口

- *LeanDojo*（NeurIPS 2023）：Python 库，从 Lean 仓库抽取证明状态、tactic、premise，并以编程方式驱动 Lean；官方仓库已标记 deprecated，指向 LeanDojo-v2 #link("https://github.com/lean-dojo/LeanDojo")[LeanDojo] #link("https://leandojo.org/")[leandojo.org]。
- *LeanDojo-v2*：端到端框架，覆盖仓库 tracing、lifelong 数据集、检索增强 agent、Hugging Face 微调与外部推理 API。核心组件：`BaseAgent` 与 `HFAgent`/`LeanAgent`/`ExternalAgent`，`SFTTrainer`/`GRPOTrainer`/`RetrievalTrainer`，基于 *Pantograph* Lean RPC 的 `HFProver`/`RetrievalProver`/`ExternalProver`；支持整证生成与按 tactic 逐步搜索；要求 Python ≥ 3.11 与 CUDA GPU，追踪阶段需 `GITHUB_ACCESS_TOKEN` #link("https://github.com/lean-dojo/LeanDojo-v2")[LeanDojo-v2]。同一课题组在 NeurIPS MATH-AI 2025 报告了该库 #link("https://leandojo.org/")[leandojo.org]。
- *DeepSeek-Prover-V2*：671B 开源模型，用 DeepSeek-V3 递归分解子目标构造冷启动数据再做强化学学习；miniF2F-test 88.9% pass ratio，PutnamBench 658 题中解出 49 题；同时开源 ProverBench、其中 15 道 AIME 解出 6 道 #link("https://arxiv.org/abs/2504.21801")[arXiv 2504.21801]。
- *Goedel-Prover*：开源（代码 MIT），`Goedel-Prover-SFT` 7B 权重在 Hugging Face，基于 `DeepSeek-Prover-V1.5-Base` 监督微调（无 RL）即达 miniF2F 57.6% `Pass@32`，PutnamBench `Pass@512` 解出 7 题并上榜首位；训练语料 `Goedel-Pset-v1` 含 1.64M 形式化陈述，其中 800K+ 配齐证明 #link("https://arxiv.org/abs/2502.07640")[arXiv 2502.07640] #link("https://github.com/Goedel-LM/Goedel-Prover")[仓库]。
- *Kimina-Prover*：从 Qwen2.5-72B 经大规模 RL 得到，提出"formal reasoning pattern"，miniF2F 达 80.7%（`pass@8192`），并声称样本效率与模型规模的清晰扩展；开源 1.5B 与 7B 蒸馏版 #link("https://arxiv.org/abs/2504.11354")[arXiv 2504.11354]。
- *Numina-Lean-Agent*（2026-01）：把"通用编程 agent 直接当形式数学推理器"作为范式——Claude Code + Numina-Lean-MCP，不训练专用 prover。以 Claude Opus 4.5 为底座解出 Putnam 2025 全部 12 题，并与数学家协作形式化 Brascamp-Lieb 定理。仓库明确要求：目标 `.lean` 文件必须位于可构建的 Lean 项目内（祖先目录含 `lean-toolchain` 与 `lakefile`），CLI skills 会向上寻找项目根并调用 `lake env lean`；孤立 `.lean` 文件会报 `lake=fail` #link("https://arxiv.org/abs/2601.14027")[arXiv 2601.14027] #link("https://github.com/project-numina/numina-lean-agent")[仓库]。这条约束对其他 agent 方案同样成立，是本项目最该内建的守卫。
- *lean-lsp-mcp*：以 `leanclient` 把 Lean LSP 包成 MCP server，用 `lake serve` 起语言服务。工具面相当完整：`lean_goal`、`lean_term_goal`、`lean_hover_info`、`lean_diagnostic_messages`、`lean_multi_attempt`（一次试多个 tactic 并回传各自目标状态）、`lean_code_actions`（把 `simp?`/`exact?` 的 "Try this" 解析成具体 edit）、`lean_run_code`、`lean_verify`（返回所用公理与 `unsafe`/`@[implemented_by]` 等源码模式告警）、`lean_build`（可选 `clean`、`fetch_cache`）、`lean_local_search`（依赖 `rg`）、`lean_minimal_hypotheses`、`lean_profile_proof`，以及外部检索 `lean_leansearch`、`lean_loogle`、`lean_leanfinder`、`lean_state_search`、`lean_hammer_premise`。外部检索普遍限流 3 次/30 秒；本地 loogle 首次建索引峰值约 13 GiB、热加载约 7 GiB #link("https://github.com/oOo0oOo/lean-lsp-mcp")[lean-lsp-mcp] #link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/main/docs/tools.md")[tools.md]。
- *lean4-skills*：面向"任意 agent host"的 Lean 4 技能包，定义了 12 条工作流（`draft`/`formalize`/`autoformalize`/`prove`/`autoprove`/`disprove`/`checkpoint`/`review`/`refactor`/`golf`/`learn`/`diagnose`），共享一个 Plan → Work → Checkpoint → Review → Replan 循环；它把 `lean-lsp-mcp` 列为"可选但强烈推荐" #link("https://github.com/cameronfreer/lean4-skills")[lean4-skills] #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/SKILL.md")[SKILL.md]。

=== (d) statement 自动形式化的现状与错误率

这一节是本节区中风险最高、也最容易被人忽略的部分：*Lean 编译通过不等于陈述正确*。

- *类型正确率在涨，但不是一个可用的置信度*。2026 年 6 月的 Signal-Coverage Matrix 报告：LLM 自动形式化的头部 type-correctness 在两年内从约 53% 升到约 76%。作者把 Lean elaborator 的通过/失败与语义等价判断交叉成四格（真成功 TS、仅类型正确 TO、仅语义正确 SO、双失败 BF），在 `ProofNet#` 与 `MiniF2F-test` 上以 DeepSeek V4-Pro 评测 Vanilla、Lean-Retry、Sample-Filter、SAF 四种方法：三种带 elaborator 反馈的方法带来 +34 到 +36 的 TS 增益，其中约 64% 来自类型层的挽救；语义层净持平（原语义错误中救回 87.5%，同时新造 8 个）。TO 到 TS 的转化率为每种方法 23/61（Wilson 95% 置信区间 26.6%–50.3%）。两个评判者在带反馈输出上分歧达 26–37 个百分点，而在 Vanilla 上只有 7 个百分点 #link("https://arxiv.org/abs/2606.28013")[arXiv 2606.28013]。
- *编译率显著高估忠实度*。2026 年多篇独立工作报告了同一结论：ITPEval 指出"仅靠原生类型检查会大幅高估语义忠实度"，并报告在源语言到 Lean 4 的 miniF2F 陈述翻译中，有相当比例的"已验证"翻译经语义检查并不成立；`Beyond Compilation` 与一项数值分析形式化的质量审计均给出"基于编译的指标显著高估形式化质量" #link("https://arxiv.org/search/?searchtype=all&query=autoformalizer")[arXiv 检索：autoformalizer]。*注*：这三篇的 arXiv 编号在本次调研中未能解析——`export.arxiv.org` 的 API 与 `arxiv.org` 的检索页在调研期间返回 429，无法取得稳定 ID；其标题、作者、提交时间与摘要已从 arXiv 检索结果页读到，结论可信，但引用时应回补编号（`UNVERIFIED` 之处仅为编号本身）。
- *低覆盖度下的"证明成功"几乎不能作为答案正确的证据*。2026 年 5 月的 Lean-as-Judge 研究在 MATH-500 上给出：证明获胜的答案在高证明覆盖度下 96% 正确，但在低覆盖度下只有 20% 正确；一个 7B 自动形式化器只对 28% 的题能证明某类陈述，而人工审计发现这些证明中仅约 43% 忠实 #link("https://arxiv.org/search/?searchtype=all&query=autoformalizer")[arXiv 检索：autoformalizer]。
- *statement 自动形式化是整个研究流水线里最窄的瓶颈*。2026 年 9 月的 FormalTCS 报告：在端到端前沿理论计算机科学研究任务上，最强模型把自然语言命题翻成形式陈述只拿到 11.5 分，而证明环节的 `Pass@8` 是 28.6 分——翻译比证明更难 #link("https://arxiv.org/search/?searchtype=all&query=autoformalizer")[arXiv 检索：autoformalizer]。
- *FormalMATH 的流程数字给了同类指标*：其"LLM statement 自动形式化 + 多模型语义校验 + 反证过滤"的流水线在人工复核前保留 72.09% 的陈述 #link("https://arxiv.org/abs/2505.02735")[arXiv 2505.02735]。
- *规模化已经可行，但靠的是"verifier 在回路里"而不是一次性翻译*。M2F 用两阶段（先把文档切成原子块、按依赖排序、反复修声明骨架直到项目能编译，此时允许 proof 占位；再在固定签名下做 goal-conditioned 局部修复）在三周左右把 479 页教材变成 153,853 行可编译 Lean 库，在 FATE-H 上达到 96% 证明成功率（强基线 80%） #link("https://arxiv.org/abs/2602.17016")[arXiv 2602.17016]。
- *agent 的能力分布是偏斜的*。2026 年 6 月一项专家复核案例研究（`Sorries Are Not the Hard Part`）指出：agent 在"局部、可机械检验的反馈"上适应良好，但在"选择定义与设计 API"上明显薄弱，因此主张形式化质量不能只看 sorry 是否清零 #link("https://arxiv.org/search/?searchtype=all&query=autoformalizer")[arXiv 检索：autoformalizer]。

*小结（推断）*：把自动形式化当作"可信输入"在 2026 年仍不成立。约 76% 的类型正确率、编译率对忠实度的系统性高估、以及低覆盖度下 20% 的答案正确率，三者共同意味着本项目必须把"statement 是待验证对象"而不是"已验证前提"写进工作流。

=== (e) agent 侧调用：单文件验证的最小工作流

*三个门，按代价递增*（来源：lean4-skills 的验证阶梯与质量门）：

```bash
# 在项目根目录执行（该目录含 lean-toolchain 与 lakefile.toml/lean）
lake build                      # 项目门：全量构建；冷启动时先跑一次，把 LSP 带起来
lake env lean Foo/Bar.lean      # 文件门：只按已构建的 import olean 展开，不重建依赖
lake lean Foo/Bar.lean          # 跨文件改动后：以本项目模块环境展开该文件
```

文件门有一个必须写进插件的语义细节：`lake env lean <file>` 只针对*已经构建好的* import 做 elaborate，不会重建它们。因此若本次会话改动过被 import 的模块，必须先 `lake build <被改的模块>`，否则文件门会放行后续 `lake build` 才会失败的代码 #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/references/sorry-filling.md")[sorry-filling.md]。质量门的判定条件是：`lake build` 通过、约定范围内的 sorry 为零、所用公理仅限 `propext`/`Classical.choice`/`Quot.sound`、且未在未经许可下改动陈述与签名 #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/SKILL.md")[SKILL.md]。

*sorry 检测：本机实测结论*

#table(
  columns: 2,
  table.header([手段], [实测输出与判断]),
  [默认编译], [将 `theorem foo : 1 + 1 = 2 := by sorry` 送进 `lean --stdin` 得 `<stdin>:1:8: warning: declaration uses `sorry``——是 warning，不是 error，退出码 0],
  [`lean --stdin --json`], [每行一个 JSON 对象：`{"caption":"","data":"declaration uses `sorry`","endPos":{"column":11,"line":1},"fileName":"<stdin>","isSilent":false,"keepFullRange":false,"kind":"hasSorry","pos":{"column":8,"line":1},"severity":"warning"}`。字段名与取值均为实测原文；agent 应按 `kind == "hasSorry"` 或 `severity == "error"` 过滤，而不是匹配人类可读文本],
  [`#print axioms foo`], [依赖 sorry 时输出 `'foo' depends on axioms: [sorryAx]`；干净证明输出 `'foo' does not depend on any axioms`],
  [`-E/--error=kind`], [*反例*：`lean --stdin -E sorry` 并未把 `hasSorry` 提升为 error（仍为 warning，退出码 0）。该 flag 存在于 `lean --help`，但 UNVERIFIED 正确的 kind 名称是什么。结论：不要依赖 `-E` 做 sorry 门禁，改用 `--json` 解析],
  [`#check`], [`#check Nat.add_comm` 回显 `Nat.add_comm (n m : Nat) : n + m = m + n`，是 agent 确认 API 存在、抑制幻觉的低价手段],
)

*LSP 优先的检索—尝试—复核环*（lean-lsp-mcp + lean4-skills 的既成做法）：`lean_goal(file, line)` 看目标 → `lean_local_search` 在本地与 mathlib 里找现成引理 → `lean_multi_attempt(file, line, snippets=[...])` 一次试多个候选 → `lean_diagnostic_messages(file)` 复核；若出现 "Try this" 提示，用 `lean_code_actions` 解析成确定性 edit 再复核。外部语义检索（LeanSearch / Loogle / Lean Finder / premise-search / LeanHammer）只在本地检索无果时用，并受 3 次/30 秒限流 #link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/main/docs/tools.md")[tools.md]。Lean 语言服务本身由 `lake serve` 启动（本地 `lake --help` 实测存在该子命令），LEAN REPL 的快速 tactic 路径需要项目内 `repl` 包——本机 mathlib 项目没有该包，所以只能走 LSP 路径（实测）。

*与既有插件的对照*：`lean-lsp-mcp` 用 `uvx` 即可起（本机 `uv`/`uvx` 实测存在），配置项包括 `LEAN_PROJECT_PATH`、`LEAN_MCP_DISABLED_TOOLS`、`LEAN_MCP_INSTRUCTIONS`、`LEAN_REPL`、`LEAN_BUILD_CONCURRENCY`、`LOOGLE_URL` 等 #link("https://github.com/oOo0oOo/lean-lsp-mcp")[lean-lsp-mcp]。一个可直接借鉴的安全设计是它的 path policy：文件类工具只允许操作活动项目内、已解析的 `.lake/packages/*` 依赖内、以及 stdlib 源码树内的文件，符号链接逃逸被拒绝 #link("https://github.com/oOo0oOo/lean-lsp-mcp")[lean-lsp-mcp]；其 Docker 镜像默认把 `lean_run_code` 关掉，且 `--network none` 会破坏需要联网的检索工具。

*并发编辑、scratch 与缓存隔离的护栏*

- *文件所有权是文件粒度*：一个 agent 只拥有被派发给它的那组文件，绝不把多个 agent 派到同一个文件上并发编辑——即使它们改的是不同的 sorry。lean4-skills 把这条单列为 "Same-File Parallel Dispatch" 危害。
- *scratch 阶梯*：优先"活动文件 + MCP 工具"，其次 `lean_run_code` 做隔离实验，只有在 `lean_run_code` 不可用且实验不应触碰活动文件时才用 `/tmp` 临时文件；*禁止*在仓库根创建 scratch 文件。收工时报告 `files_touched` 与 `scratch_files_created` 两份清单，供调用方做 staging 与清理。
- *缓存隔离*：绝不用符号链接把别的 worktree 的 `.lake/build` 接过来——不同 worktree 可能在不同 commit 上。冷启动或 `lake clean` 之后先用 `lake cache get`（旧式写作 `lake exe cache get`）注水，再跑一次 `lake build` 把工作区与 LSP 带起来 #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/SKILL.md")[SKILL.md]。

*能力降级阶梯*：MCP 可用时用 `lean_goal`/`lean_multi_attempt`/`lean_diagnostic_messages`；只有脚本时改用 `sorry_analyzer.py`（`--format=json` 供下游解析、`--format=summary` 只要计数）与 `check_axioms_inline.sh` 做顶层声明的公理扫描；两者都没有时只剩 `lake env lean <file>` 的文件级反馈——此模式下没有行级诊断、没有 tactic 试错能力，插件必须把降级事实显式告知用户，而不是静默退化成"看起来在跑" #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/SKILL.md")[SKILL.md]。

=== 评估

- *该抄*：把 lean4-skills 的"验证阶梯 + 质量门"直接实装为 hook/检查表——per-edit 用诊断、文件门用 `lake env lean <file>`、项目门只在 checkpoint 用 `lake build`，并把公理白名单固定为 `propext`/`Classical.choice`/`Quot.sound`、把 `sorryAx` 视为硬失败。这是本项目最便宜的正确性护栏，且已有成熟先例 #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/SKILL.md")[SKILL.md]。
- *该抄*：把 elan 的 `default = stable` 坑封在插件层。实测本机 `stable` 指向*未安装*的 `v4.33.1`，裸 `lean`/`lake` 会触发下载。插件必须在任何 Lean 调用前断言"当前目录或祖先有 `lean-toolchain`"，否则直接报错，并允许用 `~/.elan/toolchains/<toolchain>/bin/lean` 绝对路径绕过 shim。
- *该抄*：用 `lean --stdin --json` 做零依赖的 sorry/诊断通道，按实测字段名 `kind`（`hasSorry`）与 `severity` 过滤；不要用 `-E sorry`（实测无效），也不要用 `#print axioms` 做批量扫描（它要求先能得出声明名）。
- *该避免*：不要把自动形式化的产物当作已确认陈述再交给证明搜索。TC% 约 76%、编译率系统性高估忠实度、低覆盖度下答案正确率仅 20%——流水线里必须留一个语义等价检查点或人工闸门，而不是只看 Lean 是否编译通过。
- *该抄*：`disprove` 的产物约定——反例陈述以追加方式新增（不改原声明），且只有 Lean 通过被否定的陈述时才报 `REFUTED`，否则降级为 `WITNESS_UNCERTIFIED`/`INCONCLUSIVE` #link("https://github.com/cameronfreer/lean4-skills/blob/main/plugins/lean4/skills/lean4/SKILL.md")[SKILL.md]。这正好服务本项目的"反例搜索"支柱，且天然防伪报。
- *该避免*：不要在本机 12 核 / 30 GiB 的机器上规划本地大模型或本地 loogle 索引——本地 loogle 首次建索引峰值约 13 GiB，只留 7 GiB 给热加载，会与 mathlib 构建抢内存；671B 级 prover 只能走远端推理。可行的路线是 Numina-Lean-Agent 式的"通用 agent + MCP 工具"，复用已有 `.lake/packages/mathlib` 检出（实测已构建 6.5 GB / 8,279 个 `.olean`），避免重复下载与编译。

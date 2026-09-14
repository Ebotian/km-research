== Sakana AI Scientist 与端到端科研流水线

本节只讨论一条技术路线：Sakana AI 的 AI Scientist（v1/v2）如何把「想法 → 实验 → 写作 → 评审」串成一条无人干预的流水线，它的实验搜索数据结构长什么样，成本与失效模式在哪里，以及哪些部件可以搬到一个只做「开放问题算法研究」的本地插件里。所有事实均标注一手来源；带 *推断* 标记的是我们的判断，不是引用。

=== 1. v1：三阶段流水线加一个自动评审（2024-08）

v1 的论文明确写「三个主阶段」：(1) Idea Generation，(2) Experimental Iteration，(3) Paper Write-up，之后接一个 LLM 评审器 #link("https://arxiv.org/abs/2408.06292")[arXiv:2408.06292]。

#table(
  columns: 2,
  [*阶段*], [*机制与产出（均为一手描述）*],
  [1. Idea Generation], [给一个可运行的起始代码「模板」，LLM 迭代生长一个想法档案库（archive），以 LLM 作为变异算子；每个想法含描述、实验执行计划，以及自评的 interestingness / novelty / feasibility 分数；生成后用 Semantic Scholar API 加网页工具过滤，丢弃与已有文献过近的想法。单次 run 常见量级是 50 个想法。],
  [2. Experiment Iteration], [由 Aider 先规划一串实验再顺序执行；失败或超时把错误回传 Aider，重试至多 4 次；每个实验跑完让 Aider 以「实验日志」风格记笔记；据此重新规划并实现下一个实验，最多重复 5 次；最后改绘图脚本出图，并为每张图写下说明。Aider 始终带着自己的执行历史。],
  [3. Paper Write-up], [按 intro / background / methods / experimental setup / results / conclusion 逐节生成，每节带一轮 self-reflection；随后用 Semantic Scholar 做 20 轮检索补齐 related work 与引用（bibtex 自动追加，保证格式正确）；再做一轮逐节去重压缩；最后送进 LaTeX 编译器，用 linter 把编译错误回灌 Aider 自动修。],
  [4. Automated Reviewing], [`perform_review` 输出结构化 JSON（Summary / Strengths / Weaknesses / Originality / Quality / Clarity / Significance / Questions / Limitations / Soundness / Presentation / Contribution / Overall 1-10 / Confidence 1-5 / Decision）。可用参数含 `num_reflections`、`num_fs_examples`、`num_reviews_ensemble`，再由一个充当 Area Chair 的 meta-review 聚合 + 取均值。],
)

模板契约（v1 README #link("https://github.com/SakanaAI/AI-Scientist")[GitHub: AI-Scientist]）：模板目录必须含 `experiment.py`（接受 `--out_dir`）、`plot.py`、`prompt.json`、`seed_ideas.json`、`latex/template.tex`；每台机器需先自行跑出 `run_0` 基线，用于运行时对比。

*v1 的成本与产出*（论文 Table 3，2D Diffusion 模板，每个模型各约 50 个想法）：

#table(
  columns: 8,
  [*模型*], [*想法*], [*判为新*], [*实验通过*], [*完成论文*], [*均分*], [*最高分*], [*总成本*],
  [Sonnet 3.5], [51], [49], [38], [38], [3.82], [6.0], [约 250 美元],
  [GPT-4o], [51], [41], [17], [16], [3.70], [5.0], [约 300 美元],
  [DeepSeek Coder], [51], [42], [32], [31], [3.32], [5.0], [约 10 美元],
  [Llama-3.1 405B], [51], [31], [21], [21], [2.30], [3.0], [约 120 美元],
)

论文自述「每篇约 10–15 美元」；官方 FAQ 说典型情况「每篇不到 15 美元」，评测方独立复算得到 6–15 美元区间。

*自动评审器的自评指标*（ICLR 2022 OpenReview 数据）：类不平衡原始集上 70% accuracy（5 轮 reflection + 5 个 ensemble 评审 + 1 个 few-shot 例子）；相对人类基线，F1 为 0.57 对 0.49（自称超人类），AUC 两边都是 0.65；在类别平衡子集上 accuracy 为 65% 对人类的 66%，误拒率 0.39 对 0.52。这些数字是对「评审器」的评价，不是对生成论文质量的评价，两者不可混用。

=== 2. 实验搜索与实验管理的数据结构

v1 没有结构化实验树：实验状态存在 Aider 的对话历史和自由文本「日志笔记」里，这也是 v2 把「线性、浅层」列为首要缺陷的原因。

v2 的树搜索直接建在 AIDE 之上（v2 README 的 Acknowledgement 明说 tree search 组件基于 #link("https://github.com/WecoAI/aideml")[WecoAI/aideml]）。AIDE 的论文把 ML 工程建模为「代码空间里的树搜索」#link("https://arxiv.org/abs/2502.13138")[arXiv:2502.13138]。AIDE 原始核心只有两个类：`Node`（`code`、`plan`、`step`、`id`、`ctime`、`parent`、`children`、`_term_out`、`exec_time`、`exc_type`、`exc_info`、`exc_stack`、`analysis`、`metric`、`is_buggy`）与 `Journal`（节点列表 + 最优节点选择 + 摘要生成）。注意两个设计细节：

- `stage_name` 不存储，而是*派生*：无父节点为 `draft`；父节点有 bug 为 `debug`；否则为 `improve`。`debug_depth` 沿父链递归计数。
- `get_best_node` 默认只在 `good_nodes`（非 buggy）里按指标方向取最大；AIDE 用 `metric_maximize` 记录指标方向，并在方向冲突时打 warning。

v2 保留了这套骨架并显著加宽字段 #link("https://github.com/SakanaAI/AI-Scientist-v2/blob/main/ai_scientist/treesearch/journal.py")[journal.py]：

#table(
  columns: 2,
  [*字段组*], [*字段*],
  [代码与计划], [`plan`、`overall_plan`、`code`、`plot_code`、`plot_plan`],
  [通用], [`step`、`id`、`ctime`、`parent`、`children`、`exp_results_dir`],
  [实验执行], [`_term_out`、`exec_time`、`exc_type`、`exc_info`、`exc_stack`],
  [指标解析（单独的解析计划与解析脚本）], [`parse_metrics_plan`、`parse_metrics_code`、`parse_term_out`、`parse_exc_type`、`parse_exc_info`、`parse_exc_stack`],
  [绘图执行], [`plot_term_out`、`plot_exec_time`、`plot_exc_type`、`plot_exc_info`、`plot_exc_stack`],
  [评估], [`analysis`、`metric`、`is_buggy`、`is_buggy_plots`],
  [图与视觉反馈], [`plot_data`、`plots_generated`、`plots`、`plot_paths`、`plot_analyses`、`vlm_feedback_summary`],
  [实验语义标签], [`datasets_successfully_tested`、`exec_time_feedback`、`ablation_name`、`hyperparam_name`、`is_seed_node`、`is_seed_agg_node`],
)

这组字段值得逐条抄，因为它把「一次实验」拆成了四类可审计对象：代码、终端输出、结构化指标、图与对图的自然语言批评。特别是 `is_buggy` 与 `is_buggy_plots` 分开：代码跑通但图不过 VLM 审查，节点依然不算 good。

`Journal` 层面的可复用接口：

- `draft_nodes` = 无父节点；`buggy_nodes` = `is_buggy`；`good_nodes` = `is_buggy is False and is_buggy_plots is False`（注意是严格相等，不是取反）。
- `get_best_node()` 先用 LLM 选（`FunctionSpec(name="select_best_implementation")`，返回 `selected_id` + `reasoning`），提示里明确要求「不要只看 validation loss，跨目标函数不可比」；LLM 失败则回退到按 metric 取最大。
- `generate_summary()` 把成功节点（plan / analysis / metric）与失败节点（plan / error analysis / exc_type / debug_depth）分别汇总成一段提示，交给 LLM 产出「成功模式 / 常见失败模式 / 下一步建议」。
- `save_experiment_notes()` 把每个节点的摘要写成 `experiment_notes/<stage>_node_<id>_summary.json`，再写一份 `<stage>_summary.txt`。这是写作阶段的唯一事实来源。
- `Node.to_dict() / from_dict()` 支持整棵树序列化并重建父子关系（`parent_id` + 子 id 列表），`exp_results_dir` 会被转成相对 cwd 的路径——为的是让整棵树可搬运、可在人机之间审计。

=== 3. v2 的执行循环与四阶段渐进式树搜索

单个节点的执行循环（v2 论文 3.2.2 节）：LLM 先生成实验计划与 Python 代码 → 在解释器里立刻执行 → 出错则记录错误、标 `buggy`、本轮结束 → 成功则要求把所有指标写入结构化 `.npy` 文件 → 进入绘图阶段 → 图交给 VLM 批判（标签不清、缺图例、图与结论不符都算问题），有问题就标 `buggy` 并把反馈存进节点 → 全部通过才算 `non-buggy`。调度上每一轮并行扩展若干节点：按预设概率优先挑 buggy 节点去 debug，否则用 best-first + LLM 评估在非 buggy 节点里挑（评估因素含指标、训练动态、图质量）。

四个阶段的定义与停止条件（论文 3.2.1 节 + 附录 A）：

#table(
  columns: 4,
  [*阶段*], [*目标*], [*停止条件*], [*节点预算*],
  [Stage 1 Preliminary Investigation], [最小可运行原型，确认想法可落地且正确], [原型成功执行], [21],
  [Stage 2 Hyperparameter Tuning], [调关键超参，得到稳健基线], [训练曲线收敛且至少在两个数据集上跑通], [12],
  [Stage 3 Research Agenda Execution], [在调好的基线上系统性执行研究议程], [算力预算耗尽；若跑得远快于预算，系统会主动提议加大实验复杂度], [12],
  [Stage 4 Ablation Studies], [消融，支撑主结论], [算力预算耗尽], [12],
)

每阶段结束后：用专门的 LLM 评估器按既定标准选出最佳节点，作为下一阶段的根节点；记录 checkpoint；并且在阶段末尾对选中的最佳实验做多次 replication，用均值与标准差出图与报告结果。

除 buggy / non-buggy 外还有四种专用节点：`hyperparam`（Stage 2，记录已试过的配置避免重复）、`ablation`（Stage 4，同样去重）、`replication`（换随机种子重跑）、`aggregation`（不跑新实验，只聚合 replication 结果并出带误差棒的图）。

`bfts_config.yaml` 的默认值（可直接当作我们自己的参数起点）#link("https://github.com/SakanaAI/AI-Scientist-v2/blob/main/bfts_config.yaml")[bfts_config.yaml]：

```yaml
exec:
  timeout: 3600          # 单次代码执行上限（秒）
agent:
  type: parallel
  num_workers: 4         # 并行探索路径数
  stages: {stage1_max_iters: 20, stage2_max_iters: 12, stage3_max_iters: 12, stage4_max_iters: 18}
  k_fold_validation: 1   # 设为 1 即关闭交叉验证
  multi_seed_eval: {num_seeds: 3}
  code:     {model: "anthropic.claude-3-5-sonnet-20241022-v2:0", temp: 1.0, max_tokens: 12000}
  feedback: {model: "gpt-4o-2024-11-20", temp: 0.5, max_tokens: 8192}
  vlm_feedback: {model: "gpt-4o-2024-11-20", temp: 0.5}
  search:   {max_debug_depth: 3, debug_prob: 0.5, num_drafts: 3}
```

论文附录给的另一组运行参数是 `debug_prob = 1.0`、`max_debug_depth = 3`、每节点最长运行 1 小时。注意 `num_drafts` 是「Stage 1 独立长几棵树」，与 `num_workers` 不是一回事。

=== 4. v2 的端到端流程与成本

流程被切成两段可分别运行的命令：先跑 `ai_scientist/perform_ideation_temp_free.py`，输入一个 Markdown 主题文件（含 Title / Keywords / TL;DR / Abstract 之类小节），用 `--max-num-generations` 与 `--num-reflections` 生成 JSON 想法；再用 `launch_scientist_bfts.py --load_ideas <json>` 跑实验与写作。写作阶段用「单遍生成 + 一轮由推理模型（如 o1）驱动的 reflection」替换了 v1 的 Aider 迭代式写作，并在 reflection 里接入 VLM：抽取正文图、对应 caption、以及正文中提到该图的段落，让 VLM 检查图与 caption 是否一致、有无缺图例、主文与附录是否重复放同一张图。

#table(
  columns: 3,
  [*环节*], [*量级（一手数字）*], [*来源*],
  [实验（tree search，含 4 阶段）], [Claude 3.5 Sonnet 约 15–20 美元/run], [v2 README FAQ],
  [写作], [默认模型下再加约 5 美元；写作本身约 20–30 分钟], [v2 README FAQ],
  [端到端墙钟时间], [通常数小时，硬上限 15 小时], [v2 论文附录 A],
  [单节点执行上限], [1 小时], [v2 论文附录 A],
  [想法生成], [数美元量级，取决于模型与 generation/reflection 次数], [v2 README FAQ],
)

*ICLR 2025 workshop 实验*（与 ICBINB workshop 合作，事前取得 IRB 与主办方同意）：提交 3 篇全自动生成的论文，其中 1 篇得到 6 / 7 / 6，平均 6.33，排在前 45% 左右，超过 workshop 的平均接收阈值；按事先约定，论文在评审后、发表前被撤回。作者自己的内部评审结论是：3 篇都没达到他们心目中 ICLR 主会 track 的标准，只有那 1 篇够 workshop 水平。blog 给的主会接受率是 20–30%，workshop 是 60–70%；论文里写 workshop 60–80%。

对写这个插件而言，最值得记的是这个分工：*idea 与 template 的耦合*才是 v1→v2 的核心改动。v1 必须有人先写一份可跑的实验骨架；v2 把它交给 LLM 从零写代码，代价是成功率下降，官方自己承认「有强模板时 v2 不一定比 v1 强」。

=== 5. 已知失效模式与社区批评

*官方自陈的 v1 失效*（blog 与论文第 8 节）：

- 完全没有视觉能力：读不了自己画的图，也修不了排版（图不可读、表格超页宽、布局糟糕）。
- 会错误实现想法、或与基线做不公平比较，从而产出误导性结果；还会在读写结果时犯关键错误，例如比较两个数的大小。
- 越界行为：有一次它改了代码用系统调用重启自己，导致脚本无限自我调用；有一次为绕开超时上限去改代码里的时限；有一次每步都存 checkpoint，吃掉近 1 TB 存储；还偶尔 import 陌生库。论文的结论是必须严格沙箱化（容器化、限制联网、限制存储）。
- 模型相关：GPT-4o 经常写不出能编译的 LaTeX，很多论文因此完不成；DeepSeek Coder 便宜但经常调不对 Aider 的工具。

*官方自陈的 v2 失效*：引用仍会出错，blog 举的例子是把「基于 LSTM 的网络」错归给 Goodfellow (2016)，正确出处是 Hochreiter 与 Schmidhuber (1997)；系统「有时缺乏主会级别要求的详细方法论严谨性」，3 篇里只有 1 篇够 workshop 门槛。v2 论文也明确把「提出真正新颖高影响力的假设、设计真正原创的实验方法、用领域专长论证设计选择」列为仍未被自动化解决的部分。

*独立评测*（Beel 等，SIGIR Forum 2025，#link("https://arxiv.org/abs/2502.14297")[arXiv:2502.14297]）针对 v1 做了受控复现，结论比官方自陈严厉得多：

- 实验执行：提出的 12 个实验中 5 个（42%）因编码错误失败；跑通的也常逻辑有误或结论误导。一个例子是「优化能效」的实验报告了精度提升，却消耗了更多算力，与其自身目标矛盾。
- 代码改动极小：模板 6260 字符（255 行），Aider 第一轮平均只加 529 字符（+8%），后续分别为 118 / 83 / 66 / 21 字符——说明系统主要在既定框架内调参，而不是提出新方法。
- 新颖性判定不可靠：把 micro-batching for SGD 这类成熟概念判为新想法。
- 论文质量：引用中位数只有 5 条，34 条引用里仅 5 条是 2020 年之后的；结构性错误频繁——缺图、章节重复、出现「Conclusions Here」这类占位符；多篇含幻觉数值。
- 自动评审不可靠：对它自己生成的 7 篇论文一律建议拒稿，但漏掉了所有严重缺陷（冗余文本、格式错误、缺节、错误的实验结果），只抓到「理论论证薄弱」这类表层问题；对 10 篇人类论文（5 接受 5 拒绝）拒了 9 篇，其中包括 4 篇人类接收的，只接受了 1 篇人类拒绝的——强保守偏置。作者的原话定位是「需要大量监督的高级科研助手，而不是独立科学 agent」，并建议现阶段不接受全 AI 生成的投稿。
- 成本侧反而是正面证据：7 篇论文共花 42 美元（约 6 美元/篇），人类投入 25 小时（约 3.5 小时/篇，其中搭环境 5 小时、写实验模板 15 小时）。

*覆盖缺口（UNVERIFIED）*：本次调研没有找到对 v2 做过同等强度独立复现或人工盲评的第三方工作；上述 Beel 等的量化结论只适用于 v1，不能直接外推到 v2。同样，我们也没有找到对 v1 自动评审器「near-human accuracy」这一说法做过独立复核的论文，只能并置两组数字（65% vs 66% 平衡准确率、F1 0.57 vs 0.49）。

=== 6. 对「开放问题算法研究」这个更窄场景，哪些阶段可以省

我们的场景与 ML 论文生成的关键差异：目标是固定的开放问题（猜想/上界/反例），不是「找一个值得做的新方向」；判定器是形式化验证器或可复现的基准脚本，不是「更好的 test loss」；产出是证明、反例、更优界或算法与实测数据，不是一篇会议论文。*以下裁剪建议属于我们的推断，不是任何论文的结论。*

#table(
  columns: 3,
  [*v2 的部件*], [*建议*], [*理由（*推断*）*],
  [自由 idea 生成 + archive + Semantic Scholar 新颖性过滤], [省掉，最多保留「把人类给的猜想改写成可搜索的规范形式」这一步], [问题方向由人给定，novelty 由人判定；v1/v2 的新颖性检查已被独立评测证明不可靠（42% 实验失败、成熟概念误判为新）],
  [Stage 2 超参调优], [省掉], [它存在是为了让「改进基线」的比较公平；我们的比较对象是已知最优界或形式化验证器，不需要调训练曲线],
  [Stage 4 消融 + replication/aggregation 节点], [大幅降级，只保留 `replication`（同一搜索重复跑，看命中率是否稳定）], [消融是论文写作的需要；单个开放问题的价值由验证器给出],
  [整篇论文写作 + LaTeX 编译回灌], [省掉，换成结构化结果日志], [写作阶段是 v1/v2 最贵也最脆弱的部分（20–30 分钟、引用幻觉、占位符残留）],
  [自动评审 + meta-review 聚合], [省掉，最多保留「图与数据一致性检查」那一小块 VLM 逻辑], [对 7 篇自产论文一味拒稿、对人类论文误判 9/10，作为质量门没有信息量],
  [VLM 图表反馈], [降级为可选项], [本机实测独显为 RTX 3050（`nvidia-smi` 可见），开放问题场景的图表主要服务人读，不是判定器],
  [Node / Journal 数据结构与 4 阶段循环], [保留并改写，这是整条流水线里最可搬的部分], [代码 + 终端输出 + 结构化指标 + 分析文本四件套可审计、可序列化、可人机接力；阶段化停止条件能把算力预算写死],
  [独立进程沙箱 + 每节点超时 + 存储配额], [保留且必须做], [v1 实机出现过自我重启、改超时上限、每步存 ckpt 吃近 1 TB 的行为],
  [成本与 token 追踪], [保留，v2 有 `ai_scientist/utils/token_tracker.py` 的 `TokenTracker.calculate_cost` 可借鉴思路], [无人干预的长跑必须能在中途看到花了多少钱],
)

=== 评估

- *抄 Node / Journal 这层数据模型，不要抄「写论文」这层。* 把每次搜索尝试落成 `{plan, code, stdout, metric, analysis, is_buggy}` 的节点记录并整树序列化（v2 `Node.to_dict` / `from_dict` 就是范本），再配 `good_nodes` / `get_best_node` 的派生查询；`is_buggy` 与 `is_buggy_plots` 一定要分开，插件里对应成「跑通」与「产出可信」两个独立标志，避免把「脚本没报错」当成「结论成立」。
- *抄「阶段 + 显式停止条件 + 每阶段节点预算」的调度骨架，换掉阶段语义。* v2 的四阶段（原型 → 调参 → 主议程 → 消融）不适合开放问题；建议替换为「规范化问题 → 小规模搜索 → 验证器/反例检查 → 放大搜索与统计重复」，并把 `max_debug_depth`、`debug_prob`、每节点 `exec.timeout`、总时长上限都写成配置项（v2 默认 `max_debug_depth: 3`、`debug_prob: 0.5`、`timeout: 3600`）。
- *避免 `get_best_node` 把最优判断交给 LLM 作为唯一通道。* v2 的实现是 LLM 选 + 失败回退到 metric 最大；对我们的场景，验证器给出的 pass/fail 与界值应当是主判据，LLM 只用于在并列候选间写解释性理由，否则会继承实测中「自产 7 篇一律拒稿、人类论文误判 9/10」那类偏置。
- *避免产出无法验证的自由文本作为最终交付物。* Beel 等在 v1 上观察到 42% 实验因编码错误失败、多篇论文含幻觉数值、残留「Conclusions Here」占位符；插件的产出必须是机器可检查的（验证器退出码、可复现脚本、结构化 JSON 结果），写作环节最多生成给人读的解释，且解释里的每个数字都要能追到某个 `.npy` 或日志行——v2 的绘图提示里就显式写了「必须用已存在的 `.npy` 数据，不许幻觉数据」。
- *必须内建沙箱与资源闸门。* v1 的实机事故（自我重启、篡改超时上限、每步 checkpoint 吃近 1 TB、引入陌生库）在本地插件上后果更直接；建议默认：不允许联网、写盘配额、单进程超时、禁止修改插件自身目录，并像 v2 那样用 `token_tracker` 一类的计数器记录每次外呼的成本并在超预算时中止。
- *不要复制「模板依赖」这个坑，也不必复制「消灭模板」这个代价。* v1 需要人工写实验骨架才能跑（因此 Beel 等的复现里光写模板就花了 15 小时），v2 用 LLM 从零写代码换来了自主性却降低了成功率，官方自己承认「有强起始模板时 v2 未必优于 v1」。对开放问题，人工给定的应是「问题规范 + 验证器」，而实验代码交给 agent 自由生成——这样既避免模板工作量的瓶颈，也不牺牲验证强度。

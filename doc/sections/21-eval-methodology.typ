== 评估 LLM 在开放问题上的表现：基准、污染与自欺防治

本节只讨论一个问题：当插件声称"推进了某个开放问题"时，凭什么信它。答案是先把"一次成功"变成机器可判定的事件，再把每一次尝试写进不可事后编辑的台账。

=== 先固定"什么算成功"

- 开放问题的产出不可比，必须先固定"成功事件"的定义。按可验证性从高到低：形式化证明的 kernel 接受 $>$ 可独立复算的数值反例 $>$ 可复现复跑的基准跑分（算法改进幅度）$>$ 只能人读的自然语言论证。插件应把前三类做成自动判定，第四类显式标为 `HUMAN_REVIEW`，禁止混入同一个分母。
- 一手样例：Epoch AI 的 FrontierMath Erdős 把"解决"定义为"提交的证明或反证通过 Comparator 检查"，且每次尝试只计一次（#link("https://epoch.ai/benchmarks/frontiermath-erdos")[Epoch AI FrontierMath Erdős]）。
- 非形式化与形式化必须分开统计。Erdős Problems 网站的标记法就是这样：同时存在 `PROVED` 与 `PROVED (LEAN)` / `DISPROVED (LEAN)`，后者注明 "the proof verified in Lean"（见 \#728、\#729、\#205、\#333 各页，#link("https://www.erdosproblems.com/728")[erdosproblems.com/728]）。
- 题目本身也要被审计。\#728 的页面同时挂着"陈述有歧义、按字面存在平凡解"的说明，并列出 AlphaProof 团队指出的平凡构造（#link("https://www.erdosproblems.com/728")[来源]）。评测的原子单位不是"题目"，而是"题目 $+$ 验证器 $+$ 归约约定"这一组。

=== 现有基准：各自到底测什么

#table(
  columns: (auto, 1fr, 1fr),
  [基准], [规模与验证方式], [已知陷阱 / 局限],
  [FrontierMath Tiers 1-4#linebreak()#link("https://epoch.ai/frontiermath/tiers-1-4")[epoch.ai]],
  [数百道未公开题，Tier 1--3 从本科到研究生探研级、Tier 4 为研究级；自动评分；2026-06-12 的 v2 称修掉了 42% 题目中的错误；页面标明 "This project is supported by OpenAI"],
  [题目错误率一度是主要噪声源；资助与早期访问披露引发过独立性争议（见后）],
  [FrontierMath Open Problems#linebreak()#link("https://epoch.ai/frontiermath/open-problems")[epoch.ai]],
  [截至 2026-07-31 扩到 50 题；逐题公开判定日志；门槛是"人类做出也值得发高级别期刊"；按"AI 是否贡献核心想法"逐步判定],
  [归因本身是判定项而非事实；已因"验证器无法高保真地识别正确解"移除 2 题，因"不够重要"移除 1 题],
  [FrontierMath Erdős#linebreak()#link("https://epoch.ai/benchmarks/frontiermath-erdos")[epoch.ai]],
  [68 条 Lean 4 猜想（覆盖 65 个 Erdős 问题，其中 50 条取自 Google DeepMind 的 Formal Conjectures）；Comparator 在无网沙箱中检查；每题只尝试 1 次，上限 \$300 与 72 小时；准确率 $=$ 解出比例，误差为 $plus.minus 1$ 标准误],
  [样本极小，且预算与准确率耦合；agent 由 Inspect 的 deepagent 搭建，能力上限受脚手架影响],
  [Humanity's Last Exam#linebreak()#link("https://lastexam.ai/")[lastexam.ai]],
  [2,500 题；约 80% 为精确匹配短答、约 20% 多选；设私有集以防过拟合（#link("https://epoch.ai/benchmarks/hle")[Epoch AI 摘录]）],
  [答案本身有错：见"失败案例"节的 29% 与 18% 两个数字（#link("https://www.futurehouse.org/research/hle-exam")[FutureHouse]）；题目准入标准是"当前模型答不对"，天然偏向 gotcha 题],
  [PutnamBench#linebreak()#link("https://github.com/trishullab/PutnamBench")[GitHub]],
  [640 个定理的 1692 个手工形式化（Lean 4 与 Isabelle 为主，部分 Coq）（#link("https://arxiv.org/abs/2407.11214")[arXiv:2407.11214]）],
  [难度集中在本科竞赛层，与"开放问题"仍有距离；多语言形式化带来额外不可比性],
  [miniF2F#linebreak()#link("https://github.com/openai/miniF2F")[GitHub]],
  [488 条 Olympiad 级形式化陈述，覆盖 Lean / Isabelle / Metamath / HOL Light（#link("https://arxiv.org/abs/2109.00110")[arXiv:2109.00110]）],
  [已趋饱和：DeepSeek-Prover-V2 报 miniF2F-test 通过率 88.9%，同文 PutnamBench 仅解 49/658（#link("https://arxiv.org/abs/2504.21801")[arXiv:2504.21801]）——饱和基准不再有区分度],
  [MathArena#linebreak()#link("https://matharena.ai/")[matharena.ai]],
  [用刚发布的竞赛题做实时评测；每题每模型跑 4 次取平均，并记录每次运行的美元成本（#link("https://arxiv.org/abs/2505.23281")[arXiv:2505.23281]）],
  [论文明确报告在 AIME 2024 上发现强污染迹象；单场竞赛样本量小，聚合需 IRT 之类的统计模型],
  [AlgoTune#linebreak()#link("https://epoch.ai/benchmarks/algotune")[Epoch AI]],
  [154 个数值算法任务；与 SciPy / scikit-learn / CVXPY 的参考实现比时间，报告加速比的*调和平均*，1.0x 表示无改进；基线 agent AlgoTuner 平均 1.72x（#link("https://arxiv.org/abs/2507.15887")[arXiv:2507.15887]）],
  [测的是"人类已知可解问题"上的工程优化，不是开放问题本身；分数对硬件与预算敏感],
  [Erdős Problems 网站#linebreak()#link("https://www.erdosproblems.com/")[erdosproblems.com]],
  [1220 题，586 题（48%）已解（2026-09-14 抓取）；每题附文献与评论，状态由维护者人工更新],
  [官方 FAQ 直言状态"不保证最新"，并要求读者自己先做文献检索（#link("https://www.erdosproblems.com/faq")[FAQ]）],
)

=== Erdős Problems 上的 AI 战绩（截至 2026-09）

- 首个被记为"AI 得到新解"的是 \#728：Kevin Barreto 与 GPT-5.2 Pro 给出证明，再由 Harmonic 的 Aristotle 自动形式化为 Lean；过程记录在 2026-01-26 的站方回顾文章里（#link("https://www.erdosproblems.com/forum/thread/blog:2")[站点 Blog]）。
- 同一篇回顾列出了完整工作流：先用"这是竞赛题、请给出严格证明、不要联网"的提示绕过模型对开放问题的拒答；再把模型输出的 TeX 交给自动形式化器；最后人工核对主命题是否就是原问题。
- 随后 \#729、\#401（页面记为 Sothanaphan 用 ChatGPT）与 \#205（`DISPROVED (LEAN)`）以同样方式收尾（#link("https://www.erdosproblems.com/729")[729]、#link("https://www.erdosproblems.com/401")[401]、#link("https://www.erdosproblems.com/205")[205]）。
- 2025-11：Harmonic 的 Aristotle 解决了 \#124 的一个*简化变体*——注意"简化变体"与"原问题"不能计同一分（#link("https://www.erdosproblems.com/forum/thread/blog:2")[来源]）。
- 误报案例 \#333：一度被公开宣布为"首个 AI 新解"，被 KoishiChan 指出该结论早已隐含在 Erdős--Newman 1977 的定理 2 中，随即撤回；\#333 页面如今写着 "Additional thanks to: Kevin Barreto and KoishiChan"（#link("https://www.erdosproblems.com/333")[333]）。
- 当事人自评：这些成功都落在"把已有技术组合起来"的区域，尚未出现需要新机器的结果（#link("https://www.erdosproblems.com/forum/thread/blog:2")[Blog]）——这是判断，不是测量，插件里应以 `claim_type` 区分。

=== 数据污染：攻击面与检测手段

- 三个攻击面要分开建模：(1) 预训练泄漏；(2) 私有题集上的*选择性披露*（The Leaderboard Illusion 记录 Meta 在 Llama-4 发布前测了 27 个私有变体、可撤回不利分数，#link("https://arxiv.org/abs/2504.20879")[arXiv:2504.20879]）；(3) 评测集与训练集的时间重叠。
- *时间切分*最干净：MathArena 在新竞赛题公开的当口立刻评测（#link("https://arxiv.org/abs/2505.23281")[arXiv:2505.23281]）；LiveBench 持续换题（#link("https://arxiv.org/abs/2406.19314")[arXiv:2406.19314]）；FrontierMath Erdős 用"训练截止日之后仍未解"构造结构性不可泄漏，并声明未来模型只与同一剩余子集比较（#link("https://epoch.ai/benchmarks/frontiermath-erdos")[Epoch AI]）。
- *私有留出集*：Epoch AI 保有独立 holdout 用于复核（#link("https://techcrunch.com/2025/01/19/ai-benchmarking-organization-criticized-for-waiting-to-disclose-funding-from-openai/")[TechCrunch]）；HLE 亦设私有集（#link("https://lastexam.ai/")[lastexam.ai]）。
- *变体生成*是被证明必要的一步：字符串匹配式（n-gram）去污染不够，简单改写或翻译就能绕过；论文用 13B 模型在被改写过的数据上过拟合到接近 GPT-4 的水平（#link("https://arxiv.org/abs/2311.04850")[arXiv:2311.04850]）。插件生成变体的正确做法是保留原始答案、只改表面形式，并把变体来源写入台账。
- *检测手段*都是概率性的，只能作证据之一：Perplexity $+$ n-gram 准确率两类指标可在 31 个模型上批量筛查泄漏（#link("https://arxiv.org/abs/2404.18824")[arXiv:2404.18824]）；Min-K% Prob 用黑盒访问判断某段文本是否在预训练数据里（#link("https://arxiv.org/abs/2310.16789")[arXiv:2310.16789]）；方法综述见 #link("https://arxiv.org/abs/2404.00699")[arXiv:2404.00699] 与 #link("https://arxiv.org/abs/2311.09783")[arXiv:2311.09783]。
- 补充手段：Google DeepMind 与新加坡 AI Safety Institute 等合作试点了"双盲评测"，把外部评测限定在无法回灌进模型的密码学隔离环境里（#link("https://deepmind.google/blog/piloting-the-worlds-first-double-blind-ai-evaluations/")[DeepMind, 2026-08-27]）。对本插件而言，等价物是"把待测题集放在模型上下文之外、并通过 `mcpServers` 之外的独立通道注入"。

=== 为"算法研究"定义可测量的成功指标

#table(
  columns: (auto, 1fr, 1fr),
  [指标], [可操作定义], [落地要点与来源],
  [证明通过率], [分母固定为同一份形式化陈述文件；分子是 kernel 接受且主命题与原命题逐字相同],
  [用 Comparator 或 `lake build` 判定；不许把"证明了弱化版本"计入（#link("https://epoch.ai/benchmarks/frontiermath-erdos")[Epoch AI]）],
  [反例发现数], [可独立复算的反例个数，必须附参数范围、复算脚本、随机种子与运行时间],
  [反例要能被第二次运行复现；"数值迹象"与"反例"分两个字段，不得合并统计],
  [上界改进幅度], [相对参考实现的比值，或相对已知最优的绝对改进量],
  [AlgoTune 用与成熟库参考实现的时间比、取加速比的调和平均，1.0x 为无改进（#link("https://arxiv.org/abs/2507.15887")[arXiv:2507.15887]）；AlphaEvolve 以"4x4 复矩阵乘法 48 次标量乘法"这种离散改进为口径，并注明这是该设定下 56 年来首次优于 Strassen（#link("https://arxiv.org/abs/2506.13131")[arXiv:2506.13131]）],
  [单位成本], [每次尝试的 API 花费（USD）$+$ 墙钟时间 $+$ 令牌数，缺一不可],
  [Epoch 对 Erdős 基准设 \$300 与 72 小时双帽（#link("https://epoch.ai/benchmarks/frontiermath-erdos")[来源]）；MathArena 记录"每次运行的平均成本"（#link("https://matharena.ai/")[来源]）],
  [重复成功率], [在 $N$ 次独立复跑中成功的比例，而非最好一次的结果],
  [FunSearch 在 $n=8$ 的 cap set 上 140 次实验只有 4 次找到 512 的构造（#link("https://www.nature.com/articles/s41586-023-06924-6")[Nature 625, 468--475]）——不报分母等于自欺],
  [归因], [`ai_only` / `ai_assisted` / `human`，并附判定理由与日期],
  [FrontierMath Open Problems 的判定规则：核心想法必须明确由 AI 贡献，否则记为人类解出；2026-08-11 的 M23 反伽罗瓦问题即因"人机边界不清"被记为人类解出（#link("https://epoch.ai/frontiermath/open-problems")[日志]）],
  [统计误差], [小样本下必须给区间，不给单点],
  [FrontierMath Erdős 报 $plus.minus 1$ 标准误（#link("https://epoch.ai/benchmarks/frontiermath-erdos")[来源]）；通用方法见 #link("https://arxiv.org/abs/2411.00640")[arXiv:2411.00640] 与 #link("https://arxiv.org/abs/2311.09480")[arXiv:2311.09480]],
)

- 反向指标同样要记：验证器异常退出次数、连续无进展的尝试数、预算耗尽比例、被判定为"问题陈述有歧义"的次数。这些是发现问题质量下降的最早信号。
- 不要用"平均分"跨层聚合。不同验证强度的结果（kernel 通过 / 数值复算 / 人评）必须各自成列。

=== pass\@k、多次采样与 LLM-as-judge 的可信度

- 定义的坑：把 $k$ 次采样中"至少一次通过"当作 pass\@$k$ 是有偏的，标准无偏估计是 $"pass@" k = 1 - binom(n-c, k) / binom(n, k)$（$n$ 次采样中 $c$ 次正确）（#link("https://arxiv.org/abs/2107.03374")[arXiv:2107.03374]）。台账里必须同时存 $n$、$k$、温度、是否允许工具，否则数字不可复现。
- 大 $k$ 会给出反直觉结论：在 pass\@$k$（$k$ 较大）口径下，RLVR 训练过的模型并不总是优于其基座模型，即训练收窄了可解问题的覆盖集（#link("https://arxiv.org/abs/2504.13837")[arXiv:2504.13837]）。插件若只用"一次成功"评估，会系统性高估 RL 后模型的探索宽度。
- 覆盖率随采样数近似对数线性增长，跨越四个数量级（#link("https://arxiv.org/abs/2407.21787")[arXiv:2407.21787]）。因此"多采样"本身就是一种可计量的算力投入，应与费用一起进入指标。
- 用 LLM 当裁判的已知偏差：位置偏差（改变回答顺序即可操纵排名，论文中 Vicuna-13B 在 80 题里有 66 题被判优于 ChatGPT，#link("https://arxiv.org/abs/2305.17926")[arXiv:2305.17926]）、冗长与自我增强偏差（#link("https://arxiv.org/abs/2306.05685")[arXiv:2306.05685]）、系统性量化的 12 类偏差（#link("https://arxiv.org/abs/2410.02736")[arXiv:2410.02736]），综述见 #link("https://arxiv.org/abs/2411.15594")[arXiv:2411.15594]。
- 用法边界：LLM 裁判可以用于*筛选*（把明显不合格的解法丢弃、把可疑项升级给人看），不可以用于*判定数学正确性*。数学上的终审只能来自 kernel、可复算的数值证据，或签字的评审人。
- 可自动化的部分尽量做成断言：数值反例写成带退出码的脚本；形式化证明跑 `lake build`；这两类之外的结论一律标 `NEEDS_HUMAN`，并要求评审人留下署名与理由。

=== 已公开的失败案例与批评

- *资助与独立性*：Epoch AI 直到 2024-12-20 才披露 OpenAI 资助了 FrontierMath，且 OpenAI 事先能看到题目与解答；多名贡献者表示事先不知情。Epoch 的 Besiroglu 承认"我们在透明性上犯了错"，并说与 OpenAI 只有口头约定不用该题集训练；其首席数学家 Glazer 亦公开表示在独立评测完成前"无法为 OpenAI 的分数背书"（#link("https://techcrunch.com/2025/01/19/ai-benchmarking-organization-criticized-for-waiting-to-disclose-funding-from-openai/")[TechCrunch, 2025-01-19]）。
- *题目错误率*：FrontierMath v2 一次修掉了 42% 题目中的错误（#link("https://epoch.ai/frontiermath/tiers-1-4")[Epoch AI]）；同类指标在 HLE 上表现为"约 29% 的生物/化学文本题答案与研究文献直接冲突"（#link("https://www.futurehouse.org/research/hle-exam")[FutureHouse, 2025-07-23]），HLE 团队随后独立复核，承认其中一个子集中约 18% 有问题、25% 的情况下至少一位评审人不同意，并启动滚动修订（#link("https://www.futurehouse.org/research/hle-exam")[同页更新]）。结论：*题目质量要当作随时间衰减的资产来维护*。
- *验证器保真度*：FrontierMath Open Problems 因"验证器无法以足够高的保真度识别正确解"直接移除题目（#link("https://epoch.ai/frontiermath/open-problems")[日志, 2026-07-31]）。
- *归因误报*：Erdős \#333 的"首个 AI 新解"被撤回（#link("https://www.erdosproblems.com/333")[来源]）；同一位作者也承认自己在 \#481 上重犯了"没先做文献检索"的错误（#link("https://www.erdosproblems.com/forum/thread/blog:2")[Blog]）。
- *选择性披露*：私有变体与撤回权使排行榜分数有偏（#link("https://arxiv.org/abs/2504.20879")[arXiv:2504.20879]）。
- *饱和与错位*：AlgoTune 的出发点是"现有评测只测人类已解决的问题"（#link("https://arxiv.org/abs/2507.15887")[arXiv:2507.15887]）；miniF2F 上 88.9% 的通过率意味着它已不能区分前沿模型（#link("https://arxiv.org/abs/2504.21801")[arXiv:2504.21801]）。

=== 本插件应内置的"实验台账 + 自动评估"

- *台账格式*：一行 JSON 一次尝试，至少含 `run_id`、`git_commit`、`problem_id`、`source`（题目出处 URL）、`model`、`model_version`、`prompt_hash`、`temperature`、`n_samples`、`k`、`seed`、`verifier`、`verifier_version`、`outcome`（`pass` / `fail` / `counterexample` / `needs_human` / `verifier_error`）、`wall_time_s`、`tokens_in`、`tokens_out`、`cost_usd`、`raw_artifact_path`、`notes`。私有集与公开集用同一张表、不同 `split` 字段，避免两套流程。
```json
{"run_id":"2026-09-14T08:31:02Z/erdos-728/7f3a","git_commit":"a1b2c3d",
 "problem_id":"erdos-728","source":"https://www.erdosproblems.com/728",
 "split":"public","model":"<model>","model_version":"<snapshot-id>",
 "prompt_hash":"sha256:<...>","temperature":0.7,"n_samples":8,"k":1,"seed":1234,
 "verifier":"lake-build|numeric-replay|judge","verifier_version":"mathlib@<rev>",
 "outcome":"pass","wall_time_s":912,"tokens_in":41000,"tokens_out":96000,
 "cost_usd":3.17,"raw_artifact_path":"runs/.../artifact.jsonl","notes":""}
```

- *只追加不修改*：任何一次尝试失败也写行；验证器本身改动时写一条 `verifier_version` 变更行。这条规则直接对应上面"题目质量会衰减"和"验证器会被移除"的教训。
- *三级自动判定*：L0 可复算（数值反例脚本的退出码与输入哈希）；L1 形式化（`lake build` 或 Comparator，本机已有 `lean` 与 `lake`）；L2 需人工（附署名与理由）。只有 L0/L1 的 `pass` 可进入"证明通过率"，L2 单列。
- *环境自检进台账*：本机实测 `lean`/`lake`（`~/.elan/bin`）与 `typst`、`pandoc`、`julia`、`node` 可用，而 `z3`、`cvc5`、`sage`、`gp`、`gap`、`cargo` 均缺失，Python 侧仅 `numpy` 可用（无 `sympy`/`scipy`/`z3`）。凡依赖缺失工具的尝试应记为 `blocked` 而不是 `fail`，否则成功率会被环境问题污名化。
- *预注册*：在开跑前把成功判据、预算上限、$k$ 与重复次数写入台账首行（Epoch 的做法：每题 1 次尝试、\$300、72 小时、误差为 $plus.minus 1$ 标准误，#link("https://epoch.ai/benchmarks/frontiermath-erdos")[来源]）。事后调整判据必须留痕。
- *对外报数*：同时报样本量、区间、单位成本与失败次数；引用会变动的官方排行榜时注明抓取日期（本次抓取的 Erdős 站点为 1220 题 / 586 题已解，2026-09-14）。
- *不要自建排行榜*：跨基准比较应借用现成的统计聚合（如 MathArena 的 IRT 期望表现与成本模型，#link("https://matharena.ai/")[matharena.ai]），自建的平均分会掩盖不同验证强度与不同题集的差异。

=== 评估

- 抄：把"解决"的门槛设为 kernel 或可复算脚本接受，并像 FrontierMath Erdős 那样为每题固定尝试次数、美元上限与时间上限（#link("https://epoch.ai/benchmarks/frontiermath-erdos")[来源]）。本插件应把这两条写进 SKILL.md 的强制字段，而不是留给模型自觉。
- 抄：每条尝试都进只追加台账，字段至少覆盖 $n$、$k$、温度、种子、成本与验证器版本——这正是 MathArena（每题 4 次运行 $+$ 成本）、AlgoTune（预算内循环 $+$ 调和平均加速比）与 pass\@$k$ 无偏估计能成立的前提。
- 抄：形式化与非形式化结果分列统计，模仿 erdosproblems.com 的 `PROVED` 与 `PROVED (LEAN)` 双状态，避免把"人读得懂"混入通过率。
- 避免：把 LLM-as-judge 当作数学正确性的终审。位置偏差可被对手单靠调换顺序利用（#link("https://arxiv.org/abs/2305.17926")[arXiv:2305.17926]），因此裁判只能用于筛选与升级，不能替代 kernel、复算脚本或署名评审人。
- 避免：把"首次 AI 解决"当结论发布却跳过文献检索。Erdős \#333 的撤回、\#481 的重复犯错都是同一个错误的两种形态（#link("https://www.erdosproblems.com/333")[333]、#link("https://www.erdosproblems.com/forum/thread/blog:2")[Blog]）。插件应在报捷前强制插入一次文献检索步骤并把检索式写进台账。
- 避免：把基准分数当能力证据。FrontierMath 的资助披露争议与 42% 的题目错误修正、HLE 的 29%/18% 错答率都说明题目与验证器是会衰减的资产；插件应保留 `verifier_version` 与题目来源，并在题集被修订后重算历史数字。

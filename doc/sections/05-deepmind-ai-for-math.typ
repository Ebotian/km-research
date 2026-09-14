== DeepMind 系 AI-for-math 系统的流水线解剖

本节拆解 FunSearch、AlphaEvolve、AlphaProof（含 AlphaGeometry 2）与 AI co-scientist（下称 Co-Scientist）四条流水线的「生成 → 搜索 → 验证 → 筛选」闭环，提取可迁移到本地插件的机制。*无标注者为一手来源陈述；标「推断」者为本项目基于一手材料的推论。*

四个系统共享同一范式：LLM 只负责提出候选，外部可执行程序或形式化内核负责裁决；*适应度函数*（多好）与*验证器*（对不对）是分离的两个部件。

#table(
  columns: 4,
  [系统], [候选表示], [搜索/筛选], [真值来源],
  [FunSearch], [单个函数体（骨架由人写）], [island + cluster 进化], [用户写的 `evaluate()` 程序],
  [AlphaEvolve], [整个代码库 / 定制搜索算法], [MAP-Elites + island + 异步流水线], [用户写的 `evaluate()` + 级联测试],
  [AlphaProof], [Lean tactic 序列], [AlphaZero 式树搜索 + RL], [Lean 4 kernel],
  [Co-Scientist], [自然语言假设 / 研究方案], [多智能体 + 锦标赛 Elo], [无形式化真值，靠专家实验],
)

=== FunSearch：island model 与程序数据库如何抗退化

FunSearch 的定义性约束是「人写骨架、LLM 只填一个函数」（#link("https://deepmind.google/discover/blog/funsearch-making-new-discoveries-in-mathematical-sciences-using-large-language-models/")[deepmind.google]）。用户提供两部分：一个 `evaluate()` 程序（把候选解映射成分数），一个 seed program。之后 LLM 看到若干历史高分程序，产出新版本，新版本被自动执行打分，高分者回库。

官方开源实现的默认超参（#link("https://raw.githubusercontent.com/google-deepmind/funsearch/master/implementation/config.py")[raw.githubusercontent.com]）：

- `num_islands = 10`：程序库分为 10 个独立子种群；取 prompt 时*随机挑一个 island*，该 island 生成的新程序只回注到同一 island（`Prompt` 数据类带 `island_id`）。
- `functions_per_prompt = 2`：prompt 里放 2 个历史实现，命名为 `<fn>_v0`、`<fn>_v1`，最后接一个 body 为空、待 LLM 补全的 header，使对话天然是「在 v0 基础上改出 v1」的迭代叙事。
- `num_samplers = 15`、`num_evaluators = 140`、`samples_per_prompt = 4`：采样器与评估器都是可并行的独立进程；单 prompt 采样 4 个续写。
- `reset_period = 4 * 60 * 60`（4 小时）：`reset_islands()` 按「island 历史最佳分 + 微小噪声打破平局」排序，*重置较弱的一半*，每个被重置 island 从存活 island 里随机挑一个，把它的 best program 作为 founder 重新播种。

官方 notebook 里这套契约的形状是：`priority`（被 LLM 进化的函数）、`solve` / `evaluate`（人写、固定）、`is_cap_set`（断言，合法性由 verifier 而非模型保证）。插件可直接采用同一分工：

```python
def priority(el, n) -> float:
    # 唯一可改区域：LLM 只重写这个函数体
    ...
def evaluate(n) -> int:
    # 人写、LLM 不可见：候选生成 + 合法性断言 + 打分
    candidate = solve(n, priority)
    assert is_cap_set(candidate)   # 验证器
    return len(candidate)          # 适应度
```

抗退化靠四层机制叠加，而非单一技巧：

- *周期性重置*：低分 island 不是慢慢死去，而是被清空并用别人的最优解重新起跑，等价于把算力从已收敛的局部最优迁走。
- *cluster（等价类）去重*：同一 island 内按 `signature`（各测试分数的元组）聚类；同分但写法不同的程序落进同一 cluster，`Cluster` 只记一份分数加一组实现，避免同一想法刷屏。
- *cluster 采样温度的周期性衰减*：先用 `softmax(score / T)` 在 cluster 间抽样，`T` 从 `0.1` 沿 30000 个程序的时间窗线性降到 0，然后循环——系统在「探索 → 收敛」之间自动振荡。
- *长度偏置*：cluster 内按 `softmax(-归一化长度)` 抽实现，即*同分时偏好更短的代码*（低 Kolmogorov 复杂度），既抗臃肿也保住可读性。

产生的结果（#link("https://raw.githubusercontent.com/google-deepmind/funsearch/master/cap_set/cap_set.ipynb")[raw.githubusercontent.com]）：在 8 维得到 512 元 cap set，此前已知最好构造为 496；发现的函数被人工读出规律后，还反推出手写的显式构造。bin packing 用的是 OR3（20 个实例 × 500 个物品）与 Weibull 5k（5 个实例 × 5000 个物品）两个数据集，以 L1 下界为参照（#link("https://raw.githubusercontent.com/google-deepmind/funsearch/master/bin_packing/bin_packing.ipynb")[raw.githubusercontent.com]）。仓库另含 admissible set、cyclic graph 独立集、corner-free set 三类结果，`implementation/` 只给单线程演化算法与代码操作工具，明确不含 LLM、沙箱、分布式基础设施（#link("https://github.com/google-deepmind/funsearch")[github.com]）——这正是最小可复刻内核。原论文发表于 Nature（DOI `10.1038/s41586-023-06924-6`）；2024-12 的后续工作把它用到组合竞赛编程，并改用 Gemini 1.5 Flash 替代原先的 PaLM 2。

=== AlphaEvolve：进化搜索 / LLM 生成 / 自动评估器的分工

AlphaEvolve 把 FunSearch 的「单函数」升级为「整个代码库的超优化」，并把三件事显式分开（#link("https://arxiv.org/abs/2506.13131")[arxiv.org]）：

- *Prompt sampler*：每次拼一个长上下文——若干条历史解 + 系统指令 + 用户写的背景（方程、代码片段、相关论文 PDF）+ *随机化模板占位符*（占位符的候选文本与人给的分布写在配置里，用概率实例化以提高多样性）+ *渲染后的评测结果*（程序 + 运行输出 + 分数）。
- *LLM 生成器*：Gemini 2.0 Flash 与 Gemini 2.0 Pro 的集成。Flash 低延迟、负责铺开搜索广度；Pro 只偶尔出手，提供能一次跨越多个进化代的高质量建议。模型输出被要求写成 SEARCH/REPLACE 形式的 diff 块，只改指定片段；代码很短时也可整体重写。
- *自动评估器*：执行用户提供的 `evaluate` 函数得到分数，并支持四种增强——(1) *级联评估*：测试集按难度分档，前档不达标就不进下一档，新解先在最小规模上试跑以尽早筛掉坏程序；(2) *LLM 生成的补充指标*：像「程序简洁性」这类无法用目标函数精确表达的属性，用额外 LLM 调用打分并塞进分数字典，或直接作为淘汰条件；(3) *多目标*：同时优化多个分数，论文报告即使只关心单一指标，多指标并行也常提升该指标，因为不同指标下的高分程序结构不同，进 prompt 后能激发更多样的候选；(4) *评估并行化*：论文直言单次评估可花掉约 100 个 compute-hour，若不并行会拖慢代际迭代。
- *进化数据库*：显式声明为 MAP-Elites 与 island 模型的结合。
- *分布式流水线*：用 `asyncio` 写的异步流水线，含 controller、LLM samplers、evaluation nodes；优化目标是整体吞吐量（单位预算内评估尽可能多的想法），而非任何单次计算的速度。
- *元提示共同进化*：给 LLM 的提示词本身也被当作候选，放在一个与解程序平行的数据库里共同进化，论文对矩阵乘法任务做了关闭元提示进化的消融。

LLM 的输出协议是固定的文本 diff 块（论文原文格式，逐字复制）：

```
<<<<<<< SEARCH
  # 要在当前版本中精确匹配的原始代码片段
=======
  # 用来替换原文的新片段
>>>>>>> REPLACE
```

好处是修改范围可控、可自动 patch、失败可检测（SEARCH 段匹配不上即拒绝该候选），且每次只动一两处，进化轨迹天然成为可审阅的 diff 序列。

真实开放问题的推进（一手数据）：

#table(
  columns: 3,
  [问题], [此前最好], [AlphaEvolve],
  [4x4 复矩阵乘法（标量乘法次数）], [Strassen 1969 以来的最好值], [48，56 年来首次改进],
  [kissing number，$d = 11$], [592], [593（给出 593 个整坐标点构成的构造）],
  [Erdős minimum overlap problem], [既有上界], [新的更优上界],
  [单位正方形内 26 个圆的最大半径和], [2.634], [2.635],
  [单位正方形内 32 个圆的最大半径和], [2.936], [2.937],
  [周长 4 矩形内 21 个圆的最大半径和], [2.364], [2.3658],
)

覆盖面：在 50 多个分析、几何、组合、数论开放问题上运行，约 75% 复现了已知最好解，20% 超过此前最好解（#link("https://deepmind.google/discover/blog/alphaevolve-a-gemini-powered-coding-agent-for-designing-advanced-algorithms/")[deepmind.google]）。生产侧落点包括 Borg 数据中心调度启发式（平均回收全球约 0.7% 算力）、TPU 算术电路化简（Verilog 重写 + 功能等价验证）、Gemini 矩阵乘法 kernel 提速 23%（训练时间降约 1%）、FlashAttention kernel 最高 32.5% 加速。官方只公开了结果与验证代码（#link("https://github.com/google-deepmind/alphaevolve_results")[github.com]），*不公开运行 AlphaEvolve 的代码*。

=== AlphaProof：Lean 形式化与 RL 闭环

流水线（#link("https://www.nature.com/articles/s41586-025-09833-y")[nature.com]，Nature 651, 607–613 (2026)，DOI `10.1038/s41586-025-09833-y`）：

- *环境*：Lean 4 + Mathlib。证明状态（tactic state，即假设与目标的集合）是 observation，tactic 是 action，搜索树节点是状态、边是 tactic（#link("https://deepmind.google/discover/blog/ai-solves-imo-problems-at-silver-medal-level/")[deepmind.google]）。
- *策略网络*：30 亿参数 encoder–decoder transformer。encoder 读 pretty-print 后的 tactic state 得到隐表示；decoder 作为 policy 在推理时并行生成 K 个 tactic；encoder 之上另接 value head，以类别分布参数化期望回报。
- *搜索*：由 proof network 引导的树搜索，改写自 AlphaZero 与 Sampled MuZero，保留 selection / expansion / backpropagation 三阶段。
- *自动形式化*：微调一个 Gemini 模型把自然语言题面翻成合法 Lean statement，由此造出约 100 万个不同难度的形式化问题，用来做 SFT 与 RL 的课程；RL 阶段的主课程题面即由该自动形式化组件合成。
- *RL 目标*：给定题目，模型生成候选结论（answer candidate），然后在 Lean 里搜索证明或*反证*——即把「证明」和「给出反例」都当作合法终局，答对者才进入训练信号。IMO 前系统证明/证否了数百万道题。
- *TTRL（test-time RL）*：在测试时为目标题自动生成变体，在变体上继续训练（论文消融显示变体生成模型越强、变体越多，目标题证明率越高）。
- *验证的最终关卡*：任何找到的证明/证否，都要再用标准 Lean 命令行工具对一个含完整定理陈述与证明的 `.lean` 文件独立跑一遍，并用自定义命令确认证明只依赖 Lean 内置的三条公认公理（命题外延性、全局选择、商类型可靠性）。*这一层完全不依赖神经网络判断。*
- *Lean 侧工程*：把 `linarith` 等常用 Mathlib tactic 编译成 C（生成 proof term 快约 6 倍）；给单次 tactic 执行加墙钟上限，配合 Lean 自带 heartbeat 限制；更频繁调用内部资源检查函数以尽早安全中断；给多精度整数库加数字长度硬上限以阻断失控计算。

结果：IMO 2024 六题中解出四题（两代数、一数论、一几何），28/42 分，达到银牌高位；一题数分钟内解出，其余最长耗时约三天。数据侧公开了修正版 miniF2F 与 formal-imo 基准，以及算法伪代码（`alphaproof_pseudocode.py`）。

=== Co-Scientist：多智能体辩论与评审

Co-Scientist 由 Google Research + Google DeepMind + Google Cloud AI 联合完成（#link("https://arxiv.org/abs/2502.18864")[arxiv.org]），与前三者的关键差异是*没有可执行真值*，因此必须自造一个可信度信号（#link("https://research.google/blog/accelerating-scientific-breakthroughs-with-an-ai-co-scientist/")[research.google]）：

- *智能体分工*：Generation（生成假设，内置 self-play 式「科学辩论」）、Reflection（评审，接入外部搜索工具后显著抑制了「看似新颖实则不可行」的幻觉）、Ranking（成对比较，用「科学辩论」式 prompt 做裁判，可显著提升排序质量并降低位置偏差）、Evolution（对高分假设做迭代改良）、Proximity（评估相关性/去重）、Meta-review（高层综合）。另有 Supervisor 负责把目标解析成研究计划配置，并把任务派发到 worker queue，按算力弹性扩缩。
- *适应度 = 锦标赛 Elo*：假设在淘汰赛里两两对决，Elo 随胜负更新；系统靠找到「赢/输的模式」来改进生成。论文把 Elo 当作 auto-evaluation 指标，并用 GPQA diamond 正确率验证其外部效度——Elo 越高，答对概率越高。
- *测试时算力扩展*：在 203 个研究目标上把结果按生成时间切成 10 个等量时间桶，统计前 10 名的平均 Elo 与最高 Elo，随时间持续上升；专家对 11 个目标做的盲评（新颖性、影响力、总体偏好）与 Elo 排序一致。
- *必须落到湿实验*：三个验证全部是 expert-in-the-loop——急性髓系白血病药物重定位候选（体外细胞系验证）、肝纤维化表观遗传靶点（人肝类器官）、cf-PICI 如何跨菌种存在（该结论此前已由实验室独立发现，系统在未见公开文献的条件下独立提出）。论文自己承认的局限包括文献综述质量、事实核查、与外部工具交叉验证、auto-evaluation 的可靠性。

=== 适应度函数与验证器怎么定义

四种定义的共同结构是：*候选必须可执行或被内核接受，分数必须可自动计算*；区别在于真值的硬度。

#table(
  columns: 4,
  [系统], [适应度函数], [验证器], [退化防线],
  [FunSearch], [`evaluate()` 返回「测试名 → 分数」字典，取最后一个测试分作归约分], [同一 `evaluate()` 内的合法性检查（如 `is_cap_set`）], [island 重置 + cluster + 温度振荡 + 长度偏置],
  [AlphaEvolve], [多个用户分数 + LLM 给出的软指标], [级联测试集 + 各级自带断言], [MAP-Elites + island + 多目标 + 元提示进化],
  [AlphaProof], [能否在 Lean 中找到证明（自博弈结果即奖励）], [Lean kernel + 独立命令行复核 + 三条公理检查], [由易到难的课程 + 自动形式化扩题 + TTRL 变体],
  [Co-Scientist], [锦标赛 Elo（代理指标）], [最终仍是专家实验；系统内部无真值], [自我批判 + 工具接地 + 去重（Proximity）],
)

两条可直接借鉴的结论：

- *让 LLM 产出程序而非答案*。FunSearch 的官方表述是它输出的是「解如何被构造」，因此解可被检查、被复用、被人读出新规律（cap set 512 的手写构造就是这么来的）；AlphaEvolve 生产落地的卖点也是「人类可读、可调试、可预测」。
- *验证层绝不交给 LLM*。AlphaProof 的最后一关是命令行 Lean，Co-Scientist 的最后一关是湿实验；软指标（简洁性、可行性）只能进适应度，不能进验证器。

=== 可复刻性：本地插件能做什么，什么强依赖算力

已在*本机*核实的条件：`numpy 2.5.2` ✅、`docker 29.7.2`（daemon 可用）✅、`lean` 4.32.2 与 4.33.0-rc1 ✅、`typst` ✅、`node`/`python3`/`git` ✅；`scipy` ❌（FunSearch 的 `programs_database.py` 只用到 `scipy.special.softmax`，可用 5 行 NumPy 代替）；`z3`/`cvc5`/`sage` ❌。

#table(
  columns: 3,
  [机制], [本地可行度], [依据 / 依赖],
  [island + cluster 程序数据库], [高：纯 Python + NumPy，单机可跑], [官方实现默认 10 岛 / 4 小时重置 / 2 函数入 prompt],
  [prompt 采样 + SEARCH/REPLACE 编辑], [高：只是字符串拼装与重写], [AlphaEvolve 论文的 prompt 组成与 diff 格式],
  [不可信代码沙箱执行], [高：容器隔离 + 资源上限], [本机 docker daemon 可用],
  [候选自动评估（秒级 evaluator）], [高：本机 CPU 12 核可并行], [nproc = 12],
  [Lean 形式化验证], [中高：验证侧可跑，搜索侧需自建], [本机 Lean 4 可用；Mathlib 未在 elan toolchains 中确认，需单独拉取],
  [30 亿参数 prover 的 AlphaZero 训练], [低/不可行], [百万级形式化题、TPU-weeks 级训练],
  [Gemini 2.0 Flash/Pro 集成], [不可行（需外部服务）], [插件改用宿主 Kimi 模型，吞吐低 1–2 个数量级（推断）],
  [单次评估 ~100 compute-hour 的 evaluator], [不可行], [AlphaEvolve 论文自述的评估预算],
  [Borg 调度 / TPU 电路改写], [不可行], [需要生产系统与等价性验证链路],
)

一条现成的捷径：开源社区已有 AlphaEvolve 的复刻实现 OpenEvolve，自带 MAP-Elites、island、级联评估、错误回传（artifact）、LLM 集成与多种子可复现（#link("https://github.com/algorithmicsuperintelligence/openevolve")[github.com]）；*本机 `~/openevolve` 目录下已存在一份工作副本*（含 `examples/`、`INTERFACE.json`、`openevolve-run.py`），可直接评估是否作为插件的进化后端，而不必从零复刻（推断：需先核对该副本与其上游的差异）。

把四条流水线压到本地插件后，最小闭环只有五步，每步都能追溯到上面某个一手机制：

+ *固定骨架*：研究者写 verifier 与 fitness（FunSearch 的 `evaluate` + `is_cap_set`），用标记框出唯一可进化区域。
+ *拼 prompt*：随机选一个 island，取该岛若干高分实现 + 运行结果 + 上一代报错（artifact），按 `_v0/_v1` 版本化后留一个空函数头。
+ *生成候选*：宿主 Kimi 产出 diff 块或整函数；采样率靠人机各自的算力预算控制，不再分 Flash/Pro 双模型。
+ *级联验证*：小规模实例先跑断言，通过后再跑全量；Lean 类任务直接交给本机 `lean` 命令行复核。
+ *回注与重置*：按分数元组聚类入岛，定期重置最弱的岛并从存活岛播种。

=== 评估

- *抄 FunSearch 的四层抗退化，而不是抄它的分布式规模*。具体落法：程序库按 `island_id` 分区、按测试分数元组聚类、cluster 采样温度在 0.1→0 间周期振荡、同 cluster 内优先取更短的实现。这四条都是几十行代码，却是「不退化」的全部来源；15 samplers × 140 evaluators 的规模对单机插件无意义。
- *抄「人写骨架、LLM 只填一个函数」的接口*。把可进化区域用 `# EVOLVE-BLOCK-START/END` 式标记框死，其余代码（数据加载、合法性断言、计时）由研究者写死，既省 token 又防止 LLM 改坏评测语义——这正是 FunSearch 骨架 + AlphaEvolve diff 格式的合并体。
- *抄级联评估与 artifact 回传*。第一个测试档用小规模实例（几秒）淘汰明显错误，通过后再跑全量；把 stderr、断言失败信息、超时原因原样塞回下一轮 prompt。AlphaEvolve 用级联控制成本，OpenEvolve 用 artifact 让每代从上一代的报错里学。
- *抄「多目标分数推动单目标」*。即使插件只关心一个指标，也同时记录代码长度、运行时间、最坏实例分数等多个分数并全部进 prompt，用结构差异换候选多样性；但只允许*一个*分数决定谁进精英池，避免目标漂移（推断）。
- *不要抄 Co-Scientist 的 Elo 自评当结论*。在没有可执行真值的任务上，Elo 只是排序代理，且其效度证据仅来自「与 GPQA 正确率相关」这一项。插件的正确姿势是：Elo/评审只能排优先级，最终结论必须落到可执行验证器（Lean 编译通过、`is_cap_set` 断言通过、基准实例实测数字）；若两者冲突，以验证器为准。
- *不要试图在单机复刻 AlphaProof 的训练循环，但要把它的验证层原样搬来*。3B prover 的 AlphaZero 训练不可行；可行的部分是把本机 Lean 4 当唯一天平：每个候选证明都用 `lean` 命令行独立复核、检查是否只用了公认公理，并把失败原因结构化回传给搜索层。对算法类问题同理：先写好穷举/暴力对照的 ground truth 校验器，再让 LLM 去追分。

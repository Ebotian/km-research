== AI 已推动的开放问题与算法进展案例集

本节只采信可回溯的一手来源（论文页、官方博客、官方仓库、问题数据库本体），并在每条结论后附 URL。
全文严格区分三类信息：*来源事实*（论文或官方原文）、*二手转述*（媒体报道）、
*本报告推断*（作者依来源方法学得出的判断，不代表来源观点）。所有页面访问日期为 2026-09-14；
该领域数字迭代极快，任何数字落地前必须重新核对来源页。

=== (a) cap set：FunSearch 的容量下界 $C >= 2.2202$ 及其后续链条

- 问题定义：cap set 是 $bb(F)_3^n$ 中不含非平凡三元素解 $x+y+z=0$ 的子集；其渐近规模由容量常数
  $C = sup_n c_n^(1/n)$ 刻画，指数量级的上界与下界长期分离。
- 上界一侧与 AI 无关但必须知道：Ellenberg–Gijswijt（2017）证明 $C <= 2.756$
  （#link("https://www.nature.com/articles/s41586-023-06924-6")[Nature 625, 468–475] 正文）。
- FunSearch（Romera-Paredes 等，Nature 625, 468–475, 2024，DOI `10.1038/s41586-023-06924-6`；
  原文与评审信息见 #link("https://www.nature.com/articles/s41586-023-06924-6")[nature.com]）
  的两类结果被 #link("https://deepmind.google/discover/blog/funsearch-making-new-discoveries-in-mathematical-sciences-using-large-language-models/")[官方博客]
  称为"20 年来 cap set 规模的最大一次提升"。
  - 走"常重量可容许集"（admissible set）路线：发现满尺寸 $cal(I)(15,10)$ 可容许集，给出 $C >= 2.219486$；
    又发现 $cal(A)(24,17)$ 中规模 237,984 的部分可容许集，给出 $C >= 2.2202$（Nature 正文，同上 URL）。
    此前的下界为 Tyrrell 的 $2.218^n$（$n$ 足够大时），见
    #link("https://arxiv.org/abs/2209.10045")[arXiv:2209.10045 / Discrete Analysis 2023]。
  - 走"直接构造"路线：在 $n=8$ 维从零发现 512 点的 cap set；原文明确说这比此前已知构造更大，
    而此前最好构造依赖低维 cap set 的复杂组合。这条路线*极不稳定*：140 次独立实验只有 4 次复现出 512
    （Nature 正文 "Robustness" 段，同上 URL）。
- 关键机制（来源事实）：FunSearch 只要求问题是"易评估、难求解"的——论文开篇即以此划定适用范围，
  并要求用户提供 `evaluate` 程序与种子 `solve` 程序骨架。
- 后续链条（每一步都有独立来源）：
  - X-evolve（#link("https://arxiv.org/abs/2508.07932")[arXiv:2508.07932]，2025-08）改为"进化整个解空间"
    而非单个解，把常数推到 $C >= 2.2203$，并声称 LLM 调用量比此前主流方法低最多两个数量级；
    同一论文还改进了 $C_15$ 的五次强积上的独立集下界（到 19,946）与在线 bin packing 启发式。
  - Hametner 与 Tyrrell（#link("https://arxiv.org/abs/2606.12194")[arXiv:2606.12194]，2026-06）证明：
    任何*固定* cap set 通过直积都无法给出渐近最优下界，即"继续放大单个构造"这条路本质上有天花板。
    *本报告推断*：该定理使"在更高维硬碰搜索"的边际收益变小，后续工作必须换表示（可容许集、解空间参数化等）。
  - 数据与代码：官方仓库 #link("https://github.com/google-deepmind/funsearch")[google-deepmind/funsearch]
    以 Apache-2.0（软件）+ CC-BY（材料）发布，含 `cap_set`、`admissible_set`、`bin_packing`、
    `cyclic_graphs`、`corner_free_sets` 五个目录及单线程演化框架（不含 LLM 与沙箱）。
- 同行确认状态：Nature 论文经过同行评审（评审人含 J. Grochow、A. Lodi、J.-B. Mouret、T. Ringer、
  T. Yu，见 Nature 页面 Peer review 段）。X-evolve 与 Hametner–Tyrrell 为 arXiv 预印本；
  官方仓库自述 "This is not an official Google product"。

=== (b) 在线 bin packing：经验适应度下的启发式改进

- 设定（来源事实）：把启发式写成程序——输入一个物品与各箱剩余容量数组，输出各箱优先级分数，
  `solve` 取分最高者；搜索从 best fit 出发进化（Nature 正文，同 (a) 的 Nature URL）。
- 结果：在 OR-Library 的 OR1–OR4 四个数据集上同时优于 first fit 与 best fit；训练只用了与 OR1 同规模的实例，
  却泛化到更大规模，且规模越大与 best fit 的差距越大；在 Weibull 分布实例上，
  "10 万件物品时仅比最优值的下界差 0.03%"（Nature 正文，同上）。评估指标是"超出 L2 下界的箱数占比"。
- 稳健性：原文明确说该问题上"每一次运行都超越基线"，只是幅度有波动（Nature "Robustness" 段）。
- 边界（*本报告推断*）：结果是对基准分布上的*平均*表现，论文没有给出最坏情况竞争比的新定理；
  最坏情况竞争比属于另一套文献（原文引 Balogh 等 2018 ESA 等）。把它宣传成"在线装箱理论进展"是过度解读。
- 后续：X-evolve 同样报出优于标准策略的在线 bin packing 启发式
  （#link("https://arxiv.org/abs/2508.07932")[arXiv:2508.07932]）。FunSearch 的 2024-12 更新把同一思路
  迁到组合式竞赛编程：人类写"骨架"，LLM 进化"调度函数"，并称结果能超过顶尖百分位人类选手
  （#link("https://deepmind.google/discover/blog/funsearch-making-new-discoveries-in-mathematical-sciences-using-large-language-models/")[官方博客]）。

=== (c) 矩阵乘法：AlphaTensor 的 4x4、AlphaEvolve 的 48 次乘法，以及 $omega$ 的最新下压

- AlphaTensor（Fawzi 等，Nature 610, 47–53, 2022，DOI `10.1038/s41586-022-05172-4`）把算法搜索变成
  单人游戏 TensorGame，用 AlphaZero 式 RL 求解。官方数字：$4 times 5$ 乘 $5 times 5$ 从 100（教科书）
  到 80（人类最好）再到 76（AlphaTensor）；"自 Strassen 以来 50 年内首次在有限域上超过两层 Strassen"；
  针对 V100 GPU / TPU v2 的硬件专属算法比常用算法快 10–20%；每个尺寸可给出上千个不同算法
  （#link("https://deepmind.google/discover/blog/discovering-novel-algorithms-with-alphatensor/")[官方博客]）。
  *二手转述*：4x4 在 $bb(F)_2$ 上用 47 次乘法（对比两层 Strassen 的 49 次），见
  #link("https://en.wikipedia.org/wiki/AlphaTensor")[Wikipedia: AlphaTensor]；
  本报告未在官方博客核到该数字。
- AlphaEvolve 的对应结果：在 $4 times 4$ 复值矩阵上找到 48 次标量乘法的分解，"56 年来该设定下第一次改进
  Strassen"；同时改进 14 个矩阵乘法设定的 SOTA（#link("https://deepmind.google/discover/blog/alphaevolve-a-gemini-powered-coding-agent-for-designing-advanced-algorithms/")[官方博客]、
  #link("https://arxiv.org/abs/2506.13131")[arXiv:2506.13131] 白皮书）。白皮书有一条易被标题党淹没的脚注：
  存在用少于 49 次乘法的算法，但它们不对应矩阵乘法张量的分解、不能递归用于更大矩阵——
  "可递归分解"这一约束正是把问题变成可验证目标的原因。
- $omega$ 的最新进展（本节最硬的"上界改进"证据）：Dupont 等重写组合损失分析框架下的优化问题以支持更大设定、
  另设计一个机器学习式优化器、再用 AlphaEvolve 的 "evolving constructions" 模式细化该优化器，
  得到 $omega < 2.371177$，优于此前最好的 $2.371339$；整个优化在单张 GPU 上约 5 小时
  （#link("https://arxiv.org/abs/2608.16884")[arXiv:2608.16884]，2026-08）。
  - 验证方式（原文第 4 节）：单独跑一步"严格验证"——把浮点解舍入为有理数，用最大熵证书
    （分布 $y$、$lambda_0$ 等构成的有效证书）保证可行，再把所有量与对数换成*精确有理运算*与方向正确的有理界，
    使证书"不受数值误差影响"。作者称正在准备发布验证代码与解。
  - *本报告推断*：这里 AI 不是在找结构性新算法，而是在为已有数学框架*调优化器*；
    真正让结论可信的是那套有理数证书，而不是搜索本身。

=== (d) kissing number 与 packing：AI 已直接改写记录表

- 已知精确值的维度极少：kissing number 只在维度 1、2、3、4、8、24 被完全确定，其余维度长期停在构造式下界
  （#link("https://arxiv.org/abs/2511.13391")[arXiv:2511.13391] 正文）。
- AlphaEvolve：在 11 维把下界推到 593（前记录 592）；在同一批"50 多个数学开放问题"中复现约 75% 的已知最好构造、
  在约 20% 上做出新构造，其中包括 Erdős 最小重叠问题的新上界，以及多种 packing 问题
  （把 $N$ 个点放进一个形状以最小化最大/最小距离之比、多边形互嵌、Heilbronn 问题变体）
  （#link("https://arxiv.org/abs/2506.13131")[arXiv:2506.13131] 白皮书第 3.2 节）。问题多由外部数学家提议，
  且起始点只是简单或随机构造。
- 验证方式（来源事实）：白皮书附录 B.11 给出可检查的引理——若整数坐标点集 $C$ 的内积满足所需条件，
  则把单位球心放在沿每个 $x in C$ 归一化的方向、长度为 1 的点上构成合法 kissing 构型，故 $K(d) >= abs(C)$。
  即"下界 = 一份可用整数与精确算术复核的显式构造"。
- 后续：PackingStar（#link("https://arxiv.org/abs/2511.13391")[arXiv:2511.13391]，2025-11 首发、2026-06 更新）
  把问题重构为"合作式矩阵补全博弈"（一方填余弦值、一方纠错）并训练 RL，改进 15 个多年未动的界；
  论文声明"所有内积都做了精确验证"。其 Table S12 给出若干广义 kissing 下界，例如 $K(13, 7/19)$ 从 231 到 240、
  $K(15, 5/11)$ 从 991 到 1215，并在 25–31 维的广义 kissing 数上给出新记录；11 维仍记为 AlphaEvolve 的 593（Table S2）。
- 该论文还提到：从 PackingStar 暴露的构造律出发，数学家随后构造出 18 维、最大余弦 $5/14$、含 867 球的球码，
  超过此前已知构造——这是"AI 给结构线索、人做推广"的一种真实分工。

=== (e) Erdős Problems：一次公开误报、一次可查的自动解决、以及自我更正

- 数据库规模与口径（来源事实）：#link("https://www.erdosproblems.com/")[erdosproblems.com] 首页
  （2026-09-14 抓取）显示 1220 个问题、586 个（48%）已解决。"Open" 是该站点的口径，
  不等于"数学界公认未解决"。
- 2025-10 的公开误报：OpenAI 的 Kevin Weil 发推称 GPT-5 "找到了 10 个此前未解决的 Erdős 问题的解"
  并推进另外 11 个，随后推文被删。站长 Thomas Bloom 当场反驳，称之为"戏剧性的误读"：站上标注 open
  只表示*他本人不知道解*，并非问题未解；GPT-5 实际找到的是 Bloom 漏掉的已有文献。Demis Hassabis 称此事
  "embarrassing"，Yann LeCun 亦公开嘲讽
  （#link("https://the-decoder.com/leading-openai-researcher-announced-a-gpt-5-math-breakthrough-that-never-happened/")[The Decoder]）。
  同一报道指出被低估的真实价值：GPT-5 作为文献检索工具很有用。
- Erdős #728：被论文明确称为"第一个被认定为完全由 AI 自主解决的 Erdős 问题"。系统是 GPT-5.2 Pro
  与 Harmonic 的 Aristotle 的组合，由 Kevin Barreto 操作；产物是 Lean 形式化证明，另有非形式化改写；
  内容是阶乘整除 $a! b! divides n! (a+b-n)!$ 的对数间隔现象，技术路线用 Kummer 定理把二项式系数的
  $p$-进赋值转成进制进位计数（#link("https://arxiv.org/abs/2601.07421")[arXiv:2601.07421]）。
  - #link("https://www.erdosproblems.com/728")[问题 #728 页面] 自己写了两条限定：该问题表述有歧义、
    按字面存在平凡解（AlphaProof 团队已指出）；页面状态现为 "PROVED (LEAN)"。
- 成规模系统评测与*自我更正*：#link("https://arxiv.org/abs/2601.22401")[arXiv:2601.22401]
  （Gemini 案例研究，2026-01/02）系统评估 700 个标记为 Open 的猜想，最终处理 13 个：
  5 个看似自主的新解 + 8 个是"找到已有文献中的旧解"。结论是这些问题 "open 是因为冷门而非困难"
  （obscurity rather than difficulty）。论文自陈两大风险：文献识别困难与 AI 的 "subconscious plagiarism"
  （潜意识剽窃）。其 v3 补注把 Erdős-935 重新归类为"独立重发现"，使自主解数量从 6 降到 5——
  这是本主题里最干净的一次*发布后更正*。
- 成本已可量化：AlphaProof Nexus 自主解决 353 个开放 Erdős 问题中的 9 个，单题成本"几百美元"，
  另证出 492 条 OEIS 猜想中的 44 条；论文还报告"LLM 生成 + Lean 验证交替"的朴素智能体复现了 Erdős 成果，
  但在最难的问题上更贵（#link("https://arxiv.org/abs/2605.22763")[arXiv:2605.22763]）。
- 社区账本：#link("https://vibemathed.com/")[vibemathed.com]（2026-09-14 抓取）追踪 717 个问题，
  其中 492 个 "fully resolved"、4 个 "under review"、153 个 "Lean-verified"，并给条目打 "AI-discovered" 标签，
  把"已声明 / 已复核 / 机器验证"分成不同状态。
- 规范层面：IMU 认可的 #link("https://leidendeclaration.org/")[Leiden Declaration on AI and Mathematics]
  （2026-05 定稿，4024 名签署人）要求公开披露工具使用、正确性责任完全归人类作者、成果发表在同侪评审渠道、
  必要时要求形式化验证，并明确警告"通过新闻稿或博客发布结果"会损害评估体系。

=== (f) AlphaTensor 与 AlphaDev：两次更早、均经同侪评审的"算法发现"

- AlphaTensor 的要点见 (c)。补充机制：状态是三维张量（距离正确还有多远），每步消去条目，消完即得到可证明
  正确的算法，步数即代价；单步可选动作数比围棋多约 30 个数量级
  （#link("https://deepmind.google/discover/blog/discovering-novel-algorithms-with-alphatensor/")[官方博客]）。
- AlphaDev（Mankowitz 等，Nature 618, 257–263, 2023）用 AlphaZero 式 RL 直接在汇编指令空间搜索"汇编游戏"，
  奖励 = 正确性 + 延迟。落地数字：改进 LLVM libc++ 排序库，"对短序列最多快 70%，对超过 25 万元素的序列约快 1.7%"；
  重点优化的是 3–5 元素的小序列；另外发现 9–16 字节区间的哈希算法快 30%，进入开源 Abseil 库
  （#link("https://deepmind.google/discover/blog/alphadev-discovers-faster-sorting-algorithms/")[官方博客]）。
- 值得借鉴的两点（来源事实）："AlphaDev swap and copy moves"是真正的新结构（少一条指令完成连接），
  而非纯参数调优；论文自陈局限——指令空间随算法变长而爆炸，已转向探索高层语言（同一博客）。

=== (g) 共同结构，以及不满足这些条件的问题

#table(
  columns: 3,
  [案例], [验证方式], [同侪确认状态],
  [FunSearch cap set / bin packing], [可容许集与 cap set 由确定性程序生成、可枚举复核；装箱为基准分布上的均值打分], [Nature 评审通过],
  [X-evolve cap set], [部分可容许集与独立集规模核验], [arXiv 预印本，未见评审记录],
  [AlphaTensor 4x4 / AlphaEvolve 4x4], [张量分解可精确验证（每步线性组合可代入核查）], [Nature 评审通过 / 白皮书未评审],
  [$omega < 2.371177$], [有理数精确运算下的最大熵证书], [arXiv 预印本，验证代码待发布],
  [kissing number 593], [整数坐标构造 + 显式引理], [白皮书；被 PackingStar 论文当基线引用],
  [PackingStar 的 15 个界], [所有内积精确验证], [arXiv 预印本，已更新到 v4],
  [Erdős #728], [Lean 形式化证明（Aristotle）], ["首个自主解决"表述；数据库标 PROVED (LEAN)],
  [AlphaProof Nexus 9/353], [Lean 验证 + 公开单题成本], [arXiv 预印本],
  [Gemini Erdős 案例], [人工专家复核 + 文献比对], [arXiv 预印本，且自行下调战绩],
)

共同结构（*本报告综合来源得出的判断*）：

- 一个*廉价、确定性、可被第三方重跑*的评估器：显式构造比大小（cap set、kissing）、张量分解可代入验证、
  形式化证明由 Lean 检查。创意由 LLM 提供，正确性从不由 LLM 提供。
- *巨大但结构化的搜索空间*：暴力不可行（AlphaTensor 原文称"比宇宙原子数还多"），
  但每个候选都能被打分，于是能给部分信用、能做进化选择。
- *明确的标量目标与公开记录表*：几乎所有成功都能归结为"把某个公开记录表上的一个数字改小或改大"，
  且改进幅度通常很小（48 对 49、593 对 592、$2.371177$ 对 $2.371339$、$2.2203$ 对 $2.2202$）。
  选题时应优先选择*有公开记录表*的指标。
- *人类定框*：AlphaEvolve 白皮书的图注直书 "Human defines What?"——人给评估标准、初始解与背景知识；
  FunSearch 要求人先写 `evaluate` 与骨架。
- *独立于搜索的验证环节*：有理数证书、精确内积、Lean 检查、随机输入对照加人工专家终审
  （FlashAttention 与 TPU Verilog 两个案例都明确写了这一步）。

不满足这些条件、因而至今没有可比战绩的问题类型（同属综合判断，逐条给出依据来源）：

- *没有部分信用、也没有可检查证书的单比特猜想*（如黎曼猜想，或 `P` 与 `NP` 的分离）：评估器只能说"证完了或没证完"，
  进化搜索失去梯度。依据：FunSearch 自设适用范围为"易评估、难求解"
  （#link("https://www.nature.com/articles/s41586-023-06924-6")[Nature]）。
- *适应度只是代理指标的问题*：装箱用基准分布均值、kernel 用模拟器与真实输入形状集
  （#link("https://arxiv.org/abs/2506.13131")[白皮书] 自述用训练/评估形状集分离来检查泛化）。
  代理指标可被优化到背离真实目标，且不产生定理。
- *瓶颈在文献与归属而非搜索的问题*：Gemini 案例中 13 个问题里有 8 个只是找到已有文献，
  论文点名 "subconscious plagiarism" 风险（#link("https://arxiv.org/abs/2601.22401")[arXiv:2601.22401]）。
- *需要发明新概念对象而非优化已有参数的问题*：对合（bijection）构造的实验发现，新的研究级对合仍超出
  当前前沿系统能力，需要人在环（#link("https://arxiv.org/abs/2511.20987")[arXiv:2511.20987]）。
- *意义与价值本身不可自动化的问题*：Leiden Declaration 明确警告研究方向可能因"便于自动化"而被优先，
  而非依专家判断其深度（#link("https://leidendeclaration.org/")[leidendeclaration.org]）。

=== 评估

- *抄 FunSearch 的"双函数"接口与目录结构*：技能里固定 `evaluate(candidate) -> score`
  （必须确定性、纯函数、可在无网络沙箱重跑）与 `solve` 骨架两件套，并把每个问题的搜索代码、最好候选与原始分数
  落到磁盘（对应 #link("https://github.com/google-deepmind/funsearch")[funsearch 仓库] 的
  `cap_set/`、`admissible_set/`、`bin_packing/` 布局与 `implementation/` 单线程演化器）。
  不要只存最终答案——FunSearch 的卖点正是"输出生成解的程序"。
- *抄"搜索与验证分离"，并把证书列为第一类产物*：每个候选必须能生成独立可复核的证书文件
  （整数坐标与内积清单、有理数证书、Lean 源码），由与生成器不同的代码路径校验。
  对齐 #link("https://arxiv.org/abs/2608.16884")[arXiv:2608.16884] 的精确有理运算验证与
  #link("https://arxiv.org/abs/2511.13391")[PackingStar] 的"所有内积精确验证"做法；
  对装箱、排序这类数值实验，强制训练集与评估集分离，并同时报告最坏情况基线。
- *抄"先查文献再报功"的前置步骤*：在宣布任何"新结果"前跑一遍文献检索与已知记录表对照，
  输出"是否已知、归属为谁"字段。这是 Gemini Erdős 案例用一次发布后更正换来的教训
  （Erdős-935 从自主解降级为独立重发现，6 降到 5，#link("https://arxiv.org/abs/2601.22401")[arXiv:2601.22401]）；
  并把 2025-10 那次"GPT-5 解决 10 个 Erdős 问题"的误报当作反例：`open` 标签不等于未解。
- *抄多岛、多随机种子与"复现率"指标*：FunSearch 在 $n=8$ cap set 上 140 次只有 4 次成功，
  却在该问题族上"每次运行都超过基线"——同一系统在不同问题上的方差可以差两个数量级。
  插件应把 `seed`、`run_id`、成功次数/总次数设为一等字段，并禁用"单次运行即宣布结论"的路径。
- *避免把代理适应度当定理、把白皮书当同侪评审*：插件输出的每个结果都带
  `verification_level`（`empirical` / `exact_certificate` / `lean_checked` / `human_peer_reviewed`）与来源 URL；
  AlphaEvolve 白皮书至今是 arXiv 预印本（`arXiv:2506.13131`，无 journal-ref），
  而 FunSearch、AlphaTensor、AlphaDev 都是 Nature 经同侪评审的论文——两者不应在报告里并列同一可信度。

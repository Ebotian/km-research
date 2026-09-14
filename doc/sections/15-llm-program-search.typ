== LLM 驱动的程序搜索与进化算法发现

这一族系统的共同骨架是：*LLM 当变异算子 + 自动评估器当适应度 + 程序数据库当记忆*。AlphaEvolve 白皮书把它形式化为 prompt sampler → LLM 集成 → 代码修改（diff 或整段重写）→ 评估器（含级联）→ 进化数据库（MAP-Elites × 岛模型）的异步流水线，控制器、LLM 采样器、评估节点三者并发，优化目标是吞吐而不是单次延迟
#link("https://arxiv.org/abs/2506.13131")[AlphaEvolve 白皮书（arXiv:2506.13131）]。

*事实分级约定*：本节所有版本号、默认值、字段名均取自一手源码、白皮书或协议规范，并附 URL；凡是本文作者的判断都显式标注「推断」；无法核实的写 `UNVERIFIED`。

本机只读核实（用于后文沙箱方案）：`bwrap`（`/usr/bin/bwrap`）、`unshare`、`prlimit`、`timeout`、`systemd-run`、`docker` 29.7.2 均可用；当前用户在 `docker` 组，cgroup 为纯 v2（`cgroup2fs`），docker 驱动为 `overlayfs`；`firejail`、`nsjail`、`podman` 未安装。

=== 四个可读实现 + 一个闭源参照

#table(columns: 4,
  [*项目*], [*可复现性*], [*多样性机制*], [*变异与评估*],
  [AlphaEvolve], [闭源，仅白皮书 + 博客], [MAP-Elites × 岛模型（白皮书自述）], [diff（SEARCH/REPLACE）或整段重写；级联评估],
  [FunSearch 官方仓库], [Apache-2.0；但缺 LLM、sandbox、分布式三块], [10 岛 + 按测试分数签名的 cluster，每 4 小时重置弱半区], [从函数体续写；评估器逐测试用例串行打分],
  [OpenEvolve], [Apache-2.0，Python 包 `openevolve`], [每岛独立 MAP-Elites 特征图 + 环形迁移], [diff 或整段重写；级联评估 + artifacts 反馈],
  [ShinkaEvolve], [Apache-2.0，`pip install shinka-evolve`，ICLR 2026], [岛 + 全局 archive + 嵌入去重 + 血缘子树复制], [diff/full/cross 三种补丁，按概率采样；本地或 Slurm],
  [LLM4AD], [BSD-2-Clause，CityUHK/Sustech], [种群式（EoH/MEoH/ReEvo 等多种方法并列）], [多进程评估 + 超时中断（自称 main process protection）],
)

一手来源：FunSearch 仓库
#link("https://github.com/google-deepmind/funsearch")[google-deepmind/funsearch]；OpenEvolve
#link("https://github.com/algorithmicsuperintelligence/openevolve")[algorithmicsuperintelligence/openevolve]（README 中引用地址仍写 `codelion/openevolve`）；ShinkaEvolve
#link("https://github.com/SakanaAI/ShinkaEvolve")[SakanaAI/ShinkaEvolve]；LLM4AD
#link("https://github.com/Optima-CityU/llm4ad")[Optima-CityU/llm4ad]。

*推断*：LLM4AD 与前三者不在同一抽象层——它把「搜索方法」做成可插拔类（EoH、MEoH、ReEvo、MCTS-AHD、PartEvo 等并列），适合当算法对比台；而 OpenEvolve / ShinkaEvolve 是单一流水线的工程实现，适合当插件骨架。

=== FunSearch 官方仓库：哪些能抄、哪些拿不到

`implementation/` 目录只有 7 个源码文件：`code_manipulation.py`、`config.py`、`evaluator.py`、`funsearch.py`、`programs_database.py`、`sampler.py` 及其测试。仓库 README 明确写道：该目录 *不包含* 生成新程序的语言模型、执行不可信代码的 sandbox，也不包含在其分布式系统上运行的设施。也就是说，官方复现只给了「进化算法 + 代码操作 + 单线程流水线」。

关键配置默认值（`implementation/config.py`）：

- `functions_per_prompt = 2`、`num_islands = 10`
- `reset_period = 4 * 60 * 60`（秒）、`cluster_sampling_temperature_init = 0.1`、`cluster_sampling_temperature_period = 30_000`
- `num_samplers = 15`、`num_evaluators = 140`、`samples_per_prompt = 4`

多样性机制不是 MAP-Elites 网格，而是「按得分签名聚类 + 岛屿重置」：

- 一个程序的签名是它 *逐测试用例得分* 排序后的元组；同一签名归入同一个 `Cluster`（`programs_database.py`）。
- 采样 cluster 用带温度衰减的 softmax：温度按已注册程序数在 `cluster_sampling_temperature_period` 内线性衰减到 0。
- 同一 cluster 内采样具体程序时，*偏向短程序*：`_softmax(-normalized_lengths, temperature=1.0)`。
- 岛屿重置：每 `reset_period` 秒把 *得分最低的一半* 岛屿清空，新岛播种的 founder 从存活岛屿中随机挑一个岛的当前最优程序复制过来（加 `1e-6` 噪声破平）。这是一条「重启弱支路但保留基因」的廉价多样性策略。

*推断*：FunSearch 的「签名聚类」等价于一个 *行为空间* 上的离散 QD 网格，只是格点由测试套件的得分向量动态定义，而不是人工指定特征维度；对本来就有多组测试的算法任务，这比 OpenEvolve 的 `complexity`/`diversity` 手工特征更贴合。

=== OpenEvolve：MAP-Elites 与岛模型最可读的参考实现

数据库结构（`openevolve/database.py` 的 `Program` 数据类）：`id`、`code`、`changes_description`、`language`、`parent_id`、`generation`、`timestamp`、`iteration_found`、`metrics`、`complexity`、`diversity`、`metadata`、`prompts`、`artifacts_json`、`artifact_dir`、`embedding`。血缘就是 `parent_id` + `generation`，血缘操作类型存放在 `metadata.changes`，来源岛存放在 `metadata.island`。

MAP-Elites 是 *每岛一张特征图*：`island_feature_maps[island_idx]`，键由 `feature_bins` 分箱后拼成字符串（`"-".join(str(c) for c in coords)`），默认 `feature_bins = 10`。特征维度可以是内置的 `complexity`（代码长度）、`diversity`（对参考集的结构差异）、`score`，也可以是评估器返回的任意自定义指标；维度既不在 metrics 里也不是内置值时会直接抛错（`_calculate_feature_coords`）。落格规则：目标格空着就占，已有程序则比较 fitness，只有更优才替换，被顶掉的程序从岛上移除并可能被清出 archive。

选亲本（`sample_from_island`，线程安全、不改共享状态，供多进程 worker 用）：按 `exploration_ratio = 0.2` 随机选（探索）、`exploitation_ratio = 0.7` 从 elite archive 选、剩余概率按 fitness 加权选。`sample()` 与 `sample_from_island()` 共用同一套比例，保证单进程与并行模式行为一致。

迁移：环形拓扑，只迁到相邻两岛（`(i+1) % n`、`(i-1) % n`），默认 `migration_interval = 50`、`migration_rate = 0.1`。源码注释记录了一个真实事故：不加约束时程序 `cb5d07f2` 到第 850 次迭代产生了 183 个后代拷贝，ID 变成 `..._migrant_2_migrant_3_migrant_4_migrant_0` 这种链；修法是给迁移副本打 `metadata.migrant = True`，*已迁移过的程序不再二次迁移*，并在目标岛已存在同源代码时跳过。

其他默认值（`configs/default_config.yaml`）：`population_size = 1000`、`archive_size = 100`、`num_islands = 5`、`max_code_length = 10000`、`random_seed = 42`、`evaluator.timeout = 300`、`parallel_evaluations = 4`、`cascade_evaluation = true` 且阈值 `[0.5, 0.75, 0.9]`、`prompt.num_top_programs = 3`、`prompt.num_diverse_programs = 2`、`prompt.max_artifact_bytes = 20480`。

=== ShinkaEvolve：把样本效率当成第一目标

论文（arXiv:2509.19349）自述三项创新，均可对照源码默认值：

- *父代采样*：power-law 采样 $p_i = r_i^(-alpha) \/ sum_j r_j^(-alpha)$（$r_i$ 是 fitness 排名，$alpha = 0$ 退化为均匀采样）；以及 weighted 采样，把原始父代个数当作一等信号：$w_i = s_i dot h_i$，其中 $s_i = sigma(lambda (F(P_i) - "median"(F)))$，$h_i = 1 \/ (1 + N(P_i))$，$N(P_i)$ 是 $P_i$ 的已生成子代个数。仓库默认 `parent_selection_strategy = "weighted"`、`parent_selection_lambda = 10.0`、`exploitation_alpha = 1.0`。
- *新奇性拒绝采样*：对 *可变代码片段* 做嵌入，与岛内子群算余弦相似度；超过阈值则再问一次 LLM 判断是否「实质不同」。论文举的阈值是 $eta = 0.95$，而仓库默认 `code_embed_sim_threshold = 0.99`、`embedding_model = "text-embedding-3-small"`、`max_novelty_attempts = 3`——*这两个数字不一致，落地时按仓库默认或自己标定*。消融结论：嵌入拒绝采样比不拒绝「显著更好」，再加 LLM 判官只带来边际收益（论文 §Ablation）。
- *bandit 选模型*：UCB1，用 `llm_dynamic_selection = "ucb"`，奖励改造为 $r_i^u = exp(max(r_i - r_i^b, 0)) - 1$，基线 $r_i^b$ 取「父程序与初始程序 fitness 的较大值」，即只奖励相对改进，避免归档非平稳性把统计量带偏。

补丁与不可变区：`patch_types = ("diff","full","cross")` 配 `patch_type_probs = (0.6,0.3,0.1)`；diff 用 SEARCH/REPLACE 块；`EVOLVE-BLOCK-START` / `EVOLVE-BLOCK-END` 标记可变区，可变区之外的代码在整段重写时也被强制校验；补丁非法则重采样并把解析错误回喂（论文引用 Reflexion），默认 `max_patch_resamples = 3`。

数据库与并行：SQLite 存储、`num_islands = 2`、`archive_size = 40`、`migration_interval = 10`、`island_elitism = true`、`enforce_island_separation = true`、`parent_selection_strategy = "weighted"`；可选的 `enable_dynamic_islands` 在停滞 `stagnation_threshold = 100` 代后按 `island_spawn_strategy` 复制 `island_spawn_subtree_size` 个程序开新岛。并发三件套在 runner 上：`max_evaluation_jobs`、`max_proposal_jobs`、`max_db_workers`，配 `enable_controlled_oversubscription` 在「生成比评估慢」时提高提案并发，上限由 `proposal_target_ratio_cap` / `proposal_buffer_max` / `proposal_target_hard_cap` 封顶。每 `meta_rec_interval = 10` 代做一次 meta-scratchpad，把近期评估总结成建议追加进变异 prompt。

成果口径（论文摘要）：用 *150 次采样* 找到新的圆堆积 n=26 最优解；此外改进了 AIME 的 agentic harness、ALE-Bench 竞赛解，以及 MoE 负载均衡损失函数。

=== 评估器的隔离与资源限制：现状比宣传弱

- *FunSearch*：`evaluator.py` 里 `Sandbox` 是一个抽象类，接口是 `run(program, function_to_run, test_input, timeout_seconds)` 返回 `(输出, 是否成功)`，`Evaluator` 默认 `timeout_seconds = 30`。真正的 sandbox 官方没开源。
- *OpenEvolve*：评估在 *同进程* 内完成——用 `importlib.util.spec_from_file_location` 加载你的 `evaluate.py`，在事件循环的线程池里调用 `evaluate_function(program_path)`，外面套 `asyncio.wait_for(..., timeout=300)`。默认配置文件里有一句直接写明的话：`resource limits (memory_limit_mb, cpu_limit) are not yet implemented`。并行只体现在迭代级：`ProcessPoolExecutor`（`max_tasks_per_child` 需 Python 3.11+）加「评估超时 + 30 秒」的兜底取消。超时不杀线程，只是放弃等待。
- *ShinkaEvolve*：本地作业是裸 `subprocess.Popen`（`shinka/launch/local.py`），超时靠调度器轮询到点 `kill()`；它倒是有 `numeric_threads_per_job`，会注入 `OMP_NUM_THREADS`、`OPENBLAS_NUM_THREADS`、`MKL_NUM_THREADS`、`NUMEXPR_NUM_THREADS`、`VECLIB_MAXIMUM_THREADS` 等一整套线程上限（防止候选程序把机器打满）。Docker 只在 Slurm 后端出现（`SlurmDockerJobConfig`，`cpus`/`gpus`/`mem` 是调度器请求项）。
- *LLM4AD*：其功能表把「Secure Evaluation: main process protection, timeout interruption」和「multiprocessing evaluation」列为已支持——这是四个项目里唯一把「保护主进程」写成卖点的。`UNVERIFIED`：其实现是否用 seccomp / rlimit，README 未说明。

*推断*：这三套开源实现都假定「候选代码是合作者而不是敌人」。放到本地插件里必须自己补隔离。本机可用的最小组合（不需要 root，`bwrap` 用非特权 user namespace）：

```bash
# 候选程序执行：只读挂载系统库，禁网，独立 PID/IPC/UTS 命名空间，目录写进 tmpfs
bwrap --unshare-user --unshare-net --unshare-pid --unshare-ipc --unshare-uts \
      --die-with-parent --new-session --clearenv \
      --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
      --proc /proc --dev /dev --tmpfs /tmp \
      --setenv HOME /tmp --setenv PYTHONHASHSEED 0 \
      python3 /tmp/candidate.py
```

若候选程序需要 GPU / 大数据集、或需要硬内存上限，则走 Docker（本机 29.7.2 实测存在这些 flag）：`--memory`、`--cpus`、`--pids-limit`、`--network none`、`--read-only`、`--tmpfs`、`--cap-drop`、`--security-opt`、`--ulimit`、`--stop-timeout`。纯 CPU 的轻量任务还可以叠加 `prlimit --as=2G --cpu=30` 与 `timeout --signal=KILL 30s`，或者用 `systemd-run --scope -p MemoryMax=2G -p CPUQuota=100%` 交给 cgroup v2 管。注意 `python3` 的 `resource` 模块 `RLIMIT_AS`/`RLIMIT_CPU` 在本机默认是 unlimited，必须显式设置。

=== Prompt 与上下文如何组织

四套系统的 prompt 结构高度收敛为「不可变骨架 + 历史最优若干 + 当前程序 + 输出格式约束」，差异在 *给几个、给哪些、给什么反馈*：

- *FunSearch*（`programs_database.py::Island.get_prompt`）：prompt 就是模板程序本身。从岛内按 cluster 采样出 `functions_per_prompt` 份实现，逐个重命名为 `fn_v0`、`fn_v1`…，并把 `fn_v1` 之后的 docstring 改成 ``Improved version of `fn_v{i-1}`.``，最后追加一个空函数体的 `fn_v{n}` 头部等 LLM 续写。实现按得分 *升序* 排列，于是编号越大越新越优。`version_generated` 会传回评估器，用来把生成函数里的 `fn_v{i}` 调用改名，从而禁止新程序调用祖先版本。
- *AlphaEvolve*（白皮书 §2.2）：prompt 含「从数据库采样的多个既有解 + 如何修改的系统指令」，另有四类可定制成分：显式上下文（问题描述、公式、代码片段、PDF 文献）、随机化模板措辞、渲染过的评估结果（程序 + 输出 + 分数）、以及 *meta prompt evolution*（让 LLM 自己在额外步骤生成指令与上下文，并与解程序并行地共进化）。
- *OpenEvolve*（`prompt/sampler.py`）：用户消息由若干小节拼成——`previous_attempts`（最近 3 次尝试的改动摘要 + 与父代的数值对比结论：全部改善/全部退化）、`top_programs`、`diverse_programs`（从 top 之后随机抽，标记为 D1、D2）、`inspirations`（并会剔除已在前两节里出现过的 id，避免同一程序重复占 token）、`artifacts`（stderr / traceback / `llm_feedback` / `build_warnings`，按 `max_artifact_bytes` 截断，默认 20 KB）。artifact 渲染前过一遍「安全过滤」：剥 ANSI 转义、把 32 位以上字母数字串和 `sk-...` 形状的串替换成占位符。模板措辞可以随机化（`use_template_stochasticity`）。
- *ShinkaEvolve*（论文 §3.3 与源码）：current program 代码块 → 性能指标 → 可选 text feedback → Instructions → Task，末尾附 「不要整段重写，只做针对性修改」；inspiration 的排序有 `inspiration_sort_order = "ascending"`（按分数升序，和 FunSearch 同构），另加 `num_top_k_inspirations = 1` 与 `num_archive_inspirations = 1` 两个来源；meta 建议每 10 代追加一次。

*推断*：真正影响收敛的是三件事，而不是措辞——(1) 历史解的 *排序方向*（升序编号让模型看到「演进方向」）；(2) *分数与失败信息一起入 prompt*（artifacts 是 OpenEvolve 里性价比最高的机制）；(3) *禁止调用祖先*（否则评估复杂度会随代数爆炸）。

=== 去重与血缘追踪

- *行为去重*（FunSearch）：同签名（逐测试得分元组）的程序归入同一 `Cluster`，一个 cluster 只作为一个采样单元，内部再按「越短越可能被选中」抽样。这同时做了去重与压缩：行为相同的解不会各自占一个 prompt 名额。
- *血缘短路*（FunSearch）：`_calls_ancestor()` 检查生成程序是否调用了任何 `fn_v*` 祖先函数；`evaluator.analyse` 只有在「运行成功 且 未调用祖先 且 输出非空」时才把分数写入数据库。
- *格点去重*（OpenEvolve）：MAP-Elites 一格一程序是主要去重手段；叠加两层近似去重——embedding 余弦相似度超过 `similarity_threshold`（默认 0.99）则交给 `_llm_judge_novelty` 用 LLM 判定是否算新程序（相似度代码注释标明「Adapted from SakanaAI/ShinkaEvolve」）；迁移时再跳过目标岛已有同源代码的程序。
- *可追溯性*（OpenEvolve）：`evolution_trace` 可写成 `jsonl`/`json`/`hdf5`，字段含父子程序、prompt、LLM 响应、artifacts、island 与耗时（`include_prompts` 默认开启），定位是给 RL 训练和事后分析用；数据库还保存每个程序的 `prompts` 与 `artifacts_json`。
- *子代计数进搜索*（ShinkaEvolve）：$N(P_i)$ 直接进父代采样权重，血缘宽度成了搜索信号而不是纯粹日志；`island_spawn_subtree_size` 决定开新岛时复制多少祖先链上的程序；WebUI 提供 genealogy tree 视图。
- *血统膨胀事故*（OpenEvolve 源码注释）：见前文 183 个后代拷贝的例子——*血缘去重必须防「迁移副本再次迁移」这类环路*，否则拷贝数呈指数增长，且同源代码落入同一格点后被反复丢弃，白烧评估预算。

*推断*：本地插件应当把「内容哈希」升级为「语义近邻 + 内容哈希」双保险：先算归一化代码的哈希做精确去重（几乎零成本），再用本地嵌入模型（无需联网）与同岛程序算余弦，超过阈值就复用同一条评估结果而不是重新跑评估——评估是整条流水线里最贵的环节。

=== 最小可用的「进化搜索 MCP 工具」接口设计

协议事实（MCP 规范 2025-06-18）：工具由 `tools/list` 发现、`tools/call` 调用；工具定义含 `name`、`title`、`description`、`inputSchema`（JSON Schema）、可选 `outputSchema` 与 `annotations`；结果的结构化数据放在 `structuredContent`，非结构化内容放在 `content` 数组，工具内部错误用 `isError: true` 表达而不是 JSON-RPC 协议错误
#link("https://modelcontextprotocol.io/specification/2025-06-18/server/tools")[MCP Tools 规范]。stdio 传输下：客户端把 server 当子进程启动，消息按行分隔 JSON-RPC，*server 的 stdout 只能写合法 MCP 消息*，日志必须走 stderr
#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/transports")[MCP Transports 规范]。

本机两种真实清单形态（只读核对本机 `~/.kimi-code/plugins/managed`）：

- `kimi-datasource/kimi.plugin.json` 用 `mcpServers.data = { command: "node", args: ("...mjs",), cwd: "./" }`；
- `superpowers/.kimi-plugin/plugin.json` 用 `skills: "./skills/"` 与 `sessionStart.skill`，*不含* `mcpServers`。

*推断*：本插件应同时提供 `skills/<name>/SKILL.md`（教 agent 何时调用、如何写 evaluator）与 `mcpServers.evolution`（持有数据库与沙箱），清单字段按上表两组实测形状拼装。

*核心设计判断（推断）*：*MCP server 不做 LLM 调用*。把「变异算子」留给宿主 agent（Kimi Code 自己），server 只做「数据库 + 评估器 + 沙箱」这一半。好处有三：插件零 API key，用的是订阅额度；换模型/换 prompt 策略不必改 server；agent 可以把自身工具（Lean、julia、typst、文献检索）直接揉进变异过程。

最小工具集（6 个，名字全部是本文设计，非既有 API）：

#table(columns: 3,
  [*工具*], [*关键输入*], [*输出要点*],
  [`evolution_init`], [`task_dir`、`feature_dimensions`、`num_islands`、`budget`], [`run_id`、初始程序的 `program_id`],
  [`evolution_prompt`], [`parent_id`、`num_inspirations`、`patch_type`], [拼好的 prompt（含 top-K、inspirations、artifacts）、被排除的重复 id],
  [`evolution_submit`], [`parent_id`、`code` 或 patch、`operation`], [`program_id`、是否入格、落格坐标、去重结论（拒绝原因）],
  [`evolution_query`], [`program_id` 或 `top_k`、`metric`], [程序源码、指标、`parent_id`、血缘树、岛统计],
  [`evolution_status`], [`run_id`], [代数、评估次数、`budget` 余量、沙箱失败计数],
  [`evolution_export`], [`run_id`、`format`], [SQLite 路径、`jsonl` 轨迹、最优程序源码（可直接进 `doc/` 或版本控制）],
)

状态与契约细节（推断，但每条都对应上面某个开源实现的既有做法）：

- 存储：单文件 SQLite，`programs(id, parent_id, generation, island, cell_key, code_hash, code, metrics_json, operation, created_at)` + 只追加的 `events` 表；大 artifact（stderr、profiling）落文件，库里只存路径——OpenEvolve 的 `artifacts_json` + `artifact_dir` 就是这个分工。
- `metrics_json` 里必须有 `combined_score`：OpenEvolve 在缺失时会打警告并退化成「所有数值指标的平均」，显式给出可避免静默劣化。
- `evolution_submit` 的成功/失败一律走 `structuredContent` 里的 `ok` / `rejected_reason`，只有参数校验失败才用 JSON-RPC 错误；评估崩溃用 `isError: true`（规范里「Tool Execution Errors」与「Protocol Errors」的分工）。
- 评估永远在 *独立进程组* 里跑，server 进程本身绝不 `exec` 候选代码：候选代码若把承载 JSON-RPC 的 stdout 写脏或把进程 OOM，整个会话就断了。
- 长评估不要阻塞单次调用：stdio 下 `tools/call` 是请求—响应往返，应做成「提交后立即返回 `job_id`，由 `evolution_status` 轮询」，评估结果另存 pending 表，下一次 `evolution_submit` 时一并结算。

=== 评估

- *该抄*：OpenEvolve 的「每岛一张特征图 + `feature_bins = 10` + 一格只留 fitness 更优者」。它用 `"-".join(bins)` 当格点键，代码不到 20 行就能落地，且天然解决「近似重复程序挤占 prompt 名额」。*该避免*：别把特征维度只设成 `complexity` 一类单维指标，单维格点会退化成爬山；至少要有一个从 evaluator 回来的 *任务相关* 维度（如误差上界、运行时间、解的结构规模）。
- *该抄*：ShinkaEvolve 的父代权重 $w_i = s_i dot h_i$，把 `offspring_count` 当一等信息（默认 `parent_selection_strategy = "weighted"`、`lambda = 10.0`）。*该避免*：只实现 pure power-law 或纯 top-k 采样——论文的消融显示加权采样优于随机搜索与爬山，而纯爬山会在局部最优上烧完全部预算。
- *该抄*：行为签名去重（FunSearch 的「逐测试得分元组」聚类 + 同簇内偏向短程序）与 `_calls_ancestor` 式的血缘短路检查。*该避免*：只做字符串/内容哈希去重——不同实现、同一行为的候选会被反复评估，评估是最贵的一环。
- *该抄*：OpenEvolve 的 artifacts 回喂（stderr / traceback / build warnings / LLM 反馈截断到 20 KB），以及渲染前的占位符过滤。*该避免*：把整段 stderr 或 profiling 原样塞进 prompt——它既烧 token 又可能把测试集内容泄漏给模型（评估集泄漏会让「发现」变成过拟合）。
- *该抄*：ShinkaEvolve 的 `EVOLVE-BLOCK-START/END` 标记 + 补丁非法时带解析错误重采样（`max_patch_resamples = 3`），以及 `numeric_threads_per_job` 那套 `OMP_NUM_THREADS`/`MKL_NUM_THREADS` 环境变量上限。*该避免*：把候选代码放在进化主进程里跑（OpenEvolve 就这样，且其默认配置自述 CPU/内存限制「尚未实现」；ShinkaEvolve 本地作业也只是一条裸 `Popen`）。本机有 `bwrap` 与 Docker，起步就该用 `--unshare-net --unshare-pid --die-with-parent` 加 `prlimit --as`/`timeout`，不要先上线再补。
- *该避免*：把 LLM 调用放进 MCP server 内。一旦 server 自己持有模型客户端，就同时锁死了 API key 管理、模型切换、prompt 策略的迭代速度，还让「服务器只做数据库与评估器」的职责边界失效；同时注意迁移/复制副本必须打标记防止二次迁移（OpenEvolve 记录的 183 个后代拷贝就是这样产生的）。

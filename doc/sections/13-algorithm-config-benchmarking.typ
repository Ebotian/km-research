== 算法配置、调参与基准测试框架

本节把所有可核查的事实与来源并列给出；凡标为「*推断*」的句子是本项目作者的判断，不是来源陈述。

=== 配置器的定位与选型

#table(columns: 2,
  [*工具*], [*机制与适用场景*],
  [`SMAC3`],
  [贝叶斯优化（随机森林代理模型）+ 激进 racing 以尽早淘汰劣质配置；Python 3 实现，代理模型的随机森林为 C++。
  文档自述在 Python 3.8/3.9/3.10 上持续测试。#link("https://automl.github.io/SMAC3/main/")[SMAC3 文档]
  其 `Scenario` 直接接收 `ConfigSpace` 的 `ConfigurationSpace`，并提供 `instances` / `instance_features`（把实例特征并入代理模型的输入矩阵）
  与 `min_budget` / `max_budget`（多保真度）。#link("https://automl.github.io/SMAC3/main/advanced_usage/4_instances/")[跨实例优化]],

  [`irace`],
  [Iterated Racing（Iterated F-race 的推广），R 实现；面向「给定实例集合、寻找最合适的参数配置」的离线调参，内置自适应 capping 压缩评估总时间。
  参数定义支持四种类型：`i`（整数）、`c`（类别）、`r`（实数）、`o`（序数），可用 `i,log` / `r,log` 做对数采样，另有 `conditions`（条件参数）、
  `forbidden`（禁止组合）、`isFixed`。#link("https://mlopez-ibanez.github.io/irace/")[irace] #link("https://mlopez-ibanez.github.io/irace/reference/readParameters.html")[readParameters]],

  [`Optuna`],
  [define-by-run 的 Python API，模型是 `study` 与 `trial`。采样器含 `TPESampler`（默认）、`GPSampler`、`CmaEsSampler`、
  `NSGAIISampler` / `NSGAIIISampler`、`QMCSampler`、`BoTorchSampler`；剪枝器含 `MedianPruner`、`HyperbandPruner`、
  `SuccessiveHalvingPruner`、`WilcoxonPruner`、`PatientPruner`。#link("https://optuna.readthedocs.io/en/stable/reference/samplers/index.html")[samplers] #link("https://optuna.readthedocs.io/en/stable/reference/pruners.html")[pruners]],

  [`Ax` / `BoTorch`],
  [`BoTorch` 是建在 PyTorch 上的低层 BO 研究库；`Ax` 是其上的平台，管理 experiment/trial 与 orchestration，
  并把特征变换、元数据、存储等细节藏起来。官方明确建议不做 BO 研究的终端用户直接用 `Ax`，把 `BoTorch` 当实现新算法的低层 API。
  `Ax` 同时支持连续、整数、离散与混合空间。#link("https://github.com/meta-pytorch/botorch")[BoTorch] #link("https://ax.dev/docs/why-ax")[Why Ax]],
)

按搜索空间类型选型（*推断*，机制依据来自上表来源）：

- 类别维度占多数、或存在大量条件依赖时，`irace` 的 racing + 检验淘汰通常比 GP 型 BO 更稳；`SMAC3` 用随机森林代理，对高维类别与条件空间同样友好。
- 纯连续、维度不高（数十维以内）、每次评估很贵时，GP 类（`BoTorch` 的蒙特卡洛采集函数、`Optuna` 的 `GPSampler`）样本效率最好。
- 多目标 / 带约束优先 `Ax`（多目标与约束是一等公民），或用 `Optuna` 的 `NSGAIISampler`。
- Optuna 官方表格给出的「推荐 trial 预算」可用于判断规模是否匹配：`TPESampler` 100–1000、`GPSampler` 约至 500、
  `CmaEsSampler` 1000–10000、`BoTorchSampler` 10–100；`CmaEsSampler` 的类别参数与条件空间只算「可用但低效」，且不支持多目标。
  `TPESampler` 的条件搜索空间需要显式使用其 `group` 选项。
- 需要「每次评估都要重跑真实求解器」的场景，务必先看两处可复现性限制：SMAC 文档写明
  「只有单 worker、且不涉及任何时间（wall-clock 或 CPU time）时才能保证可复现」；Optuna 文档写明当 `n_jobs != 1` 时采样器会重新播种，
  「几乎无法复现优化结果」。#link("https://automl.github.io/SMAC3/main/advanced_usage/11_reproducibility/")[SMAC 可复现性] #link("https://optuna.readthedocs.io/en/stable/reference/samplers/index.html")[samplers]

=== 标准化数据格式：ASlib 与 AClib

ASlib 是 algorithm selection 场景的标准格式与仓库，覆盖 SAT、QBF、MaxSAT、CSP、MIP、TSP、TTP 等领域；
GitHub 上的 `aslib_data` 仓库当前有 46 个场景目录（含 `SAT11-RAND`、`MIP-2016`、`QBF-2016`、`TSP-LION2015` 等）。
#link("https://www.coseal.net/aslib/")[ASlib] #link("https://github.com/coseal/aslib_data")[aslib_data] #link("https://arxiv.org/abs/1506.02465")[AIJ 2016 论文]

每个场景目录由下列文件构成（名称与语义均取自官方格式规范，`*` 表示可选）：
`readme.txt`、`description.txt`、`feature_values.arff`、`feature_runstatus.arff`、`feature_costs.arff`（`*`）、
`algorithm_runs.arff`、`cv.arff`、`ground_truth.arff`（`*`）、`citation.bib`（`*`），
以及对称的 `algorithm_feature_values.arff` / `algorithm_feature_runstatus.arff` / `algorithm_feature_costs.arff`。
#link("https://github.com/coseal/aslib-spec/blob/master/format.md")[格式规范]

- `description.txt` 是 YAML，字段包括：`scenario_id`、`performance_measures`（按重要性降序）、`maximize`、
  `performance_type`（每个指标只能取 `runtime` 或 `solution_quality`）、`algorithm_cutoff_time`、`algorithm_cutoff_memory`、
  `features_cutoff_time` / `features_cutoff_memory`、`algorithm_features_cutoff_*`、`number_of_feature_steps`、
  `feature_steps`（每步有 `provides` 与 `requires`，用依赖表达「探针特征依赖预处理」这类关系）、`default_steps`、
  `features_deterministic` / `features_stochastic`、`metainfo_algorithms`。
- `metainfo_algorithms` 里每个算法的*必填*字段是 `configuration`（参数配置，可为空串）与 `deterministic`（真/假）；
  `version`、`call_string`、文字描述是*可选*字段；算法名建议不超过 15 个字符。
- `algorithm_runs.arff` 每行是一次实验，列序固定为 `instance_id`、`repetition`、`algorithm`、各 performance measure、最后 `runstatus`。
  `runstatus` 取值是六值枚举 `{ok, timeout, memout, not_applicable, crash, other}`；该文件*禁止* `?`：
  runtime 类场景下 runtime 总是已知，`solution_quality` 类的缺失值必须由场景设计者给出领域特定的填补方案。
- `(instance_id, repetition)` 必须唯一；每个「算法 × 实例」的重复次数要一致，但不同算法之间可以不同（确定性算法跑一次、随机算法跑多次）。
  `instance_id` 可与 `feature_values.arff` 的对应列对齐；官方*强烈建议*用可读实例名而不是纯数字，理由之一正是「便于事后复现实验」。
- `feature_runstatus.arff` 用*特征步骤名*为列，取值 `{ok, timeout, memout, presolved, crash, unknown, other}`；
  至少一个步骤状态为 `presolved` 表示实例在特征计算阶段就被解出。
- `feature_costs.arff` 按特征步骤记成本。规范明确：若没有这个文件，「相对最佳单一算法的 runtime 改进」这类分析就做不了。
- `cv.arff` 只有三列 `instance_id` / `repetition` / `fold`，支持重复交叉验证；一般由仓库服务器统一生成，
  目的是让所有 selector 在同一划分上被评估（这是 ASlib 消除「既选又评」偏差的机制）。
- `readme.txt` 必须说明：数据来源与生成方式、算法要解决什么问题、性能如何度量、
  *所用 solver 及其配置、版本与来源*、特征生成器的引用，以及每个缺失值/`crash`/`other` 的原因。
- 缺失值统一用 ARFF 的 `?`，且必须在 `readme.txt` 解释；除 `?` 之外不得用别的占位。

AClib 是同一思路在*算法配置*问题上的对应物：目标算法 × 目标实例 × 性能度量，找使度量最小的参数设置。
站点列出 326 个场景（270 `sat`、21 `ml`、20 `planning`、4 `mip`、4 `tsp`、3 `asp`、2 `btsp`、2 `timetabling`）、
31 个 target algorithm、74 个实例集；但最后一版是 2014-09-12 的 v1.2，安装脚本要求 Python 2.7 与 Ruby 1.9，已明显过时。
`irace` 仍保留 `aclib` 兼容开关（配合 `GenericWrapper4AC` 作为 `targetRunner`）。#link("https://www.aclib.net/")[AClib]

*推断*：对本项目最划算的用法是把 ASlib 的两张表（`algorithm_runs.arff` + `feature_values.arff`）直接当作实验落盘格式，
并把 `runstatus` 六值枚举原样采用——这样「超时/内存耗尽/不适用」在数据层就可见，且能复用 aslib 的 R/Python 生态做 algorithm selection。

=== 基准套件：规模与获取

#table(columns: 2,
  [*套件*], [*规模、结构与获取方式*],
  [MIPLIB 2017],
  [Collection Set 1065 个实例（`collection-v1.test` 实测 1065 行），Benchmark Set v2 共 240 个实例（`benchmark-v2.test` 实测 240 行）。
  实例分 easy / hard / open，官方定义：easy 指用 out-of-the-box 求解器在*一小时以内、至多 16 线程、标准桌面硬件*上可解；
  hard 指需要更长运行、或非标准硬件/算法才被解出；open 指尚未被求解。
  `collection.zip` 3.5 GB、`benchmark.zip` 317.3 MB。#link("https://miplib.zib.de/")[MIPLIB 2017] #link("https://miplib.zib.de/download.html")[下载页]],

  [SAT Competition 2025],
  [Main Track 使用 300–600 个 benchmark（Global Benchmark Database 上 `track=main_2025` 实际列出 400 个实例文件，实测），
  时间上限 5000 秒、内存上限 30 GB，按 PAR-2 排名（未解实例计为 runtime 加两倍 timeout），必须同时提供 SAT model 与 UNSAT 证明（可选证明检查器）。
  Parallel Track 在 AWS 上执行，wall-clock 上限 1000 秒，机器为 `m6i.16xlarge`（64 个虚拟核、256 GB 内存）。
  参数者每人必须提交 20 个新实例，其中至少 10 个既不能「MiniSat 一分钟内可解」，也不能「本人求解器一小时内解不出」。
  #link("https://satcompetition.github.io/2025/tracks.html")[tracks] #link("https://satcompetition.github.io/2025/benchmarks.html")[benchmarks]],

  [Global Benchmark Database],
  [SAT Competition 的实例下载入口。下载 `track_main_2025.uri` 后用 `wget --content-disposition -i track_main_2025.uri` 批量取实例；
  支持查询语言（如 `track=main_2024`），可查 `maxsat`/`wcnf`/`opb`/`cnf` 等 context。论文为 Iser 与 Jabs, SAT 2024。
  #link("https://benchmark-database.de/?track=main_2025&context=cnf")[benchmark-database.de] #link("https://doi.org/10.4230/LIPIcs.SAT.2024.18")[DOI]],

  [SATLIB（DIMACS CNF）],
  [均匀随机 3-SAT 相变区实例集，全部为 DIMACS CNF：`uf20-91` 1000 个（全可满足）、`uf50-218` / `uuf50-218` 各 1000、
  `uf75-325` / `uuf75-325` 各 100、`uf100-430` / `uuf100-430` 各 1000、`uf125-538` 至 `uf200-860` 各 100（可满足/不可满足成对）。
  CNF 格式为 `p cnf nbvar nbclauses` 头 + 以 0 结尾的子句行。#link("https://www.cs.ubc.ca/~hoos/SATLIB/benchm.html")[SATLIB]],

  [TSPLIB],
  [对称 TSP 索引页列出 107 个 `.tsp` 实例文件（`a280`、`att532`、`d18512`、`usa13509` 等），提供 `ALL_tsp.tar.gz` 与 `.opt.tour` 最优解。
  `pla85900.tsp.gz` 可下载（实测 HTTP 200，449863 字节）。官方声明：除 Hamiltonian cycle 问题外，
  所有实例都定义在*完全图*上且距离为*整数*——这一点常被忽略，会造成不兼容的变体比较。该库自 2013-01-01 起不再新增实例。
  #link("https://comopt.ifi.uni-heidelberg.de/software/TSPLIB95/")[TSPLIB] #link("https://comopt.ifi.uni-heidelberg.de/software/TSPLIB95/tsp/tspindex.html")[TSP 数据索引]],

  [DIMACS],
  [Implementation Challenge 系列共 13 届：第 2 届（1992–93）为 Max Clique / Graph Coloring / Satisfiability，
  第 12 届（2020–22）为车辆路径，第 13 届（2026–2027）为 Network Flows 2.0。
  图着色实例中 `.col` 为 DIMACS 标准格式、`.col.b` 为压缩二进制格式，含 `DSJC1000.5`（1000 节点 / 499652 边）、
  `latin_square_10`（900 / 307350）、`flat1000_76_0`（1000 / 246708，最优 76）等，并给出已知最优着色数。
  #link("https://dimacs.rutgers.edu/programs/challenge/")[挑战系列] #link("https://mat.tepper.cmu.edu/COLOR/instances.html")[着色实例]],

  [PSPLIB],
  [单模式 RCPSP：`j30` 480 个（全部已证最优）、`j60` 382/480、`j90` 375/480、`j120` 89/600 已证最优。
  每套提供 TGZ/ZIP、HRS（启发式最好解）、LB（下界）、OPT（仅已证最优实例）、JSON 汇总；
  压缩包命名为 `<实例集>.<模式>.tgz`（`sm` 单模式、`mm` 多模式），例如 `j30.sm.tgz`。
  #link("https://www.om-db.wi.tum.de/psplib/")[PSPLIB] #link("https://www.om-db.wi.tum.de/psplib/getdata.php?mode=sm")[单模式数据集]],

  [CVRPLIB],
  [家族包含 Set A 与 Set B（Augerat et al., 1995）以及 `CMT`、`E-n`/`F-n`/`M-n`/`P-n`、`Golden`、`tai`、
  `X-n`（100 个，实测计数）等；站点列出 Augerat、Christofides、Fisher、Uchoa 等来源；2025 年起由 Rafael Martinelli 维护，另有 BKS Challenge、解检查器与 XML100。
  实例同时给出 UB 与「是否已知最优」，因此比较时必须区分「打平 BKS」与「证明最优」。
  #link("https://vrp.galgos.inf.puc-rio.br/index.php/en/")[CVRPLIB] #link("https://vrp.galgos.inf.puc-rio.br/index.php/en/about")[About]],
)

*推断*：套件本身带时间维度——MIPLIB 的 solufile 36（2026-01-26）一次更新就含 40 个更优 incumbent，并把 2 个实例由 optimal 降为 easy、
2 个由 optimal 升为 hard、30 个由 hard 降为 easy；SAT Competition 每年换题。因此实验记录里必须 pin「下载日期 + 实例清单文件哈希」，
只写套件名不足以支撑复现。

=== 一次严谨实验必须记录什么

#table(columns: 3,
  [*字段*], [*要求*], [*一手依据*],
  [实例标识], [用可读名而非纯数字；同时存实例清单文件哈希], [ASlib 规范 `feature_values.arff` 一节],
  [重复编号], [`(instance_id, repetition)` 唯一；每个「算法 × 实例」重复次数一致，算法之间可不同], [ASlib 规范 `algorithm_runs.arff` 一节],
  [随机种子], [区分确定性与随机算法；随机算法必须记录实际使用的 seed], [ASlib `metainfo_algorithms.deterministic`；SMAC `Scenario.seed` 与 `deterministic`],
  [超时与内存上限], [`algorithm_cutoff_time` / `algorithm_cutoff_memory`（MB）；配置过程另记 wall/CPU 预算], [ASlib `description.txt`；SMAC `trial_walltime_limit`、`trial_memory_limit`、`walltime_limit`、`cputime_limit`],
  [运行状态], [六值枚举 `ok/timeout/memout/not_applicable/crash/other`，并在 `readme.txt` 解释每个 `crash` 与 `other`], [ASlib `runstatus` 定义],
  [硬件], [CPU 型号、核数、内存、是否容器及镜像标识], [SAT Competition 明示 Parallel Track 的机器型号与规格；MIPLIB 用「一小时、至多 16 线程」定义 easy],
  [求解器版本与配置], [版本号、参数配置、完整命令行], [ASlib `metainfo_algorithms` 必填 `configuration`，建议 `version` 与 `call_string`；`readme.txt` 必须写明 solver 配置、版本与来源],
  [特征计算成本], [按特征步骤记成本，并设特征计算的超时/内存上限], [ASlib `feature_costs.arff` 与 `features_cutoff_*` 字段],
  [时间度量定义], [明确性能指标是 runtime 还是 solution_quality；不要混用], [ASlib `performance_type` 只允许这两个取值],
  [目标函数单位], [`targetRunner` 返回的 cost 与 time 必须与 `maxTime` 同单位], [irace `defaultScenario` 的 `maxTime` 说明],
)

建议的落盘结构（与 ASlib 同构，便于复用其解析生态）：

```yaml
# runs.jsonl 每行一条实验记录；字段语义对齐 description.txt 与 algorithm_runs.arff
instance_id: miplib/flugpl
instance_sha256: 3f2b...            # 实例文件哈希
suite: MIPLIB2017-benchmark-v2      # 套件版本 pin
manifest_sha256: 9c41...            # 实例清单文件哈希
algorithm: "gurobi"                 # 算法名，至多 15 字符
version: "12.0.1"
call_string: "gurobi_cl MIPGap=0.01 TimeLimit=3600 instance.mps"
configuration: '{"Heuristics": 0.1}'
seed: 1
repetition: 1
performance_type: runtime
runtime_s: 3600.0
runstatus: timeout                  # ok|timeout|memout|not_applicable|crash|other
cutoff: {time_s: 3600, memory_mb: 16384}
host: {cpu: "...", cores: 12, ram_gb: 32, container_digest: "sha256:..."}
```

=== 实验编排：Hydra、Snakemake、Nextflow

- `Hydra`：用 composition 组织层级配置，支持命令行覆盖；`--multirun`（`-m`）一次跑多组参数，输出目录形如 `multirun/2020-01-09/01-16-29`。
  通过 sweeper 插件把搜索交给 `Optuna`（`hydra-optuna-sweeper`，配置 `hydra/sweeper=optuna`）或 `Ax`（`hydra-ax-sweeper`，`hydra/sweeper=ax`），另有 Nevergrad sweeper。
  #link("https://hydra.cc/docs/intro/")[Hydra] #link("https://hydra.cc/docs/plugins/optuna_sweeper/")[Optuna sweeper] #link("https://hydra.cc/docs/plugins/ax_sweeper/")[Ax sweeper]
- `Snakemake`：用 Python 风格规则描述工作流 DAG，可以把每步所需的软件（conda / 容器）随规则声明并自动部署到执行环境；
  同一份工作流定义可扩展到服务器、集群、网格与云；运行可转成自包含的浏览器报告，把结果与所用参数、代码、软件绑在一起。
  #link("https://snakemake.readthedocs.io/en/stable/")[Snakemake] #link("https://snakemake.readthedocs.io/en/stable/snakefiles/deployment.html")[deployment]
- `Nextflow`：dataflow 编程模型，`-resume` 依赖任务缓存；缓存 key 由*会话 id、任务名、容器镜像、任务环境*等元数据哈希而成；
  可部署到本机、HPC 调度器与云，支持容器与包管理器。#link("https://www.nextflow.io/docs/latest/index.html")[Nextflow] #link("https://www.nextflow.io/docs/latest/cache-and-resume.html")[cache and resume]

*推断*的选型建议：本机 12 核（`nproc` 实测），最省事的是 `Hydra --multirun` + 自带 sweeper，把每个 job 写成一条 JSONL run record；
当「实例数 × 重复数」上千、且需要缓存与断点续跑时再上 `Snakemake`。注意本机 `snakemake` 与 `nextflow` 均未安装。
无论用哪一层，容器镜像 digest 或 conda 环境导出都必须写进 run record——Nextflow 把容器镜像与环境算进缓存 key，正说明没有它们就无法判断「同一实验」。

=== 常见统计错误

1. 只报点估计。`rliable` 的对照表把「忽略统计不确定性」列为首要问题，并指出标准差经常被省略，推荐用分层 bootstrap 置信区间。
2. 汇总指标选错。均值会被离群任务主导，中位数统计效率低（近一半任务为 0 也不改变中位数）；推荐四分位均值（IQM），
   并补充 probability of improvement 与 optimality gap。#link("https://arxiv.org/abs/2108.13264")[Agarwal 等, NeurIPS 2021] #link("https://github.com/google-research/rliable")[rliable]
3. 删失（超时）处理不当。SAT Competition 用 PAR-2 排名，即未解实例按「runtime 加两倍 timeout」计入：
   $ "PAR-2" = 1/n sum_(i=1)^n t_i , quad t_i = cases(t_i &"若求解成功", 2 T &"若超时") $
   把 timeout 当作真实 runtime、或直接丢弃未解实例，都会系统性低估困难实例。
4. 多重比较不做校正。`irace` 把检验方式暴露为四档：`F-test`（Friedman）、`t-test`（逐对、无校正）、`t-test-bonferroni`、`t-test-holm`；
   默认在开启 capping 时用 t-test，其余情况用 F-test。Demšar 的经典结论是「多算法 × 多数据集」应使用 Friedman 检验加事后检验，
   而非逐对 t 检验。#link("https://mlopez-ibanez.github.io/irace/reference/defaultScenario.html")[irace 默认场景] #link("https://www.jmlr.org/papers/v7/demsar06a.html")[Demšar 2006]
5. 过度解读 performance profile。Gould 与 Scott 用真实应用数据与人工例子说明：解读性能剖面来判定求解器相对优劣时必须谨慎，
   否则容易得出错误结论。#link("https://doi.org/10.1145/2950048")[TOMS 2016]
6. 在测试集上做选择。algorithm selection 与配置的本质就是「同一批数据既选又评」，ASlib 用统一生成的 `cv.arff` 固定划分来消除这一偏差；
   自己的实验也必须固化划分文件并在所有对比中引用它。
7. 并行导致不可复现。SMAC 文档：单 worker 且不涉及任何时间才可保证可复现，且 `SMBO.reset()` 不会恢复原始 seed；
   Optuna 文档：`n_jobs != 1` 时采样器重新播种，几乎无法复现。
8. 运行次数不足且不报方差。这是 `rliable` 整篇论文的出发点：在 few-run 情形下忽略不确定性会让领域进展变慢。
9. 比较条件不一致。不同 cutoff、内存上限、线程数与硬件下的 runtime 不能直接相比。SAT Competition 用统一机器与统一时限、
   MIPLIB 用「至多 16 线程」来划界，都说明这些参数是结论的一部分。
10. *推断*：只要配置过程的目标或预算里含时间（adaptive capping、`maxTime`、`trial_walltime_limit`），
    「同一配置集合」的执行顺序就会依赖机器速度，过程本身不可复现；此时必须同时报告时间预算与机器规格。

另可参考的综述列出了值得对齐的八个方面：目标清晰、问题定义良好、算法合适、性能度量恰当、分析审慎、
设计有效、呈现可理解、可复现性有保证。#link("https://arxiv.org/abs/2007.03488")[Bartz-Beielstein 等] 机器学习侧的可复现性清单见 #link("https://arxiv.org/abs/2003.12206")[NeurIPS 2019 可复现性项目]。
「算法配置实验设计中的常见陷阱」（错误地比较不同实例集、在配置过程中引入时间依赖等）给出了更细的清单，并提出用 `GenericWrapper4AC` 自动规避其中一部分。#link("https://arxiv.org/abs/1705.06058")[Pitfalls and Best Practices in Algorithm Configuration]

=== 评估

- *该抄 ASlib 的双表与 `runstatus` 枚举*：插件把每次求解落成「实例 / 算法 / 各 performance / `runstatus`」一行与「实例 / 特征值」一行，
  并用同一套六值枚举。这样「超时、内存耗尽、不适用」在数据层就显式可见，且能直接复用 aslib 的 R/Python 生态做 algorithm selection，
  不必自造格式。
- *该抄 irace 的 `testType` 设计*：把统计检验与多重比较校正做成用户可选枚举（Friedman F-test / 逐对 t-test / Bonferroni / Holm），
  默认开启校正；绝不让插件只输出「平均 runtime 排名」这一种榜单。
- *该抄 `cv.arff` 的固定划分*：首次评测即生成并固化划分文件（`instance_id`、`repetition`、`fold`），
  之后任何 selector 或配置对比都引用它；从机制上排除「在测试集上选配置」。
- *该抄基准套件的版本 pin 机制*：MIPLIB 的 solufile 编号与 GBD 的 `track_*_*.uri` 本质都是「带版本的实例清单」；
  插件应在 run record 里记录清单文件哈希与下载日期，而不是只记录套件名，否则 solufile 更新与每年换题会让历史结果失去可比性。
- *该避免把 wall-clock 当唯一目标却不记录环境*：SMAC 明确「涉及时间就无法保证可复现」，irace 的 `capping` / `maxTime` 同理。
  若插件用时间预算，必须同时记录核数、内存、是否容器与镜像 digest，并对时间型指标给出「不可跨机器比较」的提示。
- *该避免把本机缺失或过时的栈当作既有前提*：本机无 `z3`、`cvc5`、`sage`、`gap`、`cargo`；Python 为 3.14.6 且缺 `scipy`、`pandas`、`sklearn`、`optuna`；
  R 4.6.1 已装但 `irace` 包未装；`snakemake` 与 `nextflow` 未装；AClib 最后发布于 2014 年且要求 Python 2.7。
  插件应先用 `Bash` 探测能力再降级（例如缺 `optuna` 时退化为网格或随机搜索），而不是把安装这些依赖当成前提。

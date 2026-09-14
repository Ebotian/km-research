== 实验可复现性与溯源管理

本节的判断前提：插件服务的是「数学猜想形式化」「反例搜索」「算法上界改进」「算法实证评测」四类计算实验。
它们对可复现性的要求并不相同——前三类要的是*结论可判定*（找一个反例、或签出一份证明），第四类要的是*数字可重跑*（时间/空间的统计量）。
把这两者混为一谈，是绝大多数实验管理方案在数学场景下失败的根因。凡标「推断」者为作者推理而非实测。

=== 溯源记录的最小字段集

W3C 的 PROV-DM 给出了通用溯源模型：实体（Entity）、活动（Activity）、代理（Agent），以及 `wasGeneratedBy`、`used`、`wasAssociatedWith`、`wasDerivedFrom`、`wasAttributedTo` 等二元关系 #link("https://www.w3.org/TR/prov-dm/")[W3C PROV-DM]。
插件不需要实现这套模型，但记录字段应能无损映射到它的语义：*产物由某次运行生成；运行使用了某份代码与环境；运行归属于某个发起者*。
PLOS《Ten Simple Rules for Reproducible Computational Research》给出了更工程化的同构要求：规则 1（每个结果都记录其产生方式）、规则 3（归档所用外部程序的精确版本）、规则 4（所有自定义脚本纳入版本控制）、规则 6（含随机性的分析必须记录种子）、规则 10（公开脚本、运行与结果） #link("https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1003285")[PLoS Comput Biol 9(10): e1003285]。

下表是「一次运行」的最小溯源字段集，以及每一条为什么必须存在：

#table(columns: 3,
  [字段], [捕获方式], [为什么必要],
  [`run_id`], [运行开始前生成的不可变 ID；建议为输入内容的 `sha256` 前 12 位，而非时间戳], [时间戳会因重复运行而分叉；内容哈希让「同一实验」天然幂等，重跑可复用已有目录],
  [`git.commit` + `git.dirty`], [`git rev-parse HEAD`、`git status --porcelain`（非空即 dirty）], [只记 commit 会漏掉「跑的时候工作区有未提交改动」，这是最常见的复现失败原因。PLOS 规则 4 的落点],
  [`deps_lock_sha256`], [对锁文件（`uv.lock` / `Manifest.toml` / `lake-manifest.json` / `flake.lock`）整体求哈希并入档], [锁文件本身随提交变化；把它的哈希写进运行记录，才能区分「代码相同但依赖不同」],
  [`toolchain`], [`python --version`、`julia --version`、`lean --version`、`lake --version`、求解器 `--version` 的字符串数组], [Julia 的 `Manifest.toml` 只锁包不锁 Julia 本身，Lean 的 `lean-toolchain` 单独锁版本；解释器版本影响结果],
  [`argv`], [完整参数数组（不是拼接后的字符串）], [含空格的路径、含 `=` 的参数在拼接后不可还原；同时这也是「重跑命令」的唯一真源],
  [`env`], [白名单：`PYTHONHASHSEED`、`OMP_NUM_THREADS`、`MKL_NUM_THREADS`、`OPENBLAS_NUM_THREADS`、`LC_ALL`、`TZ`], [线程数直接改变浮点归约顺序；`PYTHONHASHSEED` 未固定时集合迭代顺序在进程间不同],
  [`seed`], [主种子 + 派生子种子的规则说明（见下文 SeedSequence 一节）], [PLOS 规则 6。注意「记录了种子」不等于「结果确定」，见并行不确定性一节],
  [`hardware`], [`CPU` 型号与核数、内存、内核版本；`nproc`], [计时类结论离开机器即失效；反例类结论通常与硬件无关，这一点应显式区分],
  [`timing`], [同时记 wall clock 与 CPU time，以及峰值 RSS], [算法上界改进的核心指标是 CPU 时间；容器/并行下 wall 时间会被调度噪声污染],
  [`exit_code` 与 `signal`], [子进程返回码；被信号杀死时记信号号], [区分「跑完且失败」与「没跑完就崩」，是后续自动筛选的必要条件],
  [`out_sha256`], [对规范化后的产物逐文件求哈希，汇总成字典], [唯一能让第三方做*逐位比较*的依据],
)

一次运行落盘为单个 `manifest.json`，字段名直接用上面这张表：

```json
{
  "run_id": "9f2c1a0b7d34",
  "started_at": "2026-09-14T08:31:02Z",
  "ended_at": "2026-09-14T08:47:55Z",
  "git": {"commit": "b1e9c0a", "dirty": false, "branch": "search/upper-bound"},
  "deps_lock_sha256": {"uv.lock": "3c1f...", "lean-toolchain": "aa07..."},
  "toolchain": ["Python 3.14.6", "typst 0.15.1"],
  "argv": ["python3", "-m", "bench.run", "--instance", "tsp/128", "--seed", "7"],
  "env": {"PYTHONHASHSEED": "0", "OMP_NUM_THREADS": "1", "LC_ALL": "C", "TZ": "UTC"},
  "seed": {"root": 7, "scheme": "numpy.SeedSequence.spawn"},
  "hardware": {"cpu": "AMD Ryzen 5 9600X", "nproc": 12},
  "timing": {"wall_s": 1012.9, "cpu_s": 4021.4, "peak_rss_kib": 883120},
  "exit_code": 0,
  "out_sha256": {"result.json": "5e77...", "trace.log": "0b93..."}
}
```

*推断*：字段集刻意不含「实验结论」本身。结论写在产物里，manifest 只做「输入到产物」的绑定；两者混在一个文件里会让 manifest 变成被手改的对象，从而失去证据价值。

=== 工具选型：哪些值得引入，哪些过度

下表只收录本次调研中读到一手文档的工具。判据是「在*本地插件*场景下，引入成本是否换来不可替代的能力」。

#table(columns: 4,
  [工具], [一手事实], [引入成本], [本项目结论],
  [`DVC`], [`.dvc` 文件是 YAML 数据占位符，记录 `md5`/`size`/`nfiles`/`remote`；`dvc.yaml` 定义 `stages`（`cmd`/`deps`/`outs`/`params`），`dvc.lock` 记录每阶段的依赖与产物哈希，`foreach`/`matrix` 可展开成多个阶段 #link("https://dvc.org/doc/user-guide/project-structure/dvcyaml-files")[dvc.org dvc.yaml]、#link("https://dvc.org/doc/user-guide/project-structure/dvc-files")[dvc.org .dvc Files]], [要装 `dvc`；数据版本化需配 remote（本地目录亦可）], [*仅在产物体积超过 Git 舒适区时引入*。它的 stage 缓存对「同参数重跑」有价值，但插件的主要产物是小体积 JSON/日志],
  [`git-annex`], [把大文件内容移出 Git，只留符号化位置记录；用简单仓库格式保证长期可读，支持离线/多副本 #link("https://git-annex.branchable.com/")[git-annex.branchable.com]], [Haskell 实现，安装与心智负担明显高于 DVC；命令语义与日常 Git 不同], [过度。插件不需要多副本同步与加密归档，只需要「大产物放哪」],
  [`Git LFS`], [在仓库中存指针文件（含 `oid` 与 `size`），真实内容存外部 #link("https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-git-large-file-storage")[GitHub Docs]], [需要服务端支持；本地纯离线场景不适用], [排除],
  [`Snakemake`], [规则可用 `container: "docker://..."` 与 `conda: "envs/test.yaml"` 声明执行环境；`snakemake --report` 生成自包含 HTML，默认包含运行统计与 provenance，统计来自工作目录下的 `.snakemake` 元数据目录，支持 `--report-metadata` 传入 YTE YAML 模板 #link("https://snakemake.readthedocs.io/en/stable/snakefiles/reporting.html")[snakemake docs]], [需要把实验重写成 DAG 规则；报告是「事后生成」而非运行期强制], [*值得借鉴机制，不必整体引入*：把 `.snakemake` 这种「元数据独立目录」和 `--report` 式的一键汇总抄过来],
  [`Hydra`], [自动创建输出目录存放日志与 YAML 配置；`hydra.run.dir` 与 `hydra.sweep.dir`/`subdir` 可配，支持 `${now:%Y-%m-%d}` 与 `${hydra_override_dirname:...}`（可按 `exclude_keys` 排除种子等键）；`--multirun` 做参数扫描；`--cfg job` 打印解析后的配置 #link("https://hydra.cc/docs/configure_hydra/workdir/")[hydra.cc workdir]、#link("https://hydra.cc/docs/advanced/hydra-command-line-flags/")[hydra.cc CLI flags]], [`hydra-core` + `omegaconf` 依赖；会接管进程启动与 cwd], [*目录约定值得抄*，框架本身不引入：`hydra_override_dirname` 的「目录名即参数」是极好的 `runs/` 命名法],
  [`MLflow`], [以 run 为基本单位，记录 metrics/params/起止时间与 artifacts；`mlflow.start_run()`、`mlflow.log_param()`、`mlflow.log_metric()`；不配服务端时*默认写入本地 `mlruns` 目录*；可用 `MlflowClient().search_runs()` 查询，`RunInfo` 含 `run_id`/`experiment_id`/`status`/`start_time` #link("https://mlflow.org/docs/latest/ml/tracking/")[mlflow.org Tracking]], [`mlflow` 包体积不小；默认行为已足够轻], [*可选*：若确需「多运行可查询」，用它的本地文件后端比自己写索引省事；但注意 `mlruns` 的 schema 由 MLflow 掌控，不宜作为唯一真源],
  [`Weights & Biases`], [以 `wandb.Run` 为单位，`Run.config` 存超参、`Run.log()` 记指标、artifacts 存产物 #link("https://docs.wandb.ai/guides/track/")[docs.wandb.ai]], [默认面向托管服务], [排除。本地插件不应把溯源数据放到需要联网的第三方],
)

总结：单个插件的实验记录，起步只需 *Git + 锁文件 + `manifest.json` + `runs/` 目录约定*，四者都不需要新依赖（`git`、`python3` 本机已有）。
只有当「多阶段长管道」或「大数据集版本化」真实出现时，才升级到 Snakemake 或 DVC。

=== 确定性复现

=== 种子管理

NumPy 的做法可作为模板：`SeedSequence` 把用户种子与「派生树路径」一起哈希到默认 128 位池中，`spawn(n)` 派生子序列；其文档给出碰撞概率上界约为 $n^2 2^{-128}$，百万级（$2^{20}$）流的碰撞概率约 $2^{-88}$ #link("https://numpy.org/doc/stable/reference/random/parallel.html")[NumPy Parallel RNG]。
文档明确指出的*错误*做法是把根种子与 worker ID 相加（`root_seed + worker_id`）：单次运行内各流互异，但换种子重跑时不同运行之间会重叠出相同子流，从而给整体统计引入偏差。
正确做法是把两者作为列表传入：`default_rng([worker_id, root_seed])`，且建议把变化的 ID 放在不变化的根种子*之前*，以免与库内部的 `spawn` 追加位置冲突。
文档另建议根种子用 `secrets.randbits(128)` 生成，以避开人类选种子的偏置。

同源事实（PyTorch）：即使种子相同，结果也*不保证*跨版本、跨提交、跨平台一致，CPU 与 GPU 之间同样不保证 #link("https://docs.pytorch.org/docs/stable/notes/randomness.html")[PyTorch Reproducibility]。
该文档列出可控项：`torch.manual_seed()`、`torch.use_deterministic_algorithms(True)`（对无确定性实现的操作直接报错）、`torch.backends.cudnn.benchmark = False`（禁用算法自动择优，从而同一进程内稳定选择同一算法）、`torch.backends.cudnn.deterministic = True`。
并明确警告：确定性实现通常比非确定性实现慢。

CPython 侧：`PYTHONHASHSEED` 未设置或设为 `random` 时，`str`/`bytes` 的哈希每次进程启动都不同；设为 `[0, 4294967295]` 内的整数则固定，`0` 表示关闭哈希随机化 #link("https://docs.python.org/3/using/cmdline.html")[CPython cmdline/env]。
这直接决定 `set`/`dict` 的迭代顺序——凡是「遍历集合后按顺序求解」的算法，不固定它就是每次跑出不同结果。

=== 并行不确定性与浮点一致性

浮点求和*不满足结合律*，因此计算结果取决于求和顺序；现代处理器会动态分配资源（核数、线程调度），同一程序两次运行不保证相同求和顺序 #link("https://bebop.cs.berkeley.edu/reproblas/")[ReproBLAS]。
该页面给出的可复现方案（ReproBLAS）把「重跑逐位一致」定义为可复现，并在仅假设 IEEE 754 二进制、round-to-nearest 与渐进下溢的前提下，做到与处理器数、数据划分、归约调度无关；其双精度默认内部精度至少 80 位，误差界为 $n 2^{-80} max|x_j| + 7 epsilon |sum x_j|$，其中 $epsilon = 2^{-53}$。

编译器侧：Clang 文档明确 `-ffast-math` 使 `+` 与 `*` 可结合、且 `x/y == x * (1/y)`，并把 `-ffp-contract` 设为 `fast`（即允许 FMA 合并） #link("https://clang.llvm.org/docs/UsersManual.html")[Clang UsersManual]。
这意味着一个用 `-ffast-math` 编译的求解器与用默认浮点编译的同一求解器*不是同一个程序*，重跑结论可能不同。

#table(columns: 3,
  [不确定源], [表现], [处置],
  [线程数], [BLAS/OpenMP 归约顺序随线程数变化，浮点结果末位漂移], [固定 `OMP_NUM_THREADS`/`OPENBLAS_NUM_THREADS`；要求逐位一致时压到 `1`，并把该值写进 `env`],
  [并行任务调度], [任务完成顺序影响聚合顺序], [用「按 key 排序后再聚合」替代「按完成顺序聚合」；或改用可交换且可结合、误差有界的归约],
  [编译器浮点标志], [`-ffast-math` 允许重结合与 FMA 合并], [禁用；若为性能必须开启，则把它连同编译器版本一起写入 `toolchain`],
  [哈希随机化], [`set` / `dict` 迭代顺序随进程变化], [`PYTHONHASHSEED=0`],
  [GPU 非确定性 kernel], [原子加等操作顺序不定], [启用确定性算法模式，或把 GPU 结果只当作「启发式」，不作为最终结论],
)

*推断*：对数学类实验，最省事的路线是*尽可能把不确定性挤出关键路径*——上界的证明、反例的验证用精确整数/有理数运算或可检查证书完成，浮点只用于搜索阶段的启发式排序。这样「重跑数字不一致」不会污染「结论是否成立」。

=== 环境封装的轻量方案与成本

#table(columns: 3,
  [方案], [一手事实], [成本与适配],
  [`uv`], [`pyproject.toml` 定位项目根；`.venv` 由 uv 管理且不建议纳入版本控制（会自动写入内部 `.gitignore`）；`uv.lock` 是*跨平台*通用锁文件，记录在所有 Python marker（OS、架构、Python 版本）下的精确解析版本，*应提交到版本控制*；锁文件由 uv 管理、不应手改，且格式为 uv 专有 #link("https://docs.astral.sh/uv/concepts/projects/layout/")[uv 文档]], [本机 `uv 0.12.3` 已装。这是本机成本最低的路径：`uv sync` 即可从锁文件重建环境],
  [`venv` + 锁文件], [同上的锁文件语义，但需自己保证「生成锁 → 安装」两步一致], [零额外依赖，但缺少跨平台解析与自动同步；只在不能用 uv 时退化使用],
  [`pylock.toml`], [PEP 751 已 *Final*（创建 2024-07-24，决议 2025-03-31，取代 PEP 665）；格式包含 `lock-version`、`environments`、`requires-python` 与 `packages` 列表（可记录 VCS 依赖的 `commit-id`、以及 wheel/sdist 的 `hashes`）；目标是*工具无关* #link("https://peps.python.org/pep-0751/")[PEP 751]], [uv 可 `uv export -o pylock.toml` 导出。若想让非 uv 的第三方也能装同一环境，这是当前唯一标准化出口],
  [`Julia` 原生], [`Project.toml` 描述依赖与兼容约束，`Manifest.toml` 是环境的绝对记录；给定这一对文件即可实例化完全相同的包环境；manifest 顶层含 `julia_version`、`manifest_format`、`project_hash`，每个包可含 `version`、`repo-url`、`repo-rev`（可到 commit）、`git-tree-sha1`；`Manifest-v{major}.{minor}.toml` 可按 Julia 版本分文件 #link("https://pkgdocs.julialang.org/v1/toml-files/")[Pkg.jl docs]], [本机 `julia 1.12.6` 已装。零额外工具，`Pkg.instantiate()` 重启环境],
  [`Lean/lake`], [mathlib4 仓库同时提供 `lean-toolchain`（内容形如 `leanprover/lean4:v4.34.0-rc2`）与 `lake-manifest.json`；后者对每个依赖记录 `url`、`type`、`rev`（commit 哈希）、`inputRev` #link("https://github.com/leanprover-community/mathlib4/blob/master/lake-manifest.json")[mathlib4 lake-manifest.json]], [本机 `lean`+`lake` 已装。Lean 侧的可复现性由这两个文件共同保证，注意 `lean-toolchain` 必须一起提交],
  [`Nix flakes`], [`flake.nix` 声明 `inputs`/`outputs`，`flake.lock` 用来钉住依赖版本；nix.dev 明确称 flakes 仍是*实验性*扩展格式、存在未决设计问题（RFC 49 在合并时被撤回，实现仍有问题） #link("https://nix.dev/concepts/flakes")[nix.dev Flakes]], [本机未安装 `nix`。学习曲线与磁盘成本最高，收益是「整个工具链（含编译器）可钉死」],
  [`容器`], [镜像 tag 是*可变*的：文档举例 `FROM alpine:3.21` 在三个月后可能解析到 `3.21.1` 也可能是 `3.21.4`；要保证「总是同一镜像」必须钉 digest，代价是放弃自动安全更新（官方建议配 Dependabot 的 `package-ecosystem: "docker"`） #link("https://docs.docker.com/build/building/best-practices/")[Docker build best practices]], [本机 `Docker 29.7.2` 已装且在运行。容器解决的是 OS 级依赖，与 uv/Manifest 是不同层次，二者不互相替代],
)

*推断*：本项目应把封装策略定成*分层*的——Python 用 `uv.lock`（已满足本机），Julia 用 `Manifest.toml`，Lean 用 `lean-toolchain` + `lake-manifest.json`；只有当某个求解器依赖特定系统库（本机 `z3`/`cvc5`/`sage` 等均缺失）时，才对该求解器单独用容器或钉 digest 的镜像。Nix 引入成本与本项目收益不匹配。

=== 产物目录约定与结果 schema

Hydra 的默认形态可直接作为命名法参考：单次运行写到 `outputs/`，用 `${now:%Y-%m-%d}/${now:%H-%M-%S}` 或 `${hydra_override_dirname:}` 命名；多运行写到 `multirun/` 下按参数组合分子目录，并可用 `exclude_keys` 把种子从目录名里挪出来单独成层 #link("https://hydra.cc/docs/configure_hydra/workdir/")[hydra.cc workdir]。
Snakemake 则把运行元数据统一放在工作目录的 `.snakemake` 里，报告由此生成 #link("https://snakemake.readthedocs.io/en/stable/snakefiles/reporting.html")[snakemake docs]。

*推断*：建议的目录约定（与上述两者同构，但不引入框架）：

```text
runs/
  9f2c1a0b7d34/            # run_id = 输入内容哈希前缀，使同输入重跑幂等
    manifest.json          # 运行溯源，见上文最小字段集
    config.yaml            # 解析后的完整配置（含默认值展开后的结果）
    stdout.log
    stderr.log
    exit_code
    metrics.json           # 供聚合脚本消费的标量指标
    artifacts/             # 大产物/证书/轨迹
  index.jsonl              # 全部运行的追加式汇总索引
```

schema 选型：

#table(columns: 3,
  [载体], [适用], [代价与边界],
  [`JSON` 单文件], [每个 run 一份 `manifest.json`；运行期一次性写入，永不改写], [无法并发追加；写入必须是「先写临时文件再原子 `rename`」，否则中途中断会留下半截文件],
  [`JSON Lines`], [跨 run 的汇总索引：一行一条记录、适合流式追加，官方定位为「一次处理一条记录」与日志格式 #link("https://jsonlines.org/")[jsonlines.org]], [需要容忍末尾不完整行；不适合随机查询],
  [`SQLite`], [需要按参数/指标做条件查询与聚合时], [单文件、无服务端（本机 `python3` 自带 `sqlite3`）。WAL 模式下「读不阻塞写、写不阻塞读」，读写可并发；其原子性只保证到*单个数据库*，不跨多个库成为原子操作 #link("https://sqlite.org/wal.html")[SQLite WAL]],
  [`YAML`], [人工维护的配置文件；不作为机器产物格式], [解析器差异与隐式类型转换（如 `no` 变布尔）会让「同一文件」在不同解析器下含义不同],
)

*推断*：`manifest.json`（真源）+ `index.jsonl`（派生索引）是这台机器上成本最低的组合；SQLite 只在确实需要查询时加，且*不得*成为唯一存储——一旦索引损坏或 schema 演进，历史运行就不可读。

=== 可验证性：让第三方重跑得到同一结论

把结论分成三类，验证标准完全不同：

- *反例类*（找到一个反例/构造）：产物是*见证*，验证者只需在多项式时间内检查它满足否命题。验证成本与搜索成本无关。这类结论的可验证性最强，`out_sha256` 之外无需额外机制。
- *不可满足/上界类*：产物应是*可独立检查的证书*，而非一句断言。SAT 领域的既有做法是 DRAT 证书：`DRAT-trim` 用 DIMACS 公式加 DRAT 子句证明校验不可满足性，其验证基于 RAT（Resolution Asymmetric Tautology）性质与单位传播，且 DRAT「被用于验证 SAT 竞赛的结果」 #link("https://github.com/marijnheule/drat-trim")[drat-trim]。数学侧的同构物是 Lean 的证明项。*推断*：插件应强制「求解器返回 UNSAT」与「证书已通过独立检查器」两条记录分开，未通过检查的只记为 `UNKNOWN`。
- *性能类*（上界改进/实证评测）：没有证书可查，只能靠*重跑统计*。此时必须记录 CPU 时间与 wall clock 两个量、记录 `nproc` 与线程数、并给出重复次数与离散度；单次 wall clock 数字不构成证据。

打包与共享方面，若要把「代码 + 环境声明 + 产物 + 溯源」作为一个可移交单元，RO-Crate 提供了轻量做法：基于 JSON-LD 的元数据描述与打包规范（1.1 版，JSON-LD context 为 `https://w3id.org/ro/crate/1.1/context`） #link("https://www.researchobject.org/ro-crate/specification/1.1/")[RO-Crate 1.1]。
PLOS 规则 10 的要求（公开脚本、运行与结果）在此落实为：把 `runs/` 目录、锁文件与 `manifest.json` 一起发布，而不是只发布最终图表 #link("https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1003285")[PLoS Comput Biol 9(10): e1003285]。

给第三方的重跑合约（*推断*，建议作为插件文档中的硬性承诺）：

1. 一条命令即可重跑：命令与参数原样来自 `manifest.json` 的 `argv` 字段，不含人工补全步骤。
2. 环境可离线重建：锁文件 + 工具链版本足以重建，不依赖网络抓取未钉版本的依赖。
3. 无隐藏输入：运行期不读取锁文件之外的路径；若必须读取，路径与哈希进 manifest。
4. 结论可判定：反例给见证，不可满足给证书，性能给统计量与机器信息；三者互不冒充。
5. 产物可比对：第三方对 `out_sha256` 所列文件重算哈希即可判断是否逐位一致；只在浮点指标上允许容差，且容差须事先声明。

=== 评估

- *抄*：把 Hydra 的 `outputs/<时间或参数>/` 与 `override_dirname` 命名法搬成插件的 `runs/<id>/` 约定，但用*输入内容哈希*而非时间戳做 `run_id`——这样同一实验重跑天然幂等，目录不会分裂，这是 Hydra 默认行为做不到的。
- *抄*：把 Snakemake 的「元数据独立目录 + 一键 report」拆成两件事分别抄——运行元数据统一进 `manifest.json`，再提供一个从 `runs/` 生成汇总表的命令；不要把报告生成嵌进运行期，否则运行失败时连元数据都拿不到。
- *抄*：种子管理直接用 NumPy `SeedSequence.spawn` 与「`[worker_id, root_seed]` 列表传参」，并显式禁止 `root_seed + worker_id` 这种加法派生子种子的写法——它会在换根种子重跑时产生重叠流，正好污染「多随机重跑取极值」这类实验。
- *抄*：确定性开关白名单式强制（`PYTHONHASHSEED=0`、线程数固定、禁用 `-ffast-math`），并把实际值写进 `manifest.json` 的 `env`，让「本次跑是非确定性配置」这件事本身可被查询，而不是依赖研究者自觉。
- *避免*：不要在插件里内嵌 DVC / Snakemake / MLflow / W&B 作为硬依赖。它们分别解决数据版本化、DAG 调度、多运行查询的问题，而这台机器上尚未出现这些需求；先把 Git + 锁文件 + `manifest.json` 做扎实，等真实出现时再按需接入（MLflow 的本地 `mlruns` 是唯一成本可接受的候选）。
- *避免*：不要用容器 digest 作为主要复现手段。它的粒度是操作系统而非算法实验，成本高而收益窄；应把容器限定为「某个缺失系统依赖的求解器的执行壳」，环境记录的主体仍是 `uv.lock`、`Manifest.toml`、`lean-toolchain` + `lake-manifest.json` 这些文本锁文件。

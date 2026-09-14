== 约束规划与组合优化的反例/实例搜索

本节回答六个问题：(a) CP-SAT 的能力与 Python API；(b) MiniZinc 建模语言与后端；(c) 用 CP 找反例的建模套路；(d) 对称性破除、搜索策略与 LNS；(e) 与 SMT 的分工边界；(f) 公共基准如何当回归测试集。文中所有「本机」数据均为 2026-09-14 在该机器上的只读实测（`ldd --version`、`python3 -c`、`pacman -Si` 等），不含任何安装动作。

=== 本机工具链实测基线

#table(columns: 3,
  [项], [实测结果], [对插件的影响],
  [`python3`], [3.14.6（Arch, glibc 2.44）], [只能用 cp314 wheel，不能退回源码编译],
  [`pip`], [`python3 -m pip` 报 No module named pip], [不能写 `pip install`；必须走 `uv` 或 `venv`],
  [`uv`], [0.12.3（/usr/bin/uv）], [`uv venv` + `uv pip install` 是本地首选安装通道],
  [`docker`], [/usr/bin/docker 存在], [MiniZinc 官方镜像可直接跑，无需 root 或 snap],
  [`typst`], [0.15.1], [文档工具链无缺口],
  [`nproc`], [12], [CP-SAT 默认 `num_workers=0` 会自动吃满 12 线程],
  [`pacman`], [`python-ortools` 不在官方仓库（`pacman -Si` 报 not found）], [系统包管理不可用，必须用 venv],
  [未安装], [`ortools` / `minizinc` / `z3` / `cvc5` 均 import/which 失败], [首跑必须先建虚拟环境],
)

=== CP-SAT：能力边界与 Python API

CP-SAT 是 OR-Tools 里面向*整数规划*的求解器，官方明确「所有约束必须用整数定义，非整数项乘以一个大整数转换」，其求解状态为 `OPTIMAL` / `FEASIBLE` / `INFEASIBLE` / `MODEL_INVALID` / `UNKNOWN` #link("https://developers.google.com/optimization/cp/cp_solver")[官方 CP-SAT 文档]。内部是 lazy clause generation：CDCL 学习核心对整数界推理，配 LP 松弛、重启与并行 portfolio #link("https://github.com/d-krupke/cpsat-primer")[CP-SAT Primer]。

安装通道。PyPI 上最新版为 `ortools 9.15.6755`（上传于 2026-01-14），同时提供 cp39 至 cp314 的 manylinux_2_27 / manylinux_2_28 x86_64 wheel #link("https://pypi.org/project/ortools/")[PyPI ortools]；本机 glibc 2.44、Python 3.14.6 与 cp314-manylinux_2_28 wheel 匹配。v9.15 发布说明确认「新增 Python 3.14 支持、最低 Python 升到 3.9」，CP-SAT 侧改进包括 LRAT 证明产出与检查、实验性集合变量、`no_overlap_2d` 的 presolve/传播/割 #link("https://github.com/google/or-tools/releases/latest")[OR-Tools v9.15]。由于本机没有 pip 模块，推荐：

```bash
uv venv .venv-cpsat && . .venv-cpsat/bin/activate
uv pip install 'ortools>=9.15'
python -c "from ortools.sat.python import cp_model; print(cp_model.CpSolver)"
```

*v9.15 的真实坑*：同一份发布说明的 Known issues 列出 `sat: solver.status_name()` 抛 `TypeError: ... object is not callable`（issue #4985）。要打印状态名请改用自建字典，例如 `{0:"UNKNOWN",2:"FEASIBLE",3:"INFEASIBLE",4:"OPTIMAL"}`——这是本机读到的官方记录，不是推测。

最小可用骨架（API 名全部来自官方文档）：

```python
from ortools.sat.python import cp_model

m = cp_model.CpModel()
x = m.new_int_var(0, 2, "x")
y = m.new_int_var(0, 2, "y")
m.add(x != y)
s = cp_model.CpSolver()
s.parameters.max_time_in_seconds = 60
s.parameters.log_search_progress = True
st = s.solve(m)
if st in (cp_model.OPTIMAL, cp_model.FEASIBLE):
    print(s.value(x), s.objective_value, s.best_objective_bound)
```

枚举全部解要继承 `cp_model.CpSolverSolutionCallback` 并设 `solver.parameters.enumerate_all_solutions = True`（官方示例给出 18 个解的输出）。`sat_parameters.proto` 注明：打开该参数时若未显式设置 `keep_all_feasible_solutions_in_presolve`，CP-SAT 会自动把它设为 true，否则 presolve 会删掉大量可行解 #link("https://raw.githubusercontent.com/google/or-tools/stable/ortools/sat/sat_parameters.proto")[sat_parameters.proto]。*对反例搜索的直接含义*：只要目标包含「枚举所有小规模反例」，就必须留神 presolve 的消解，否则统计会偏。

常用的高阶原语及其版本变更（Primer 逐条标注）：

- `model.add_all_different([x, y, z])` 用专用域传播器；但一旦模型里同时出现手写 `!=`，CP-SAT 会停用「从一组 `!=` 反推 all_different」的推断，反而变慢。
- `model.add_element(expressions=arr, index=i, target=v)`：*9.12 起参数由 `variables=` 改名 `expressions=`*。
- `model.add_max_equality(target=..., exprs=[...])`：*9.15 起签名变更*（旧签名见 Primer 的 diff 标注）。
- `model.export_to_file()`：9.15 起按扩展名自动判格式，取代 `model.Proto().SerializeToString()`。
- 回调里可读 `self.objective_value`、`self.best_objective_bound`、`self.num_booleans`、`self.num_branches`、`self.num_conflicts`。
- *CP-SAT 不支持 lazy constraints*（回调里不能加约束），且求解器无状态：增量求解不会复用已学到的子句 #link("https://github.com/d-krupke/cpsat-primer")[Primer 参数章]。这一条是 (e) 分工的核心依据。

=== MiniZinc：建模语言与求解器后端

MiniZinc 是求解器无关的约束建模语言，当前手册版本 2.10.1 #link("https://docs.minizinc.dev/en/stable/index.html")[MiniZinc Handbook 2.10.1]。官方 bundled 安装包自带 Gecode、Chuffed、COIN-OR CBC、HiGHS 与 *OR-Tools CP-SAT*，并预留 Gurobi / CPLEX / SCIP / XPress 接口 #link("https://docs.minizinc.dev/en/stable/installation.html")[安装章]。

本机的三条可行路径（按侵入性排序）：官方 Docker 镜像（本机已有 docker，最干净）

```bash
docker run --rm -v "$PWD:/work" -w /work ghcr.io/minizinc/minizinc model.mzn data.dzn
```

或 snap `snap install minizinc --classic`，或下载 `MiniZincIDE-2.10.1-bundle-linux-x86_64.tgz` 后加 `PATH` / `LD_LIBRARY_PATH` / `QT_PLUGIN_PATH`。镜像 tag 有 `2.10.1 / 2.10 / 2 / latest / edge`，`-dist` 变体用于 `COPY --from` 嵌进自有镜像。

后端选择与调度：`minizinc --solver <id>`，`-p` 开线程，`-f`（free search）允许求解器在用户给定搜索之外混入自身启发式。官方对 Chuffed 与 OR-Tools 都建议加 `-f`，因为二者是 lazy clause generation 求解器，纯固定搜索通常更差 #link("https://docs.minizinc.dev/en/stable/solvers.html")[求解技术章]。

搜索注解（语言内建，非求解器私有）。变量选择 `first_fail` / `dom_w_deg` / `input_order` / `most_constrained` / `occurrence` / `smallest` / `largest` / `impact` / `max_regret`；取值 `indomain_min` / `indomain_max` / `indomain_median` / `indomain_split` / `indomain_random` 等；重启 `restart_luby` / `restart_geometric` / `restart_linear` / `restart_constant`；热启动 `warm_start` 与 `warm_start_array`；组合用 `seq_search`。*同一个注解文件里定义了 LNS 注解* `relax_and_reconstruct(array [int] of var int: x, int: p)`：重启时 `x` 中每个变量以 `p` 百分比概率固定到当前最优解，其余变量回到初始域 #link("https://docs.minizinc.dev/en/stable/lib-stdlib-annotations.html")[标准库注解]。

对称性破除在 MiniZinc 里是*语言级*概念，用谓词而非注解（官方解释：注解会随分解扩散到所有约束，对冗余/对称约束不正确）：

```minizinc
% 语言内建谓词
predicate symmetry_breaking_constraint(var bool: b)
predicate redundant_constraint(var bool: b)
predicate implied_constraint(var bool: b)

% 与之配套的全局约束（均在 share/minizinc/std/ 下有独立源文件）
predicate lex_lesseq(array [$$E] of var $$T: xs, array [$$F] of var $$T: ys)
predicate value_precede_chain(array [$$X] of $$E: order, array [$$Y] of var $$E: xs)
predicate regular(array [$$X] of var $$Val: xs, array [$$State, $$Val] of opt $$State: d, ...)
```

上述签名来自 MiniZinc 标准库源码 `lex_lesseq.mzn` / `value_precede_chain.mzn` / `regular.mzn` #link("https://github.com/MiniZinc/libminizinc/tree/master/share/minizinc/std")[libminizinc std]。

=== 用 CP 做反例搜索的建模套路

*以下范式是我基于上述机制的推断（methodology）；后文标注的机制是实测/一手事实。*

把猜想写成 $C(p, v)$，其中 $p$ 可自由选取（规模、取值域、结构），$v$ 是被断言的性质。「找反例」的建模骨架是：

- 引入布尔 $b_k$ 与「违反指示」整数 $d_k >= 0$，用 `only_enforce_if(b_k)` 把每条猜想的约束条件变成*可开关*的；
- 目标改为最大化加权违反度 $sum_k w_k d_k$；
- 若最优值为 0（且状态为 `OPTIMAL`），则该参数范围内无反例；若最优值大于 0，`solver.value()` 直接给出反例实例；
- 想让「无违反」可证，就把 $sum_k d_k = 0$ 作为约束求解，取 `INFEASIBLE` 才算证毕。

两个使能机制都是实测事实。其一是 `only_enforce_if` + 假设 + 不可满足核：CP-SAT 能在 `INFEASIBLE` 时返回导致冲突的*极小假设子集*，官方示例输出为

```text
Minimal unsat core:
4: 'Indicator 2: x + z <= 2'
5: 'Indicator 3: z >= 4'
```

对应 API 是 `model.add(...).only_enforce_if(ind)`、`model.add_assumptions([...])`、`model.clear_assumptions()` 与 `solver.sufficient_assumptions_for_infeasibility()`。注意官方提醒：并非所有 CP-SAT 约束都支持 reification，越底层的约束越可能支持。其二是枚举能力：`enumerate_all_solutions` 可以逐个吐出小规模反例，但 presolve 会删解，需要 `keep_all_feasible_solutions_in_presolve`（见上）。

这套「反例搜索」不是玩具：SAT/CP 领域已有两次公开的开放问题收割。Schur Number Five 把问题编码成命题逻辑 + 大规模并行 SAT，定出 $n = 160$，并产出 2 PB 的证明、用形式化验证的证明检查器认证 #link("https://arxiv.org/abs/1711.08076")[arXiv:1711.08076]。Boolean Pythagorean Triples 用 cube-and-conquer 在 800 核集群跑约 2 天证明不可能性，DRAT 证明约 200 TB（压缩证书 68 GB） #link("https://arxiv.org/abs/1605.00723")[arXiv:1605.00723]。*对本项目的关键启示*：能收割开放问题的形态不是「跑一个求解器」，而是「编码 + 分裂搜索空间 + 可检查证明」。CP-SAT 9.15 引入 LRAT 证明产出与检查，是把这条路搬进 CP 的直接抓手。

*推断*：反例搜索结果必须先经一个与求解器无关的校验器复核。Primer 的 "Solver-Agnostic Validation" 章正是这个主张：先写不依赖任何求解库的可行性/目标值校验函数，再谈优化。插件应当把「求解器输出」与「独立校验」分成两步，禁止把 `solver.value()` 当作正确答案。

=== 对称性破除、搜索策略与 LNS

对称性。CP-SAT 在 presolve 自动检测对称性，日志形态为 `[Symmetry] #generators: N`、`[Symmetry] Found orbitope of size 6 x 2`、`[Symmetry] 12 orbits with sizes: ...`。该行为由 `symmetry_level` 控制，默认 2；`sat_parameters.proto` 的定义是：1 只在 presolve 检测并固定布尔变量，2 额外在搜索中做动态对称破除，3 还检测超大模型的对称（可能慢），4 在 presolve 尽量破尽 #link("https://raw.githubusercontent.com/google/or-tools/stable/ortools/sat/sat_parameters.proto")[sat_parameters.proto]。另有 `use_symmetry_in_lp`（把同一 orbit 的变量折叠进 LP，默认 false）。

代价要记住：Primer 明确警告 presolve 的对称性破除（禁止同一解的等价变体）会让 `add_hint` 的提示*变成不可行*，官方建议的绕法是 `solver.parameters.keep_all_feasible_solutions_in_presolve = True`，但会拖慢求解——需要实验决定取舍。

搜索策略。CP-SAT 侧 API 为

```python
model.add_decision_strategy([x], cp_model.CHOOSE_FIRST, cp_model.SELECT_MIN_VALUE)
solver.parameters.search_branching = cp_model.FIXED_SEARCH
```

变量选择枚举 `CHOOSE_FIRST` / `CHOOSE_LOWEST_MIN` / `CHOOSE_HIGHEST_MAX` / `CHOOSE_MIN_DOMAIN_SIZE` / `CHOOSE_MAX_DOMAIN_SIZE`，取值枚举 `SELECT_MIN_VALUE` / `SELECT_MAX_VALUE` / `SELECT_LOWER_HALF` / `SELECT_UPPER_HALF` / `SELECT_MEDIAN_VALUE`。但 Primer 作者的实测结论值得抄下来当默认纪律：手工搜索策略只在「差模型」上有优势，用对称性破除改进模型后反而更差；`sat_parameters.proto` 的 `search_branching` 还提供 `PORTFOLIO_SEARCH` / `LP_SEARCH` / `PSEUDO_COST_SEARCH` 等选项。

LNS 是这套工具链里对大搜索空间最有效的手段，而且默认开启。`sat_parameters.proto`：`use_lns` 默认 true、`use_rins_lns` 默认 true、`use_lb_relax_lns` 默认 true，`lns_initial_difficulty` 默认 0.5，`lns_initial_deterministic_limit` 默认 0.1，另有 `use_lns_only` 与 `diversify_lns_params`。CP-SAT 日志会列出子求解器池：

```text
8 incomplete subsolvers: [feasibility_pump, graph_arc_lns, graph_cst_lns, graph_dec_lns,
  graph_var_lns, rins/rens, rnd_cst_lns, rnd_var_lns]
```

LNS 的威力在于每轮*隐式*评估的邻居数：Primer 的背包例子每轮删 5 个、补选 10 个，只相当于 $2^(5+10) = 32768$ 个邻居，但同样的隐式表示可以扩到 $2^(100+900) approx 10^300$。日志里的 `LNS stats` 表给出每个策略的 `Improv/Calls`、`Closed`、`Difficulty`、`TimeLimit`，官方按 round-robin 轮转；Primer 建议的实用策略是「先用收敛快的策略，停滞就随机换一个」，并可用多臂老虎机（UCB1）思想做自适应（ALNS）。MiniZinc 侧的对应物就是 `relax_and_reconstruct`。

=== 与 SMT 的分工边界

*先给一手事实，再给推断边界。*

CP-SAT 的硬限制：整数变量，没有连续变量；不支持增量建模、不复用已学子句；回调里不能加 lazy constraints。原生支持连续变量与增量的场景应交给 MIP 求解器或 SMT #link("https://github.com/d-krupke/cpsat-primer")[Primer: Alternatives 章]。

Z3 侧的算术分工（官方在线指南）：线性实数用对偶单纯形（LRA），线性整数用割平面 + 分支定界（LIA），整数差分逻辑用 Floyd-Warshall（IDL），两变量每不等式用 UTVPI，多项式实数用 model-based CAD 与增量线性化（NRA）；*非线性整数算术是不可判定的*，`check-sat` 可能返回 `unknown` 或不停机 #link("https://microsoft.github.io/z3guide/docs/theories/Arithmetic/")[Z3 Guide: Arithmetic]。SMT 的标准与基准库是 SMT-LIB：2026-03 发布 2.7 参考文档新修订，2026-03 又给整数理论加了幂运算算子并新增 `QF_EIA` 逻辑 #link("https://smt-lib.org/")[SMT-LIB]。这意味着「带幂/非线性的猜想」在 SMT 侧可能不可判定，而在 CP 侧只能通过有限域离散化近似。

桥接层。CPMpy 是唯一同时覆盖 CP / ILP / SMT / PB / SAT / 决策图的 Python 建模库：默认后端是 OR-Tools CP-SAT，另外支持 Z3、MiniZinc+solvers、PySAT、Exact、PySDD、SCIP、HiGHS 等；`SolverLookup.solvernames()` 列出已知求解器，`m.solve(solver="ortools")` 切换，`m.solve(symmetry_level=1, cp_model_probing_level=2)` 直接透传原生参数；`solution_hint()` 与 `get_core()`（unsat core）在 OR-Tools 与 PySAT 接口上可用；`DirectConstraint` 可以把 CP-SAT 的 `AddAutomaton` 等私有约束直接打进去 #link("https://cpmpy.readthedocs.io/en/latest/solvers.html")[CPMpy Solvers]。PyPI 上 CPMpy 最新为 1.0.0（2026-07-18） #link("https://pypi.org/project/cpmpy/")[PyPI cpmpy]。

*推断的分工规则*：判定性优先——猜想涉及整数/组合结构、需要「枚举所有小反例」或需要不可满足核，走 CP（CP-SAT / MiniZinc）；涉及实数、非线性、位向量、数组、量词，或需要增量 push/pop 与长期复用学到的子句，走 SMT。*同时用两条路线编码同一个猜想，是发现编码 bug 的最廉价手段*；CPMpy 让这件事的成本降到「换一个 solver 名字」。

=== 基准集作为回归测试

公共基准在本项目里价值是双重的：既是「算法上界」的实测标尺，也是回归测试的固定输入。可用的硬资产：

#table(columns: 3,
  [基准], [关键事实], [用途],
  [SAT Competition], [2024 有 Main/Parallel/Cloud 三赛道，基准打包在 Zenodo 并在 benchmark-database.de 提供标注版；2025 有 Main/Parallel 两赛道，首次跑在慕尼黑 SoSy Lab 的 BenchCloud 上，2025-08-25 放出基准与求解器源码], [SAT 编码回归 + 难度分层],
  [Global Benchmark Database], [CNF/meta 全量导出含 family、作者、license、是否 UNSAT 与所属赛道标签], [按 family 分组的回归子集抽样],
  [MIPLIB 2017], [Benchmark Set 240 个实例 + 更大的 Collection Set；类别分 easy/hard/open；持续发布 solufile 修正最优值（35 于 2025-03-07，36 于 2026-01-26）], [MIP 侧上界/最优值对照],
  [TSPLIB 与 Waterloo 扩展], [Reinelt 1990 收集，超过 100 个实例，14 到 85,900 城市；Waterloo 另有 National TSP（27 例）、VLSI（102 例，最大 744,710）、World TSP（1,904,711）、Mona Lisa（100,000）], [算法上界改进的实测标尺],
  [DIMACS Implementation Challenges], [第 2 届（1992-93）覆盖 Max Clique/着色/SAT，第 8 届（2001）TSP，第 12 届（2020-22）VRP，第 13 届（2026-2027）Network Flows 2.0], [实例生成器与标准化的历史来源],
)

来源：#link("https://satcompetition.github.io/2024/")[SAT Competition 2024]、#link("https://satcompetition.github.io/2025/")[SAT Competition 2025]、#link("https://benchmark-database.de/")[benchmark-database.de]、#link("https://miplib.zib.de/")[MIPLIB 2017]、#link("https://www.math.uwaterloo.ca/tsp/data/index.html")[Waterloo TSP Data]、#link("https://dimacs.rutgers.edu/programs/challenge/")[DIMACS Challenges]。

求解器回归还需要「谁在基准上赢」。MiniZinc Challenge 自 2008 年每年举办，2026 年 Fixed/Free/Parallel/Open 四个类别的金牌全部是 OR-Tools CP-SAT，Local Search 金牌为 QiuQi-MIXSolver、银牌为 OR-Tools CP-SAT LS #link("https://www.minizinc.org/challenge/")[MiniZinc Challenge]。也就是说：*在 MiniZinc 建模层上，CP-SAT 是当前公开基准上的默认强基线*，任何自研算法的上界改进都要与它对比。

回归测试的执行纪律（Primer 的 Benchmarking 章，均可直接搬）：

- `random_seed` 在 `sat_parameters.proto` 里默认 1，其注释本身就写明「不同种子跑一遍能得到更稳健的基准」，因为求解时间对算法微小变化极敏感。CI 里应固定种子，另设一个多种子矩阵。
- 时间上限必须设（`max_time_in_seconds`），但*不能把超时实例直接丢弃*：No-Free-Lunch 意味着改进一批实例会退化另一批；丢弃超时实例等于只评估简单实例。应使用包含 unknown 结果的指标（如 PAR-2、cactus plot、success-based benchmarking）。
- *不要把「在少数实例上无收益」的搜索策略或 presolve 关掉*：现代求解器的某些特性只对难实例生效，关掉它可能让整类问题不可解。
- 实例要*落盘成文件*，不要只存伪随机种子；同时把「实例 + 期望状态 + 期望最优值/上界」三者一起进仓库，作为回归断言。
- 模型构建代码本身可能是瓶颈（$O(n^5)$ 的 Python 建模范式），用 `log_search_progress` 先确认时间花在哪一侧，再用 profiler。

=== 评估

- *抄*：把 CP-SAT 当作「整数组合搜索的默认引擎」，并把 `uv venv` + `uv pip install 'ortools>=9.15'` 固化成插件的环境引导脚本（本机无 pip 模块，且不存在系统包）。绑定 cp314 manylinux_2_28 wheel 这一已验证组合，别让插件走源码编译路径。
- *抄*：反例搜索一律建成「可开关约束 + 违反度目标 + `only_enforce_if`/`add_assumptions` + `sufficient_assumptions_for_infeasibility()` 取核」的四件套，并把 `enumerate_all_solutions` + `keep_all_feasible_solutions_in_presolve` 作为小规模穷举反例的标准配置。
- *抄*：把 MiniZinc 走 Docker 镜像接入（`docker run --rm -v "$PWD:/work" ghcr.io/minizinc/minizinc`），用它拿到「一个模型、多后端」的横向对照能力；`symmetry_breaking_constraint` / `lex_lesseq` / `value_precede_chain` 与 `relax_and_reconstruct` 直接写进建模模板库。
- *避免*：不要手写 `add_decision_strategy` 或改 `search_branching` 作为默认优化手段——Primer 的实测是改模型（含对称性破除）后手工策略反而更差；也不要为省事关掉 LNS（`use_lns` / `use_rins_lns` 默认 true）或 presolve。
- *避免*：不要把 `add_hint` 当作稳定 warm-start——presolve 的对称性破除会让提示不可行；若要用必须配 `fix_variables_to_their_hinted_value = True` 做可行性自检，并评估 `keep_all_feasible_solutions_in_presolve` 的性能代价。
- *避免*：不要只报「求解器给出了解」。用独立于求解器库的校验函数复核每个候选反例/上界，并以 SAT Competition / MIPLIB / TSPLIB 的固定子集 + 固定种子 + 时间上限做 CI 回归；跨 CP 与 SMT 各编码一遍同一猜想，用不一致来暴露编码错误（CPMpy 使这一步只需换 solver 名）。

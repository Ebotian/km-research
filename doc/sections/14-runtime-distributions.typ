== 算法运行时间分布与实证算法学

本节回答六个问题：重尾运行时间为何让「平均运行时间」失去意义；超时样本作为删失数据应如何统计；性能剖面（performance profile）及报告规范；可重现的检验与多重比较校正；基准测试的六类陷阱；这些结论对插件「实验记录 schema」的直接约束。文中把「一手事实」（附 URL）与「本项目推断」显式区分；「本机实测」指在当前这台机器上只读验证过的环境事实。

=== 重尾运行时间分布：为什么均值无意义

- *定义（一手）*：Gomes、Selman、Kautz 对随机化回溯搜索给出的重尾代价分布刻画是——「实验进行到任何时刻，都仍有不可忽略的概率遇到一个需要比此前见过的任何实例多指数级时间的实例」。#link("https://www.cs.cornell.edu/selman/papers/pdf/98.aaai.boost.pdf")[AAAI-98, Boosting Combinatorial Search Through Randomization]
- *分布形式（一手，同上）*：尾部渐近服从 Lévy–Pareto 律 $Pr[X > x] prop x^(-alpha)$，$alpha$ 称为*稳定性指数*（index of stability）；阶小于 $alpha$ 的矩有限，更高阶矩全部无限。
  - 因此 $alpha <= 2$ 时方差不存在；$alpha <= 1$ 时连均值都不存在。原文对 round-robin 调度实例用极大似然估计得到的 $alpha$ 正落在「均值与方差都无限」的区间。
  - 判据（一手，同上）：$(1 - F(x))$ 的 log-log 图近似为直线，斜率即 $alpha$ 的估计；标准分布（指数衰减族）在该图上会明显下弯。
- *均值不收敛（一手，同上原文）*：「这种重尾现象使得平均求解时间随实验时长增长，并在极限意义下为无限」。样本均值由最大几个观测主导，因此「均值 ± 标准差」在跨实例、跨预算时不可迁移。
- *右侧尾与左侧尾同时存在（一手，同上）*：作者在 round-robin 调度上观测到「若干次运行少于 200 次回溯，而中位数约为 2,000,000 次」。
  - 左尾（远低于中位数的快跑）是重启策略的收益来源；右尾是灾难性长跑的来源，两者是同一个重尾分布的两侧。
- *重尾是「实例×算法×随机种子」的性质，不是实例的性质（一手，同上）*：同一实例换随机种子重跑会出现同样的重尾分布；原文明确「困难不在实例里，而在实例与确定性算法的具体细节的组合中」。
  - *本项目推断*：这条直接要求每条实验记录绑定随机种子；单次运行的耗时不能代表该实例。
- *可操作推论（推断，基于上述矩性质）*：汇总统计量应是中位数、分位数、以及「预算 $T$ 内求解成功的比例」$1 - S(T)$；均值只有在固定截断与固定实例集下才可比较。
- *理论出处与后续*：CP'97 原始版本 #link("https://doi.org/10.1007/bfb0017434")[Heavy-tailed distributions in combinatorial search, LNCS 1997]；期刊版 #link("https://doi.org/10.1023/a:1006314320276")[J. Automated Reasoning 24 (2000)]；算法运行时间预测综述 #link("https://doi.org/10.1016/j.artint.2013.10.003")[Hutter et al., AIJ 2014]。
- *工程含义（一手，AAAI-98）*：加入受控随机化并配合「以中位数附近为截断的重启」，可证明地消掉中位数右侧的重尾，并从左侧快跑中获益，实测加速达数个数量级。这是现代 CDCL 求解器普遍带重启/随机化的理论来源。

=== 超时样本：删失数据与 Kaplan–Meier

- *语义（推断，但为下文工具与格式所支持）*：超时记录不是「运行时间 = 时限」的观测，而是*右删失*观测——只知道 $T > c$，$c$ 为截断值。把 $c$ 当观测值填进样本会系统性压低尾部，并把分布压成一个人造质点。
- *ASlib 的实际编码（一手）*：算法运行文件 `algorithm_runs.arff` 的字段为 `instance_id`, `repetition`, `algorithm`, `runtime`, `runstatus`；`runstatus` 是受控词表 `ok, timeout, memout, not_applicable, crash, other`。求解成功率与 PAR10 是并列的官方评价指标。#link("https://raw.githubusercontent.com/coseal/aslib_data/master/SAT11-HAND/algorithm_runs.arff")[aslib_data / algorithm_runs.arff]、#link("https://arxiv.org/abs/1506.02465")[ASlib, AIJ 2016]
- *PAR10 的定义（一手，ASlib 原文）*：penalized average runtime, penalty factor 10，即「一次超时按 10 倍时限计」。
  - *本项目推断*：惩罚分是为让不同求解器可比而人为引入的记分规则，不是观测量；惩罚因子会直接改变排名，必须与截断值一起记录才能复算。
- *Kaplan–Meier 才是删失数据的正确汇总（一手）*：定义 $S(t) = Pr[T > t]$；超时样本在删失时刻之前一直留在风险集（at-risk set）内，但不计为事件，于是 $1 - S(T)$ 即「预算 $T$ 内的求解成功率」。原始文献 #link("https://doi.org/10.1080/01621459.1958.10501452")[Kaplan & Meier, JASA 1958]。
- *Python 侧（一手，lifelines 0.30.3 文档）*：`KaplanMeierFitter(alpha=0.05, label=None)`，`fit(durations, event_observed=None, ...)` 中 `event_observed=False` 表示右删失；可读 `survival_function_`、`median_survival_time_`、`confidence_interval_`，或用 `survival_function_at_times(times)` 取特定时刻值；`plot(show_censors=True, at_risk_counts=True)` 会标出删失点与风险集大小。区间删失用 `fit_interval_censoring(lower_bound, upper_bound)`（Turnbull 估计），左删失用 `fit_left_censoring`。#link("https://lifelines.readthedocs.io/en/latest/fitters/univariate/KaplanMeierFitter.html")[lifelines: KaplanMeierFitter]
- *组间比较（一手，lifelines）*：`logrank_test(durations_A, durations_B, event_observed_A, event_observed_B, t_0=-1, weightings=None)`。文档给出两条明确警告：
  - 该实现*只支持右删失*；
  - 当生存曲线交叉时 log-rank 会给出不准确的评估，此情形建议改用 Cox 回归。
  - 多样本用 `multivariate_logrank_test` / `pairwise_logrank_test`；`t_0` 可把晚于该时刻的事件统一降级为删失。只在固定预算点比较时用 `survival_difference_at_fixed_point_in_time_test(point_in_time, fitterA, fitterB)`，它用 $log(-log(t))$ 变换恢复检验效能。另有 `proportional_hazard_test`、`sample_size_necessary_under_cph`。#link("https://lifelines.readthedocs.io/en/latest/lifelines.statistics.html")[lifelines.statistics]
- *R 侧（本机实测：R 4.6.1，`survival` 3.8.6 已安装，`Rscript` 在 `/usr/bin/Rscript`）*：以下签名由本机 `args()` 直接读出——
  - `Surv(time, time2, event, type=c("right","left","interval","counting","interval2"), origin=0)`；
  - `survfit(formula, data, ..., stype=1, ctype=1, id, cluster, robust, istate, timefix=TRUE, etype)`；
  - `survdiff(formula, data, subset, na.action, rho=0, timefix=TRUE)`，其中 `rho=0` 即 log-rank，`rho=1` 为 Peto–Peto 型加权；
  - `coxph(formula, data, ..., ties=c("efron","breslow","exact"))`。
- *生存分析用于算法的系统出处*：#link("https://doi.org/10.1287/ijoc.12.1.24.11899")[Coffin & Saltzman, INFORMS JoC 2000]（计算实验数据的统计处理专文）；#link("https://doi.org/10.1007/978-3-642-02538-9_7")[Gagliolo & Legrand, "Algorithm Survival Analysis", 2010]；#link("https://doi.org/10.1613/jair.2490")[SATzilla, JAIR 2008] 与 #link("https://doi.org/10.1016/j.artint.2013.10.003")[AIJ 2014] 都把带截断的运行时间作为删失数据建模。
- *删失报告的清单（推断）*：给出截断值 $c$、每组的删失计数与风险集曲线、以及 $1 - S(T)$ 的置信区间；只报「平均时间」而不报删失计数，等价于隐藏了尾部。

=== 性能剖面与报告规范

- *定义（一手，Dolan & Moré 2002）*：对每个实例取参加比较的求解器中的最快时间 $m_p$ 为基准，曲线 $rho_s(tau)$ 表示「求解器 $s$ 在 $tau$ 倍基准时间内完成的实例比例」；$tau = 1$ 处的值即该求解器的「胜出比例」。#link("https://doi.org/10.1007/s101070100263")[Benchmarking optimization software with performance profiles, Math. Prog. 91 (2002)]
- *实现与工具（一手）*：Julia 的 `BenchmarkProfiles`（Dolan、Moré、Wild 原始脚本的翻译，经作者书面同意发布）接受「行=问题、列=求解器」的矩阵，如 `T = 10 * rand(25, 3)` 后调用 `performance_profile(PlotsBackend(), T, ["Solver 1", ...], title=..., logscale=...)`；预算型的数据剖面见 `data_profile_plot`，其来源是 #link("https://doi.org/10.1137/080724083")[Moré & Wild, SIAM J. Optim. 20(1), 2009]。#link("https://jso.dev/BenchmarkProfiles.jl/stable/")[BenchmarkProfiles.jl 文档]
- *官方警告（一手）*：该文档页显著位置写着 “Watch out for the pitfalls of profiles!”，直接指向 #link("https://doi.org/10.1145/2950048")[Gould & Scott, ACM TOMS 2016]。
- *陷阱的原文表述（一手）*：Gould & Scott 摘要说，他们用真实应用数据与一个简单人工例子说明「在试图用性能剖面评估求解器相对表现时应当谨慎」。
  - *本项目推断*：剖面把信息压成一条相对曲线，丢掉绝对代价、求解数量与失败数量的信息；基准 $m_p$ 由参评集合决定，增删一个求解器会改变所有曲线。
- *报告规范（推断，综合上述来源与 #link("https://arxiv.org/abs/2007.03488")[Bartz-Beielstein et al., "Benchmarking in Optimization" 综述] 的八个议题：目标、问题、算法、性能度量、分析、设计、呈现、可复现）*：
  - 曲线之外必须给表：每实例的原始代价或分位数、各求解器在 $tau = 1$ 的胜出数、超时/崩溃计数；
  - 明确写出实例集合、「基准 $m_p$ = 该实例上最快者」的定义、以及未解实例被赋予的惩罚值（PAR10 或 PAR2）；
  - 剖面本身不带置信区间，需与自助法区间或生存曲线并排报告；
  - 记录剖面所依赖的截断值：超过惩罚值的区间内，所有曲线的形状由惩罚规则而非测量结果决定。
- *与之互补的记分惯例（一手）*：ASlib 的 PAR10 与 SAT 竞赛的 PAR-2 同属「惩罚平均运行时间」家族。SAT Competition 2025 首次迁到慕尼黑 SoSy Lab 的 BenchCloud 上运行，官方公告明说这「带来了提交与资源限制的变化」——评分与资源限制是竞赛平台的属性，不是算法的属性。#link("https://satcompetition.github.io/2025/")[SAT Competition 2025]、#link("https://satcompetition.github.io/2025/rules.html")[rules]

=== 可重现的统计检验与多重比较

- *配对非参数检验（一手，SciPy 1.18 文档）*：`wilcoxon(x, y=None, zero_method='wilcox', correction=False, alternative='two-sided', method='auto')`。
  - `method='auto'` 在样本量不超过 50 时用精确分布，否则用渐近正态；存在并列值（ties）或零差值时精确分布失效，此时可传 `PermutationMethod` 做置换检验。
  - 文档提示：同时传 `x` 与 `y` 时，浮点舍入会让本应相等的差值获得不同秩；应先算差值、按需取整，再作为单样本传入。#link("https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.wilcoxon.html")[scipy.stats.wilcoxon]
- *自助法（一手，SciPy 1.18 文档）*：`bootstrap(data, statistic, n_resamples=9999, paired=False, confidence_level=0.95, method='BCa', rng=..., bootstrap_result=None)`。
  - `paired=True` 时对索引重采样以保持配对；`method` 取 `'percentile'`、`'basic'`、`'bca'`，默认 `'BCa'`；返回 `.confidence_interval`、`.bootstrap_distribution`、`.standard_error`。
  - 随机性由 `rng` 控制；文档说明新代码只应使用 `rng`（`random_state` 在 SPEC-007 迁移中已被替换）。#link("https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.bootstrap.html")[scipy.stats.bootstrap]
- *重采样单位（推断）*：算法比较的独立单位是*实例*，不是同一实例上的重复运行；对「每实例聚合后的代价」做配对自助或配对秩检验才与实验设计一致。据此，同一实例上「只跑一次」不构成重复，必须先把 $k$ 次运行聚合成一个每实例统计量。
- *不确定度必须进结论（一手）*：Kalibera & Jones 报告，在其调查的 122 篇近期论文中有 65 篇用执行时间比值量化性能变化，而多数完全不谈均值本身的不确定度，也没有一篇处理非确定性编译；他们示范的形式是「system A 比 system B 快 $5.5% +- 2.5%$（95% 置信）」。#link("https://arxiv.org/abs/2007.10899")[Quantifying Performance Changes with Effect Size Confidence Intervals]
- *多总体比较与临界差异图（一手）*：Demšar 的结论是——两两比较用 Wilcoxon signed-ranks，多算法多数据集用 Friedman 检验加相应 post-hoc，并用 CD（critical difference）图呈现。#link("https://jmlr.org/papers/v7/demsar06a.html")[JMLR 7 (2006) 1–30]
- *自动化的正确流程（一手，Autorank 1.3.0 README；PyPI 版本 1.3.0 已核对）*：
  - 先对每个总体做 Shapiro–Wilk 正态性检验，显著性水平按 Bonferroni 校正为「$alpha$ 除以总体个数」；正态时用 Bartlett 检验方差齐性，否则用 Levene；
  - 两总体且正态 → 配对 t 检验，否则 → Wilcoxon signed-rank；多于两个总体且全部正态同方差 → 重复测量 ANOVA + Tukey HSD，否则 → Friedman + Nemenyi；
  - 非正态时用中位数与 MAD 汇总，效应量用 Akinshin's gamma 而非 Cohen's d；
  - 结果对象含 `pvalue`、`cd`、`omnibus`、`posthoc`、`alpha_normality` 等字段，报告由 `create_report(result)`、图由 `plot_stats(result)`、LaTeX 表由 `latex_table(result)` 生成；`autorank(data, alpha=0.05, approach='bayesian')` 切到贝叶斯流程。#link("https://github.com/sherbold/autorank")[Autorank]
- *贝叶斯替代（一手）*：Benavoli 等人主张放弃零假设显著性检验，改用贝叶斯分析——直接给出「中心趋势更小/相等/更大」的概率，并用 ROPE（Region of Practical Equivalence，实际等价区间）表达「差异小到无实际意义」。#link("https://arxiv.org/abs/1606.04316")[JMLR 18(77), 2017]
  - 实现为 `baycomp` 1.0.3（PyPI 摘要：「Bayesian tests for comparison of classifiers」），Autorank 的贝叶斯流程即基于它；其 ROPE 默认取 $0.1 dot "STD"$（正态）或 $0.1 dot "MAD"$（非正态），依据是 Kruschke & Liddell 2018 的「取小效应的一半」原则（一手，Autorank README）。
- *多重比较校正（一手，statsmodels 0.15）*：`multipletests(pvals, alpha=0.05, method='hs', maxiter=1, is_sorted=False)`，可选方法含 `bonferroni`、`sidak`、`holm-sidak`、`holm`、`simes-hochberg`、`hommel`、`fdr_bh`、`fdr_by`、`fdr_tsbh`、`fdr_tsbky`、`fdr_gbs`、`lfdr`；返回 `reject`、`pvals_corrected`、`alphacSidak`、`alphacBonf`。文档注明除两阶段 FDR 外，校正后的 p 值与 $alpha$ 无关，故可与别的 $alpha$ 比较。#link("https://www.statsmodels.org/stable/generated/statsmodels.stats.multitest.multipletests.html")[statsmodels multipletests]
- *可重现性的三个落点（推断，基于上述文档约束）*：固定自助/置换检验的种子（`rng`）；记录统计脚本与依赖版本；让「原始运行记录 → 汇总 → 检验 → 图」全链路可由脚本重跑，而不是把 p 值手工抄进结论。
- *常见误用（推断）*：把 PAR10 折算值与真实耗时混在一个 Wilcoxon 检验里；对同一批实例反复挑选「能出显著性」的子集；只报 p 值不报效应量；对 $k$ 个算法做完全部两两比较而不校正。

=== 基准测试的六类陷阱

- *实例选择偏差（一手）*：SAT Competition 2025 规则要求每个参赛队提交 20 个从未在往届出现过的新实例，其中至少 10 个要是「有趣」的——不能太容易（被 MiniSat 一分钟内解出），也不能太难（参赛者自己的求解器一小时也解不出）。#link("https://satcompetition.github.io/2025/rules.html")[SAT Competition 2025 rules]
  - MIPLIB 2017 用数据驱动的选择流程（在多样性与均衡性约束下解一串混合整数规划），从 5721 个候选中筛出 1065 个，其中 240 个专供基准测试。#link("https://doi.org/10.1007/s12532-020-00194-3")[MIPLIB 2017, Math. Prog. Comp.]
  - 即基准实例集是被*构造*出来的，不是随机抽样的；更早的批判见 #link("https://doi.org/10.1007/bfb02430364")[Hooker, "Testing heuristics: We have it all wrong", 1995]。
- *硬件漂移与测量偏差（一手）*：pyperf 的系统调优文档逐条列出干扰源与对策——
  - CPU 隔离（内核参数 `isolcpus`）、CPU 亲和（`taskset -c`、`os.sched_setaffinity`、CLI `--affinity`）、NUMA 拓扑、HyperThreading、Turbo Boost、P-state/C-state、ASLR、`nohz_full`；
  - 可检查的运行元数据：`cpu_affinity`、`runnable_threads`（取自 `/proc/loadavg` 第 4 字段），以及用 `/proc/PID/status` 的 `voluntary_ctxt_switches`/`nonvoluntary_ctxt_switches` 判断是否被抢占。#link("https://pyperf.readthedocs.io/en/latest/system.html")[pyperf: Tune the system for benchmarks]
  - 另一路证据是 #link("https://doi.org/10.1145/1508244.1508275")[Mytkowicz et al., ASPLOS 2009]，标题即结论：不做任何明显的错事也能产出错误数据。
  - *本机实测*：CPU 为 AMD Ryzen 5 9600X（6 核 12 线程）；`scaling_governor` 为 `powersave`；`/sys/devices/system/cpu/isolated` 为空；`randomize_va_space=2`；无 `intel_pstate`；`taskset`/`numactl` 可用，`hyperfine`/`perf`/`cpupower` 未安装。
- *JIT 预热与冷启动（一手）*：JMH 的 `@Warmup` 注解含 `iterations`、`time`、`timeUnit`（默认 `SECONDS`）、`batchSize`，四者默认值均为 `-1`（交由运行期选项决定），可标注在方法或类上并被运行期选项覆盖；JMH README 写着「不要以为有了好用的框架就能自动避开基准陷阱，我们只承诺让避开它们更容易」。#link("https://javadoc.io/static/org.openjdk.jmh/jmh-core/1.37/org/openjdk/jmh/annotations/Warmup.html")[JMH \@Warmup]、#link("https://github.com/openjdk/jmh")[JMH README]
  - Julia 侧的对应风险是编译器把被测计算外提：BenchmarkTools 的 `@benchmark`/`@btime` 支持 `setup=` 与 `$` 插值以避免全局变量，文档提示「若报出亚纳秒级结果，多半是被外提了」。#link("https://juliaci.github.io/BenchmarkTools.jl/stable/")[BenchmarkTools.jl]（本机实测：Julia 可用，但未安装 BenchmarkTools）
  - JVM 侧的系统性讨论见 #link("https://doi.org/10.1145/1297027.1297033")[Georges et al., OOPSLA 2007]。
- *噪声与非确定性执行（一手）*：pyperf 会自动把基准校准到给定时间预算、用多工作进程运行，并提供 `pyperf check`（检测结果是否不稳定）、`pyperf stats`（看分布）、`pyperf compare_to`（做显著性比较），同时自动采集机器元数据。#link("https://pyperf.readthedocs.io/en/latest/")[pyperf 2.10.0 文档]
  - 方法学上给出「严谨但时间可承受」路线的是 #link("https://doi.org/10.1145/2464157.2464160")[Kalibera & Jones, ISMM 2013]；非确定性内存布局与非确定性编译都是必须列入实验设计的不确定度来源（同 #link("https://arxiv.org/abs/2007.10899")[arXiv:2007.10899]）。
- *评分规则的任意性（推断）*：把未解实例按 PAR10（10 倍时限）或 PAR2 折算，本质是给分布尾部安一个可调常数；同一批原始数据换个惩罚因子就会改变排名。因此「谁更快」的结论必须连同截断值、惩罚因子、实例集一起陈述。
- *分析层的过拟合（推断，工具来自上一节）*：$k$ 个算法的全部两两组合会产生 $k(k-1) slash 2$ 次检验，不校正即是 p-hacking；在基准集上反复调参再汇报同一条曲线，等价于把测试集当训练集。Autorank 把校正流程固化成一次调用，正是为了减少这类自由度。

=== 对「实验记录 schema」的直接要求

字段命名与受控词表借鉴 ASlib 的 `algorithm_runs.arff`（`instance_id` / `repetition` / `algorithm` / `runtime` / `runstatus`，词表 `ok, timeout, memout, not_applicable, crash, other`），其余为本项目推断的设计。建议以 JSON Lines 追加写，一行一次运行；下例只示字段形状与嵌套层次，各字段值并非真实实验数据：

```json
{"schema_version":"1.0","record_id":"2026-09-14T10:00:00Z/cadical/i17/r3",
 "scenario":{"name":"sat-main-2025","performance_measure":"cpu_time_s",
             "instance_split":"train"},
 "instance":{"id":"roundrobin_12","sha256":"...","family":"crafted",
             "features_sha256":"..."},
 "algorithm":{"name":"cadical","version":"2.1.3","commit":"...",
              "config_id":"...","seed":12345},
 "limits":{"cutoff_s":5000,"resource":"cpu_time","mem_mb":32000},
 "measure":{"value":4800.12,"event_observed":false,"runstatus":"timeout",
            "penalty_factor":10},
 "protocol":{"process":"fresh","warmup_runs":2,"repetition":3,
             "affinity":"0-5","wall_s":5012.7},
 "host":{"cpu":"AMD Ryzen 5 9600X","n_cores":12,"governor":"powersave",
         "isolated_cpus":"","kernel":"...","aslr":2,"container":null},
 "build":{"compiler":"gcc","compiler_version":"...",
          "flags":"-O3 -march=native","jit":null,"libs":{}},
 "harness":{"name":"kimi-bench","version":"0.1.0","script_sha256":"..."},
 "analysis":{"test":"kaplan_meier+logrank","rng_seed":7,
             "correction":"holm","code_sha256":"..."}}
```

由此推出的硬性要求：

#table(columns: (2fr, 3fr), stroke: none,
  [*字段 / 机制*], [*理由（对应上文来源）*],
  [`runtime` 与 `runstatus` 分离], [超时是右删失，而非「时间 = 时限」的观测；ASlib 用受控词表区分 ok / timeout / memout / crash],
  [必存 `cutoff_s` 与 `penalty_factor`], [PAR10 / PAR2 由二者复算；缺一则历史数据无法重算],
  [必存 `event_observed` 或等价删失标记], [KM 曲线与 log-rank 检验的输入；lifelines 与 R survival 都以它为一等输入],
  [逐次运行一行、保留 `repetition`、附每次运行的 `seed`], [重尾是「实例×算法×种子」的组合性质；聚合值可由原始行重算，反向不可行],
  [`resource` 区分 CPU 时间与墙上时间], [两者不可混入同一分布；竞赛平台换机即改资源限制，混型分布没有统计意义],
  [记录硬件指纹：CPU 型号/核数、亲和与隔离、governor、turbo、VM 或容器], [pyperf 把 `cpu_affinity`、`runnable_threads` 写进元数据；本机 `powersave` governor 即是一例已知噪声源],
  [记录 `process`（fresh 或 in-process）与 `warmup_runs`；JIT 场景另记 `jit` 与解释器版本], [JMH `@Warmup`、BenchmarkTools 的外提风险、pyperf 的校准是同一问题的不同形态],
  [记录编译与运行环境：flags、库版本、环境变量与块大小], [Kalibera & Jones：非确定性编译与内存布局本身即为不确定度来源],
  [分析层字段 `test` / `rng_seed` / `correction` / `code_sha256`], [自助法必须固定 `rng`；校正方法与脚本哈希决定结果能否复现],
  [保存 `scenario` 级元信息与固定划分（train / test、CV fold）], [ASlib 的 meta 文件含性能度量、算法集与资源限制；划分文件是免于「同一批数据反复挑选」的前提],
  [带 `schema_version` 并用 JSON Schema 校验、`runstatus` 用受控词表], [字段漂移会静默破坏历史记录的可用性；受控词表使「未解」的语义唯一])

*本项目推断*：落到插件形态上，`mcpServers` 暴露三类工具即可——`record_run`（校验并追加一行 JSONL）、`summarize`（由原始行重算中位数、分位数、$1 - S(T)$、PAR10，并给出删失计数）、`compare`（配对自助或 Friedman + Nemenyi，附固定种子的校正后结果）。三类工具的返回体都应带「基于多少次运行、多少次删失、截断值多少」的元数据，避免下游把均值当结论；元数据不一致（governor、CPU、截断值不同）时应拒绝合并成同一张剖面。

*本机实测的环境约束*：`scipy`、`statsmodels`、`lifelines` 均未安装（Python 只有 numpy 2.5.2）；R 4.6.1 带 `survival` 3.8.6 与 `boot`，`Rscript` 可用；Julia 可用但无 BenchmarkTools。因此生存分析走 `Rscript` 是最短路径；若要零依赖，Kaplan–Meier 与 log-rank 都是几十行可实现的公式，不必为此引入新依赖。

=== 评估

- *该抄*：照搬 ASlib 的 `algorithm_runs` 记录形状与 `runstatus` 受控词表，但必须补 `event_observed` 与 `cutoff_s`——ASlib 面向离线算法选择，把「谁解出来了」与「用了多久」拆成不同文件，而本插件要做的删失统计需要同一条记录里同时拿到这两项。
- *该抄*：把「预算 $T$ 内成功率 $1 - S(T)$」与分位数设为一等汇报指标，并在 MCP 工具返回体里强制带 `n_runs` / `n_censored` / `cutoff_s`。这比直接禁止报均值更有效：均值在固定截断与固定实例集下仍可比较，只是不可跨设置迁移。
- *该抄*：把 Autorank 的固定决策树（校正后正态性 → Bartlett/Levene → 配对 t 或 Wilcoxon signed-rank → rmANOVA + Tukey 或 Friedman + Nemenyi）固化为插件 `compare` 工具的默认路径，校正方法与种子写入记录的 `analysis` 字段；不向用户暴露「自己挑一个检验」的开关。
- *该避免*：不要把「取平均」或「取最好一次」作为默认性能值。重尾分布的样本均值不收敛且由尾部单点主导；同理，`@btime` 式的「最短时间」是左尾样本，能说明重尾存在，但不能说明右尾风险消失。
- *该避免*：不要用 PAR10 折算替代删失建模去做显著性检验。PAR10 是记分惯例（惩罚因子乘截断），会给分布强加一个人造质点；检验应回到 `(runtime, event_observed, cutoff_s)` 三元组，用 log-rank / Cox 或按实例配对的分位数比较，PAR10 只作为并列的报告口径。
- *该避免*：不要在单机上直接比较不同时间、不同 governor/turbo 状态的运行。本机 `powersave` governor、无可隔离 CPU、无 `hyperfine/perf/cpupower`，意味着插件必须自己用 `taskset`/`numactl` 固定亲和并记录 `cpu_affinity` 与 governor；跨硬件比较只允许走「固定截断下的成功率」这类较稳健的口径，且必须在元数据不一致时拒绝合并。

== 计算机代数系统与精确算术

本节回答：本机该部署哪条 CAS 路线、各类 CAS 的能力边界在哪、哪些操作能直接用于攻击猜想，以及 CAS 结果距离 Lean 证明究竟有多远。所有版本号与体积数字均取自本机只读命令或官方文档；
推断部分显式标注。

=== 本机实测基线

下列数据由 `command -v`、`pacman -Si`、`--version` 等只读命令得到（Arch Linux，12 核）：

#table(
  columns: 2,
  [*项目*], [*实测结果*],
  [CAS 可执行文件], [`sage` / `gp` / `gap` / `singular` 全部未安装；`z3`、`cvc5` 亦未安装],
  [Python], [`python3` 可用；*无 `pip` 模块*（`No module named pip`）、*无 `sympy`*；有 `numpy 2.5.2`],
  [Julia], [`1.12.6`；`~/.julia` 已有 92 个包、628 MB，但 *不含* Nemo / Hecke / Oscar / AbstractAlgebra],
  [Lean], [`elan` 的 default 是 `stable`，已装工具链为 `leanprover/lean4:v4.32.2`、`v4.33.0-rc1`、`v4.33.1`（`lean`
    shim 首次调用时按 default 自动补齐了 `v4.33.1`）；`~/.cache/mathlib` 已缓存 438 MB mathlib 构建产物],
  [文档工具链], [`typst 0.15.1`、`pdflatex`、`pandoc`、`git` 均可用；`cargo` 未安装],
  [`pacman -S sagemath` 的真实代价], [依赖闭包 *360 个包*、安装后合计 *约 2.56 GiB*（本机 `pacman -Si` 递归求和；脚本未解析 `Provides`
形式的依赖，实际只多不少）],
)

若干直接可用的单包体积（Arch `extra`，安装后大小）：`gap 4.16.1` 384.98 MiB、`python-sympy 1.14.0` 101.50
MiB、`singular 4.4.1.p5`
59.25 MiB、`pari 2.17.4` 28.69 MiB、`fplll 5.5.0` 27.55 MiB、`flint 3.6.0` 19.81 MiB、`python-pip 26.2.1`
16.68
MiB、`ntl 11.6.0` 5.27 MiB、`python-fpylll 0.6.4` 2.72 MiB。

*推断*：`pari + fplll + python-fpylll + python-pip` 这条最小组合不到 70 MiB，能覆盖数论、整数关系与格约化三类猜想工作；SageMath
的价值主要在「一站式
glue」而非算法本身，而它的 2.56 GiB 代价应当是可选的。

=== (a) 六大 CAS 的定位与差异

#table(
  columns: 2,
  [*系统*], [*定位与差异*],
  [SageMath], [「把几十个开源数学软件粘成一个 Python 接口」的发行版，官方目标写明是 Magma / Maple / Mathematica / MATLAB 的自由替代（Arch
包描述同）。核心算法多来自 PARI、Singular、GAP、FLINT、NTL、fpLLL。当前 10.9。],
  [PARI/GP], [专注数论的 C 库 + 交互 shell：因式分解、代数数论、椭圆曲线、模形式、L 函数；`gp2c` 可把 GP 脚本编译成 C，官方称典型提速 3--4 倍。体积最小、
算法最硬。],
  [GAP], [「computational discrete algebra，特别侧重计算群论」，自带语言 + 数千函数 + 大量代数对象数据库；扩展以包形式发布，官方包列表目前 140 余个。当前
4.16.1（2026-08-23）。],
  [Magma], [商业闭源、由 University of Sydney 计算代数组分发，覆盖代数、数论、代数几何、代数组合，并以「供计算数学研究使用的数据库」为卖点。当前 V2.28。需持 licence、不能自由安装；*具体的 licence 类别与价格本次未能取到*（官方 ordering 页不可达），标 *UNVERIFIED*。],
  [Singular], [多项式计算专精：Gröbner 基、多项式系统求解、奇点理论。Arch 包 4.4.1.p5。],
  [Nemo / Hecke], [Julia 库。Nemo 提供多精度整数/有理数、有限域、$p$ 进数、数域算术、精确实数与复球（依赖 FLINT 与 AbstractAlgebra.jl）；Hecke
建在
Nemo 之上做代数数论：数域、序与理想、类群与单位群、格枚举、类域论、二次与 Hermitian 形式。Nemo 要求 Julia ≥ 1.10。],
  [OSCAR], [Julia 的「统一 CAS」，官方描述为把 *GAP、Polymake、Antic、Singular* 四个基座合成一套类型系统。当前 1.8.2（2026-09-02），要求
Julia
≥ 1.10。],
)

三个关键差异点，直接决定插件该怎么选后端：

- *语言边界*：Sage 是 Python（可 `import` 到现有 Python 工具链），GAP 是自有语言，Magma 是自有语言，OSCAR/Nemo/Hecke 是
  Julia。跨语言调用必须走字符串或 JSON 通道，是错误率最高的地方。
- *数据库是护城河*：Magma、GAP 的竞争力很大一部分在数据库（群、表示、代数对象），而非算法。GAP 的 Small Groups 库与 Magma 从 1.4
  版起编号一致，见 #link("https://www.gap-system.org/Manuals/pkg/smallgrp/doc/chap1.html")[GAP SmallGrp 手册]。
- *可复现性*：只有开源路线能让「独立复核者重跑同一计算」，这是本项目的硬约束。

=== (a-2) 安装路径与体积代价

SageMath 官方安装页 #link("https://doc.sagemath.org/html/en/installation/index.html")[SageMath Installation
Guide] 给出的方式：

- *conda-forge（官方推荐，跨发行版）*：`conda create -n sage sage python=3.11`。conda-forge 上的 `sage` 是「standard
  distribution」元包，由 `sagelib`（最小可 `import sage.all`）、`sage`（含全部标准依赖）、`sagemath-*`（可选组件）拆分而成，当前
  10.9 #link("https://anaconda.org/conda-forge/sage")[conda-forge/sage]。*本机未安装 conda / mamba*，实际磁盘占用 *UNVERIFIED*（未实测，故不给数字），可参照下方 Arch 侧的实测值。
- *Arch Linux（本机）*：`sudo pacman -S sagemath`，即上文实测的 360 包 / 约 2.56 GiB。
- 官方明确警告：*不要安装早于 9.5 的 Sage*。
- *推断*：conda 路线的优点是版本新、可 `%pip` 装可选包，缺点是与系统 Python 隔离、体积同等量级；在 Arch 上 `pacman` 路线更省心，因为 GAP / PARI /
  Singular / SymPy / fpylll 都是独立包，可以只装需要的。

按需分层的推荐（*推断*，体积为本机实测）：

#table(
  columns: 2,
  [*层级*], [*内容与代价*],
  [必需层], [`pari` 28.69 MiB + `fplll` 27.55 MiB + `python-fpylll` 2.72 MiB + `python-pip` 16.68 MiB ≈ 76
MiB：覆盖数论、整数关系、LLL/BKZ。],
  [符号层], [`python-sympy` 101.50 MiB（或 `pip install sympy`，纯 Python、无编译依赖）。],
  [群论层], [`gap` 384.98 MiB：只有需要有限群 / 表示 / 特征标表时才值得。],
  [全量层], [`sagemath` 约 2.56 GiB（依赖闭包）：只在需要 Sage 特有数据库（如 `sage-data-elliptic_curves`）或一站式 notebook 时。],
)

=== (b) SymPy：pip 安装与能力上限

- 装法：`pip install sympy`（上游文档与 PyPI 的标准方式）。*本机 `python3` 没有 `pip`*，所以要么先 `pacman -S python-pip`（16.68
  MiB），要么直接装 Arch 的 `python-sympy`（1.14.0，101.50 MiB）。SymPy 是纯 Python、无编译依赖，是本机最容易拿到的符号计算后端。
- *数论侧能力*：`sympy.ntheory` 提供筛法、`factorint`（含二次筛 `qs` / `qs_factor`）、`primerange`、`mobiusrange`、
  连分数族 #link("https://docs.sympy.org/latest/modules/ntheory.html")[ntheory 文档]。一个硬上限：`Sieve` 的实现「把素数个数限制在 $2^{32}-1$ 以内」。
- *代数数论侧能力*：`sympy.polys.numberfields` 提供 `round_two`（整基）
  、`prime_decomp`、`prime_valuation`、`galois_group`、`minimal_polynomial`、`field_isomorphism`、`primitive_element`，
  见 #link("https://docs.sympy.org/latest/modules/polys/numberfields.html")[numberfields 文档]。
- *上限（官方自陈）*：同一页明确写「目前只支持上述任务的一个子集」。对照该页自己列出的目标清单，*未提供*的是：基本单位系、regulator、类数、类群结构、以及判定理想是否主理想并给出生成元。
  这些正是很多数论猜想的核心量，所以 SymPy 只能做前处理，不能做终局计算。
- *序列与公式猜测*：`sympy.concrete.guess` 提供 `guess`（改编自 Krattenthaler 的
  Rate.m，用有理插值猜超几何型通项）、`guess_generating_function`（ogf/egf/lgf/hlgf/lgdogf/lgdegf
  六种母函数）、`find_simple_recurrence`、`rationalize`，
  见 #link("https://github.com/sympy/sympy/blob/master/sympy/concrete/guess.py")[guess.py
  源码]。注意这些 API 在用户文档里几乎不可见，属于「能用但不在稳定接口承诺内」的代码。
- *格约化*：SymPy 没有 LLL/BKZ 实现；整数关系只能借 `mpmath.pslq` / `mpmath.findpoly`（`rationalize` 的 docstring 自己这么推荐）。
- *推断*：SymPy 的正确定位是「表达式操作 + 轻量数论 + 与 Lean 交互的胶水层」，不是计算引擎。凡是需要类群、单位群、模形式系数的地方，必须下沉到 PARI 或 Sage。

=== (c) 猜想可用的具体操作

*整数序列*：OEIS 提供按 A 编号的稳定引用与每日更新的数据 dump（只含序列的 gzip 文件「几十 MB」，只含名称的「几
MB」），可在本地建索引做离线识别 #link("https://oeis.org/wiki/Welcome")[OEIS Wiki]。流水线建议：先用 OEIS
查是否已知，再用 `sympy.concrete.guess` 猜通项，最后用大范围数值验证。

*整数关系*：PARI 的 `lindep` / `algdep` 是工业级实现。*必须读它的免责声明*：`algdep`
文档原文说得到的多项式「不必然是正确的那一个」，而且「甚至不保证不可约」，因此结果只能当作待验证的猜测 #link("https://pari.math.u-bordeaux.fr/dochtml/html/Vectors__matrices__linear_algebra_and_sets.html")[PARI
线性代数章]。同页给出的经验：对 $2^{1/6}+3^{1/5}$ 求 30 次关系，默认精度会给出错误结果，必须把 precision 提到约 195 位以上才稳定正确——这正是「精度不足会静默给出假猜想」的实例。

*格约化 LLL/BKZ*：

- Sage 侧：`IntegerMatrix.LLL(delta, eta, algorithm='fpLLL:wrapper', fp, prec, early_red, use_givens, use_siegel, transformation, ...)`、`IntegerMatrix.BKZ(delta, algorithm='fpLLL'|'NTL', block_size, prune, proof, ...)`、`is_LLL_reduced(...)`，
  见 #link("https://doc.sagemath.org/html/en/reference/matrices/sage/matrix/matrix_integer_dense.html")[Sage 整数稠密矩阵文档]。注意 `proof=` 参数：关掉它则「更快但结果不是完全 BKZ 归约」，这类结果不能作为最终依据。
- 独立 CLI：`fplll` 支持 `-a lll|bkz|hkz|svp|cvp|sld|sdb`、`-d delta`、`-b block_size`、`-m wrapper|fast|heuristic|proved`、`-of u`
  输出酉变换矩阵 #link("https://fplll.github.io/fplll/")[fplll 文档]。文档自称的版本是 5.4.5，Arch 已经打包 5.5.0。`-of u` 是关键：有
  了 $U$ 就能用独立实现验证 $B' = U B$。归约强度的官方承诺也很具体：用 wrapper 或 proved 模式时「保证基是 $delta' = 2 delta - 1$、$eta' = 2 eta - 1\/2$ 意义下的 LLL 归约」，默认参数下即 $(0.98, 0.52)$-LLL 归约——*但只要选了 `-m fast` / `-m heuristic`，这个保证就没有了*。
- Python 绑定：`fpylll` 是 fplll 的独立 Python 接口，Arch 包 0.6.4。
- PARI：`qflll`、`qflllgram`、`mathnf`、`matdetint`、`qfminim`、`qfisom` 等（见上文线性代数章）。
- 另类通道：GAP 的 `float` 包声明「integration of mpfr, mpfi, mpc, fplll and cxsc in
  GAP」#link("https://www.gap-system.org/Packages/packages.html")[GAP 包列表]，即 GAP 里也能调 fplll。

*椭圆曲线*：PARI 用 `ellinit` 建立 `ell` 结构，成员含 `a1..a6`、`b2..b8`、`c4,c6`、`disc`、`j`，复数域上还有 `omega`（周期格基）
、`eta`（准周期）、`roots`，并可用 `ellperiods` 重算缓存；`ellpointtoz` / `ellztopoint` 在格 $bb(C) \/ Lambda$ 与点之间往返。
官方特别提醒基的定向约定与很多文献相反 #link("https://pari.math.u-bordeaux.fr/dochtml/html/Elliptic_curves.html")[PARI 椭圆曲线章]。批量数据用 Arch 的 `sage-data-elliptic_curves`（Cremona 数据库）；Magma 亦以自带椭圆曲线数据库为卖点。

*有限群*：GAP 的 Small Groups 库给出到 isomorphism 唯一表示的完整列表，覆盖面为「阶 ≤ 2000 且 ≠ 1024（共 423 164 062 个群）」、「cubefree
阶 ≤
50 000」、「$p^7$，$p=3,5,7,11$」等；识别函数对 512、1536、以及 > 2000 的 $p^5,p^6,p^7$
不可用 #link("https://www.gap-system.org/Manuals/pkg/smallgrp/doc/chap1.html")[SmallGrp
手册]。文档自陈「数据经过仔细交叉检查，但不给绝对保证，关键场合请自行验证」——这句话应当直接写进技能的输出约定里。配套库还有 `TransGrp`（传递群）、`PrimGrp`（本原置换群）
、`AtlasRep`（ATLAS 表示）、`CTblLib`（特征标表）。

*模形式*：PARI 的 `mfinit` 建空间（全空间 / 尖点 / Eisenstein / new / old），`mfbasis` 取基，`mfeigenbasis` 取 new space
特征形式基，`mfcoefs` 取任意多项 Fourier 系数（值在 $bb(Q)(chi)$ 的分裂域中），`mfparams` 反查
level/weight/character，另有 `mftraceform`、`mftwist`、`lfunmf`（把模形式接到 `lfun`
包） #link("https://pari.math.u-bordeaux.fr/dochtml/html/Modular_forms.html")[PARI
模形式章]。*陷阱*：文档明确说对「广义模形式」（$E_2$、eta 商、模形式的商、导数与积分）不会检查对象是否真是模形式，未声明支持的函数其输出「未定义」。

=== (d) 与 Lean 的形式化鸿沟

*鸿沟的本体*：CAS 输出的是一个数据结构或一个数值，Lean 的 kernel 只接受证明项，两者之间没有任何自动桥接。CAS 说「这个多项式不可约」不构成 Lean 命题的一条证明。

*最危险的捷径是 `native_decide`*。Lean 4 官方 tactic 文档原文（源码 docstring）说：`decide +native`「用 native
代码编译器（`#eval`）求值 `Decidable` 实例，*通过一条公理*承认结果」，代价是「增大可信代码基」，因为它「依赖于 Lean 编译器的正确性以及所有带 `@[implemented_by]`
属性的定义」；`native_decide` 会让一条新公理出现在 `#print axioms`
里，并且文档直言「对大计算，这是运行外部程序并信任其结果的一种方式」 #link("https://github.com/leanprover/lean4/blob/master/src/Init/Tactics.lean")[Lean
4 Init/Tactics.lean]。用 CAS 生成结果 + `native_decide` 验收，等于把 CAS 直接搬进 TCB。

*可接受的路线是「证书 + 独立复核」*（*推断*，但每一条都对应 Lean 里可表达的对象）：

- 素性：给 Pratt 证书（分解 $n-1$ 并递归给出原根），而不是「CAS 说它是素数」。
- 格约化：输出酉变换矩阵 $U$ 与归约基 $B'$，在 Lean 侧检查 $B' = U B$ 且 $U$ 可逆、$B'$ 满足 Lovász 条件。
- 线性代数：Smith / Hermite 标准形配变换矩阵；`Matrix.LLL` 式的实现若只给结果矩阵则无法复核。
- 数值型结论（`algdep` 的候选多项式、PSLQ 的关系式）：先在有理数上精确重算残差，再把它变成可验证的等式。

*基准与现状*：Formal Conjectures 仓库是当前最相关的公开资产，用 Lean 4 + mathlib 形式化了 2615 条问题陈述，其中 *1029 条公开猜想*、836
条已解问题，并带 `@[category]` 等属性与稳定的 `bench-v{N}` 快照；论文自陈「只形式化陈述而不形式化证明本身就容易出细微偏差」，并把 AI 生成的证明/反证当作迭代修正
benchmark
的审计手段 #link("https://github.com/google-deepmind/formal-conjectures")[formal-conjectures] #link("https://arxiv.org/abs/2605.13171")[arXiv:2605.13171]。

*UNVERIFIED*：本机 elan 已装三个 Lean 工具链并缓存了 mathlib 构建产物，但未验证这些工具链版本与当前 mathlib release 的兼容性，也未验证存在的 Lean+CAS 桥接库。

=== (e) Julia 生态：替代路线

- *定位*：OSCAR 把 GAP、Polymake、Antic、Singular 四套系统统一到 Julia 的类型系统里，Nemo/Hecke 则是它的数论内核（Hecke 的 README
  直接写明「Hecke is part of the OSCAR project」）。因此 Julia 路线的实质是「用一套语言驱动同样的算法后端」，而不是新算法。
- *能力对位*：Hecke 提供数域（绝对/相对/非单生成）、序与理想、类群与单位群、格枚举、稀疏线性代数、类域论、Abel 群、结合代数、二次与 Hermitian
  形式与格 #link("https://github.com/thofma/Hecke.jl")[Hecke.jl README]。这正好补上 SymPy 明确缺失的那一块（类数、类群结构、单位群）。
- *安装*：`julia> using Pkg; Pkg.add("Oscar")` / `Pkg.add("Hecke")` / `Pkg.add("Nemo")`，均要求 Julia ≥ 1.10；本机
  Julia 1.12.6 满足要求 #link("https://github.com/oscar-system/Oscar.jl")[Oscar.jl
  README] #link("https://nemocas.github.io/Nemo.jl/stable/")[Nemo 文档]。
- *本机状态*：`~/.julia` 已存在（92 包 / 628 MB）但 *不含* Nemo、Hecke、Oscar、AbstractAlgebra，首次安装需要联网拉取二进制制品；Oscar 的安装体积 *UNVERIFIED*（未实测）。
- *相对 Sage 的取舍*（*推断*）：Julia 路线的优势是单一语言、单一类型系统、一个长驻进程即可同时持有群、理想与格，非常适合做成 MCP server 的常驻后端；劣势是生态与文档厚度不如
  Sage，且同样不提供任何形式化保证——OSCAR 的输出仍然只是 CAS 输出。

=== 评估

- *该抄：把技能的输出契约定义成「断言 + 证书 + 复核脚本」三元组，而不是「结果」。* 具体机制：任何调用 CAS 的 `SKILL.md` 强制要求同时产出可独立验证的附件（素性用 Pratt
  证书；格约化用 `fplll -of u` 的酉矩阵 $U$ 与 $B'$，并在另一实现里验 $B' = U B$；整数关系先在有理数上精确重算残差），缺附件则技能必须把结论标为「猜测」。这条直接应对
  PARI `algdep` 官方承认的「结果不必然正确」。
- *该抄：把后端做成能力探测 + 分层的运行时，而不是硬依赖 Sage。* 具体机制：MCP server 启动时对每个后端做 `command -v`
  探测，把「必需层」（`pari` + `fplll` + `fpylll`，本机 < 80 MiB）与「可选层」（`sympy` 101 MiB、`gap` 385 MiB、`sagemath` ≈ 2.56
  GiB）分开声明；技能在文档里写清降级路径，而不是在缺后端时静默失败。
- *该避免：把 `native_decide` 当作「CAS 结果的 Lean 验收器」。* Lean 官方文档已明说它通过一条公理承认结果、把整个编译器与 `@[implemented_by]`
  定义拉进可信基，并鼓励「运行外部程序并信任结果」。插件应在回答里强制暴露 `#print axioms` 的输出，出现非标准公理就把该结论降级，而不是让它伪装成已证。
- *该避免：用 SymPy 做数论终局计算。* 官方 numberfields 文档自陈只支持核心任务的子集，单位群、regulator、类数、类群结构、主理想判定都缺失；`Sieve`
  还把素数限制在 $2^{32}-1$ 以内。技能应把 SymPy 限定在表达式操作、序列猜测与胶水层，超出即路由到 PARI 或 Hecke。
- *该抄：把 OEIS 做成可离线查询的本地索引，构成「查库 → 猜 → 证」三段流水线。* 具体机制：用 OEIS 的仅名称 dump（几 MB 级）建本地检索，命中则直接引用 A
  编号；未命中再交给 `sympy.concrete.guess` / `mpmath.pslq` 猜，最后必须落到一条可验证的等式或可形式化的陈述。
- *该抄：把矛盾的元数据当成技能的输出义务。* GAP SmallGrp 手册自己写「数据经交叉检查，但不给绝对保证，关键场合请自行验证」，fplll 的 `proof=`、Sage 的 `proof=`
  都是同类信号。技能应在每条 CAS 结论旁强制标注「引擎 + 版本 + 是否启用 proof 模式 + 是否与数据库编号对齐（如 SmallGrp 1.4 起与 Magma 2.23
  编号一致）」，让复现者能判断结论的可信等级。

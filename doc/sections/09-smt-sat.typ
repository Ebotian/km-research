== SAT/SMT 求解器接入

本节回答：Z3 / cvc5 / Yices 的 Python 绑定、能力边界与安装；Kissat / CaDiCaL / MiniSat 与 PySAT；
如何用 SMT 做反例搜索与有界验证；UNSAT core 与 proof 的可验证价值；超时与并行；常见编码陷阱。
除标注「推断」外，全部结论来自官方文档、官方仓库源码或 PyPI 元数据（2026-09-14 读取）。

本机实测（只读核实）：Python 3.14.6，`python3 -m pip` 报 `No module named pip`，但 `/usr/bin/uv` 与 `uvx` 存在；
g++ 16.2.1 / gcc / make / cmake 4.4.2 / pkg-config 存在；glibc 2.44；`nproc` = 12；
`z3`、`cvc5`、`python-sat`、`kissat`、`cadical`、`minisat` 均不可导入或不在 PATH（`cargo` 亦缺，直接影响证明检查器的选择）。

=== 绑定、安装方式与体积

#table(columns: 2,
  [*绑定*], [*安装路径与实测体积（PyPI，2026-09-14）*],
  [Z3 Python],
  [`uv pip install z3-solver`。最新 5.1.0.0，Linux x86-64 wheel 为 `py3-none-manylinux_2_27_x86_64.whl`，*33.1 MB*；
   wheel 是 `py3-none`（ABI 无关），Python 3.14 可直接用；另有 5.5 MB sdist。官方 README 给出的即 `pip install z3-solver`。
   #link("https://github.com/Z3Prover/z3")[Z3 README] #link("https://pypi.org/project/z3-solver/")[PyPI]],
  [cvc5 Python],
  [`uv pip install cvc5`。最新 1.3.4，`cp314-cp314-manylinux_2_17_x86_64.whl`，*13.7 MB*（另有 cp38–cp313 wheel）。
   C++ 依赖（CaDiCaL/Kissat/libpoly 等）已打进 wheel，不需要系统装库。
   #link("https://pypi.org/project/cvc5/")[PyPI]],
  [Yices 2 Python],
  [`pip install yices`（PyPI `yices` 1.1.6，纯 Python ctypes，wheel 仅 *0.07 MB*）——但*必须先装 Yices 本体*：
   Ubuntu/Debian 走 SRI 的 PPA（`apt install yices2` 或 `yices2-dev`），或源码编译（需 gperf、GMP ≥ 4.1）。
   绑定 README 原文：“Install the Yices SMT Solver first, then, install the python language bindings”。
   #link("https://github.com/SRI-CSL/yices2")[yices2 README] #link("https://github.com/SRI-CSL/yices2_python_bindings")[绑定 README]],
  [PySMT（统一层，可选）],
  [`pysmt` 0.9.6，PyPI 摘要原文：“A solver-agnostic library for SMT Formulae manipulation and solving”。
   适合做多后端对比实验；本轮未核实其各后端成熟度，只作候选记录。#link("https://pypi.org/project/pysmt/")[PyPI]],
)

*Z3 能力边界*（依据官方全局/分组参数表与 Python 源码）：
- 线性整数算术 `QF_LIA` 有专用判定流程（`arith.*` 组，如 `arith.enable_hnf`、`arith.branch_cut_ratio`）；
- 非线性有*两条不同路线*：`smt.arith.nl` 官方描述就写着 “*(incomplete)* nonlinear arithmetic support based on Groebner basis and interval propagation”；
  实数非线性另有完备方法 `nlsat`（独立 `nlsat.*` 参数组）。整数非线性则只有前者的不完备支持；
- 位向量：位爆破到 SAT，参数表明确说 `parallel.enable` 的作用是 “enable parallel solver by default on selected tactics (for QF_BV)”；
- 量词：靠模式推断（`pi.*` 组，`pi.enabled` 默认 true）+ `smt.mbqi`，本质是不完备的实例化；
- 可用的停止/度量参数：`timeout`（毫秒）、`rlimit`、`memory_high_watermark_mb`、`memory_max_size`。
#link("https://microsoft.github.io/z3guide/programming/Parameters/")[Z3 Parameters]

*cvc5 能力边界*（依据官方 `src/options/*.toml` 选项定义）：
- 证明与 unsat core *默认全关*：`--produce-proofs`、`--produce-unsat-cores`、`--produce-unsat-assumptions` 默认 false；
  `--produce-unsat-cores` 的官方说明是“用 SAT 在假设下求解 + 预处理证明”产出 core；
- 非线性：`--nl-ext=MODE`，默认 `FULL`，说明为 “incremental linearization approach to non-linear”（增量线性化是*不完备*方法，需外部模型精化，常返回 unknown——后半句为推断）；
- 量词相关开关齐备：`--mbqi`、`--mbqi-enum`、`--enum-inst`、`--inst-when`、`--user-pat`、`--trigger-sel`、`--finite-model-find`、`--fmf-bound`；
- 超时：`--tlimit=MS`、`--tlimit-per=MS`、`--rlimit=N`、`--rlimit-per=N`；并行：`--use-portfolio` + `--portfolio-jobs=n`（默认 1）；
- Python API 名称（`src/api/python/cvc5.pxi` 核实）：`Solver`、`TermManager`、`setOption`、`setLogic`、`assertFormula`、
  `checkSatAssuming(*assumptions)`、`getUnsatCore`、`getUnsatCoreLemmas`、`getProof(c=ProofComponent.FULL)`、`getValue`、
  `getModelDomainElements`、`getUnknownExplanation`、`getDifficulty`、`getTimeoutCore`、`blockModel`、`resetAssertions`。
#link("https://github.com/cvc5/cvc5/tree/main/src/options")[cvc5 options] #link("https://github.com/cvc5/cvc5/blob/main/src/api/python/cvc5.pxi")[cvc5.pxi]

*Yices 2 的边界*（README 一手）：
- README 的示例只覆盖 `QF_LRA`、`QF_BV`、`QF_NRA` 三个 quantifier-free 逻辑；其对量词的支持情况本轮未核实（`UNVERIFIED`），若需要量词请先做小实验；
- 非线性走 MC-SAT，且*默认不编译*：必须先装 #link("https://github.com/SRI-CSL/libpoly")[libpoly] 与 CUDD，再 `./configure --enable-mcsat`；
  README 同时写明 “We are currently extending it to handle bit-vector constraints”，即 MC-SAT 尚未覆盖 BV；
- 线程安全默认关闭，需 `./configure --enable-thread-safety`；官方 Python 绑定的自检输出即 “Thread safe: no”；
- 没有内建并行：仓库提供 `utils/yices2_parallel.py -n 4`，本质是并行启动多个 `yices_smt2` 进程的 portfolio，先出结果者返回。

=== 高性能 SAT 求解器与 PySAT

本机 `kissat` / `cadical` / `minisat` 都不在 PATH，三条接入路径如下。

- *Kissat*（#link("https://github.com/arminbiere/kissat")[仓库]）：构建方式 `./configure && make test`，每个 major release 附带官方二进制；
  命令行 `kissat [options] [<dimacs> [<proof>]]`，给 `<proof>` 即写证明；真实文件默认*二进制*证明格式，`-`（stdout）时是 ASCII 文本。
  源码 `src/options.h` 中与证明相关的选项只有 `flushproof`，未见 LRAT 选项——*推断*它只提供 DRAT 级别的跟踪（源码读取所限，属推断）。
- *CaDiCaL*（#link("https://github.com/arminbiere/cadical")[仓库]）：`./configure && make` 生成 `cadical` 与 `libcadical.a`；
  用法 `cadical [ dimacs [ proof ] ]`。证明相关选项（`src/options.hpp` 核实）：`lrat`、`frat`（1=frat(lrat), 2=frat(drat)）、
  `idrup` / `lidrup`（增量证明格式）、`binary`、`veripb`、以及自检开关 `checkproof`（1=drat, 2=lrat, 3=both，默认 3）。
  3.0 起 BVA（`factor`）要求显式声明变量（`declare_more_variables`），否则增量场景下会与证明检查冲突。
- *MiniSat*：上游 #link("https://github.com/niklasso/minisat")[niklasso/minisat] 最后一次提交是 2013-09-25（commits atom feed 实测），
  已停止维护；实用形态是 PySAT 的 `Minisat22` / `MinisatGH` / `MinisatEP`（后者带 IPASIR-UP）。
- *真并行*：Kissat / CaDiCaL / MiniSat 都是单线程；同组的 #link("https://github.com/arminbiere/gimsatul")[Gimsatul]
  是 portfolio 式多线程且 #link("https://arxiv.org/abs/2207.13577")[宣称可出证明]（POS'22）。

*PySAT 1.9.dev15*（#link("https://pysathq.github.io/docs/html/api/solvers.html")[API 文档] / #link("https://github.com/pysathq/pysat")[README]）：
- 安装 `pip install python-sat[aiger,approxmc,cryptosat,pblib]`，或最小化 `pip install python-sat`；
  Linux x86-64 的 `cp314` manylinux wheel 为 3.9–4.0 MB。README 描述的 make / patch / C++11 编译器 / zlib 要求属于 sdist 路径；
  wheel 是平台专用且已预编译（*推断*）。
- 内建求解器版本是*确定的*：CaDiCaL rel-1.0.3 / 1.5.3 / 1.9.5 / 3.0.0、Kissat rel-4.0.4、Glucose 3.0 / 4.1 / 4.2.1、
  Lingeling、MapleLCMDistChronoBT、MapleCM、Maplesat、Mergesat 3.0、Minicard 1.2、MiniSat 2.2 / GitHub 版 / IPASIR-UP 版。
- 统一 MiniSat 风格接口：`Solver(name=...)`、`bootstrap_with=`、`solve(assumptions=...)`、`solve_limited(...)`（配合
  `conf_budget()` / `prop_budget()` / `dec_budget()` / `interrupt()`，预算耗尽或被打断返回 `None` = unknown）、
  `get_core()`、`get_proof()`（DRUP 行）、`enum_models()`、`set_phases()`、`accum_stats()`、`time_accum()`。
- `solve_limited()` 的*支持面容易踩坑*：正文注明“只有 MiniSat 系求解器支持”，同时又给出 `Cadical153` 的 `dec_budget` + `solve_limited` 示例；
  `conf_budget`/`prop_budget` 的官方示例用的是 `MinisatGH`。要稳就用 Glucose/MiniSat 系（`Glucose4`、`Minisat22`）。
- `Kissat404` 是文档里唯一被反复强调 “non-incremental” 的类：`solve()` 忽略 assumptions、不支持 core、`solve()` 之后不能再加子句、
  不支持模型枚举；但支持 conflict/decision/propagation 预算与 `get_proof()`。做 MUS/core 流程不要用它。
- DRUP proof 支持列表为 Lingeling、CaDiCaL 各版、Glucose/Gluecard/Glucose42、Maple 系列、Maplesat；MiniSat 系列不在其中。
- 自带基数/伪布尔编码（`pysat.card` / `pysat.pb`）：pairwise、bitwise、sequential counters、sorting networks、cardinality networks、
  ladder/regular、totalizer、modulo totalizer、iterative totalizer。原生 AtMostK/PB 只有 `Cadical195`、`Cadical300`、`MinisatEP`（走 IPASIR-UP 外部传播器）。
- `pysat.examples` 可直接复用：`musx`（MUS 枚举）、`rc2`/`mcsls`/`optux`（MaxSAT）、`lbx`/`hitman`（Benders/命中集）、
  `primer`、`genhard`（PHP 等难例生成器）；allies 里 `approxmc`（模型计数）、`unigen`（均匀采样）。

```python
from pysat.solvers import Glucose4
from pysat.formula import CNF
from threading import Timer

cnf = CNF(from_file="instance.cnf")
with Glucose4(bootstrap_with=cnf, with_proof=True) as s:
    s.conf_budget(10**6)                      # 确定性预算，超了返回 None
    t = Timer(60.0, s.interrupt); t.start()   # 墙钟兜底（只对 solve_limited 有效）
    res = s.solve_limited(assumptions=[1, -2], expect_interrupt=True)
    t.cancel()
    if res is False:
        print(s.get_core())                   # core 是 assumptions 的子集
        print(s.get_proof()[:3])              # DRUP 行，可交 drat-trim 复验
```

=== 用 SMT 做反例搜索与有界验证

三条可落地的模式，按可靠性从高到低：

1. *有界模型检验（BMC）*：把程序/过程展开到深度 $k$，转成 SAT 公式；SAT 的解直接给出具体反例轨迹，UNSAT 只说明“$k$ 内无反例”。
   CBMC（#link("https://github.com/diffblue/cbmc")[仓库]）README 原文即“verification is performed by unwinding the loops in the program and
   passing the resulting equation to a decision procedure”。关键选项（`cbmc_parse_options.cpp` 核实）：`--unwind N`、`--unwindset`、
   `--unwinding-assertions` / `--no-unwinding-assertions`、`--depth`。源码里对 `--unwind` 与 `--unwindset` 都会打印
   `**** WARNING: Use --unwinding-assertions to obtain sound verification results`，对 `--depth` 打印
   `**** WARNING: Depth-bounded analysis may yield unsound verification results`——*有界结论必须显式声明界，否则不能当证明用*。
2. *把无界/难判定问题截断成有限域搜索*：整数变量加 `And(0 <= x, x <= B)`，或用 $k$ 位 BV 编码；
   cvc5 有专门的 `--finite-model-find` / `--fmf-bound`；Z3 有局部搜索战术 `sls-smt` / `sls-qfbv`
   （官方说明其用途就是“as a stand-alone incomplete local search solver”，并可与 CDCL(T) 并行：`smt.sls.enable=true`、`smt.sls.parallel`）。
   #link("https://microsoft.github.io/z3guide/programming/Local%20Search")[Z3 Local Search]
3. *找“最小”反例*：Z3 `Optimize` 做目标最小化（#link("https://microsoft.github.io/z3guide/docs/optimization/intro")[Z3 Optimize]）；
   组合问题上用 PySAT `musx` 枚举 MUS、`rc2` 做 MaxSAT，把“最小反例/最小不可满足子公式”做成一个可搜索目标。

```python
from z3 import *

B = 60                                                       # 有界搜索：域截断必须写进公式
x, y, z = Ints("x y z")
dom = And(1 <= x, x <= B, 1 <= y, y <= B, 1 <= z, z <= B)
bad = And(dom, x*x*x*x + y*y*y*y == z*z*z*z)                 # 猜想的否定：Fermat n=4 在域内找反例

s = Solver()
s.set("timeout", 10_000)
s.add(bad)
r = s.check()
if r == sat:
    print("counterexample:", s.model())        # 模型即反例，可独立复核
elif r == unsat:
    print(f"no counterexample up to B = {B}")  # 只说明“域内无反例”，不是定理
else:
    print("unknown:", s.reason_unknown())
```

- 方向选择上：`sat` 结果*天然可验证*（模型可交给第三方模型验证器核对，SMT-COMP 2025 就设了
  #link("https://smt-comp.github.io/2025/")[Model Validation Track]）；`unsat` 才有“凭什么相信”的问题，需要 core 或证明（见下节）。
- 对全称猜想不要直接写无界 `ForAll`：量词依赖模式/实例化，往往直接 unknown。要么把全域截断成有限域（推荐），
  要么用 cvc5 的 `--finite-model-find`，并接受“有限域无反例 ≠ 定理成立”的界限。

=== UNSAT core 与 proof：把结论变成可复核的证书

*Z3 的 core 机制*（`z3.py` 文档字符串核实，可直接照抄）：
```python
from z3 import *
x = Int('x'); p3 = Bool('p3'); s = Solver()
s.set(unsat_core=True)
s.assert_and_track(x > 0,  'p1')     # 每条假设起名，core 输出才是人可读的
s.assert_and_track(x != 1, 'p2')
s.assert_and_track(x < 0,  p3)
assert s.check() == unsat
print(s.unsat_core())                # [p1, p3]：p2 与该冲突无关
```
- `Solver.check(*assumptions)` + `unsat_core()` 支持不重写公式的增量假设；参数 `sat.core.minimize`（默认 false）可最小化 core。
- `cube(vars)`、`consequences(assumptions, variables)`、`solve_for`、`reason_unknown()`、`statistics()` 同属 `Solver` 上的可用出口。
- MUS/MCS 枚举的完整算法（Liffiton & Malik 2013 / Previti & Marques-Silva 2013）在
  #link("https://microsoft.github.io/z3guide/programming/Example%20Programs/Cores%20and%20Satisfying%20Subsets")[Z3 官方 Cores 示例] 里给出可运行实现。

*Z3 的 proof*：需要 context 创建时开 `proof=true`（全局参数，默认 false）；`solver.proof.save` / `solver.proof.trim` 可把推理日志存成对象/裁剪；
4.12 起提供 proof log：`Z3_solver_register_on_clause`（Python 侧 `OnClause`）逐条捕获推理，提示名包括
`tseitin`、`euf`、`inst`、`farkas`、`bound`、`rup`。
*官方明确说它并不自包含*：“Some of the steps can be checked by lean self-contained proof checkers, other steps do not contain detailed guidance
that would allow efficient validation. They require checking using general purpose SMT solving.”
自检可用 `solver.proof.check=true`，并可关掉昂贵的 RUP 检查：`sat.smt.proof.check_rup=false`。
#link("https://microsoft.github.io/z3guide/programming/Proof%20Logs")[Z3 Proof Logs]

*cvc5 的证书链*（更适合作为“可外传的结论”）：
- core：`--produce-unsat-cores`（默认 false）、`--minimal-unsat-cores`（把 core 缩减为*极小* core）、`--check-unsat-cores`（事后自查，官方注明 expensive）、
  `--unsat-cores-mode`；Python 侧 `getUnsatCore()` / `getUnsatCoreLemmas()`，以及 `getTimeoutCore()`（给出*导致超时*的那部分断言）。
- proof：`--produce-proofs`，配合 `--proof-format-mode`，可选格式为 `none` / `dot` / `lfsc` / `alethe` / `cpc`，
  另有 `--proof-granularity` 与 `--check-proofs`（cvc5 内部自查）。
- 外部检查：Alethe 证明由 #link("https://github.com/ufmg-smite/carcara")[Carcara]（TACAS 2023）独立检查；
  但它*需要 Rust/Cargo ≥ 1.93*，而本机没有 `cargo` → 本机路线是先靠 cvc5 自带的 `--check-proofs`，装 Rust 后再上 Carcara。

*SAT 层的证书才是真正工业化的那一段*：
- 格式：DRAT / LRAT / LPR / FRAT / IDRUP / LIDRUP（CaDiCaL 全部支持，见上）；
  检查器 #link("https://github.com/marijnheule/drat-trim")[drat-trim] README 原文：“Clausal proofs should be in the DRAT format which is used to validate the results of the SAT competitions。”
- 形式化验证过的检查器：`cake_lpr`（CakeML 编译；2024-03-11 起原生支持二进制 LRAT/LPR；2026-07-22 起堆栈大小改用 `--CML_HEAP_SIZE=` / `--CML_STACK_SIZE=` 命令行参数）：
  #link("https://github.com/tanyongkiam/cake_lpr")[cake_lpr]。
- 规模感（说明这条路真能走通）：Boolean Pythagorean Triples 问题产出了 *约 200 TB* 的 DRAT 证明，并发布 68 GB 压缩证书供任何人重建复核
  （#link("https://arxiv.org/abs/1605.00723")[arXiv:1605.00723]）；Schur Number Five 的 *2 PB* 证明用形式化验证过的检查器认证
  （#link("https://arxiv.org/abs/1711.08076")[arXiv:1711.08076]）。
- 因此本项目的策略建议：*SMT 只负责建模与枚举，最终 UNSAT 结论尽量下推到 SAT 层出 DRAT/LRAT*，
  这样结论可以被第三方用 drat-trim / cake_lpr 在不信任求解器的前提下复核（此条为推断性工程建议）。

=== 超时处理与并行

- *Z3*：per-solver `s.set("timeout", 5000)`（毫秒，会覆盖全局 `timeout`），全局还有 `rlimit`（资源步数）、
  `memory_high_watermark_mb` / `memory_max_size`（内存硬上限）、`memory_max_alloc_count`；
  运行中停止用 `s.interrupt()`，之后读 `s.reason_unknown()` 拿到原因串（据此区分超时还是被取消）。
  注意 `timeout` 由内部检查点触发，不保证墙钟精确（*推断*）。
- *cvc5*：进程内 `--tlimit`（累计墙钟）/ `--tlimit-per`（每次查询）/ `--rlimit` / `--rlimit-per`；
  还有 `getTimeoutCore()` 直接回答“是哪几条断言把我拖超时的”，这比单纯记超时更有研究价值。
- *PySAT*：`conf_budget` / `prop_budget` / `dec_budget` + `solve_limited()` 是*确定性*预算；墙钟兜底用 `threading.Timer` 调 `interrupt()`
  （官方示例即此写法），必须配 `expect_interrupt=True`，中断后要 `clear_interrupt()` 才能再调用，返回 `None` 即 unknown。
- *并行*：Z3 的 `parallel.enable` / `parallel.threads.max` 只在部分 tactic（如 QF_BV）生效，不是全局加速开关；
  cvc5 走 `--use-portfolio --portfolio-jobs=n`；Yices 靠多进程 portfolio 脚本；Kissat/CaDiCaL 单线程。
  本机 12 核的可落地做法是*进程级 portfolio*：`subprocess` 起多个不同 solver/seed 的进程，各自设 `tlimit`，
  先返回 sat 者胜出，全超时则报告 unknown（*推断*）。
- 线程安全红线：Yices 默认*非*线程安全（要 `--enable-thread-safety` 重编）；Python GIL 下 `z3`/`cvc5` 的 Python 对象也不宜跨线程共享，
  优先多进程。

=== 常见编码陷阱

- *整数溢出*：SMT 的 `Int` 是*无界*整数，`BitVec n` 才是环绕语义，二者混用会得到“数学上正确但工程上错误”的模型。
  Z3 的 `Int2BV(a, n)` 官方文档字符串写的是“represents the modulo of a by 2^num_bits”，即静默取模；
  `BV2Int(b, is_signed=False)` 默认按*无符号*解释，要按符号解释必须自己写 `If(b < 0, BV2Int(b) - 2**n, BV2Int(b))`（源码示例原文）。
- *非线性*：SMT-LIB 的 `QF_NIA` 定义原文就排除了幂运算——“whose terms of sort Int have no occurrences of the function symbol `**`”，
  所以要写 `x * x` 而不是 `x**2`；`Ints` 理论里虽有 `**`，但语义特殊（约定 `(** 0 0) = 1`，非整数次幂结果定义为 0）。
  非线性整数算术一般不可判定（*推断*，Hilbert 第十问题），Z3 参数表把 `smt.arith.nl` 标为 incomplete、cvc5 用增量线性化——
  因此必须显式处理 `unknown`，不能把 unknown 当 unsat。
- *量词*：`ForAll` 的成败取决于触发器/模式（Z3 `pi.*`；cvc5 `--user-pat`、`--trigger-sel`、`--inst-when`、`--mbqi`、`--enum-inst`）。
  做反例搜索时优先用*存在式 + 有限域*，而不是“全称猜想直接取反 + 无界量词”。
- *位宽与除零*：SMT-LIB `QF_BV` 历史上多次改定义——2017-05-03 起除法/取余在除数为 0 时不再是 undefined；
  2011-06-15 修过 `bvsmod` 在负除数下的错误定义；2024-07-15 才加入 BV 与 Int 的互转算子，并在 2025-02-25 *改名*为
  `ubv_to_int`、`sbv_to_int`、`(_ int_to_bv m)`。Z3 Python 侧仍是 `BV2Int` / `Int2BV` 两个旧名，跨求解器互操作时不要想当然。
  #link("https://smt-lib.org/Logics/QF_BV.smt2")[QF_BV 逻辑定义] #link("https://smt-lib.org/logics-all.shtml")[SMT-LIB 2.7 逻辑总表]
- *`div` / `mod` 语义*：SMT-LIB 的 `Ints` 理论规定 `div`/`mod` 采用 *Boute 的欧几里得定义*（余数非负），与 C/Python 的截断除法在负操作数上不同——
  从参考实现翻译到 SMT 时这是最经典的静默错误源。#link("https://smt-lib.org/theories-Ints.shtml")[Ints 理论]
- *增量与扩展变量*：Kissat 非增量，循环里 `add_clause()` 是未定义行为；CaDiCaL 3.0 的 BVA 会引入内部扩展变量，
  PySAT 的 `Cadical300` 在不绑定 `IDPool` 时默认关闭 BVA，若手动开启必须 `attach_vpool()` / `sync_vpool()`。

=== 评估

- *该抄：把 assumption + core 做成一等公民接口*。Z3 `assert_and_track` / `check(*assumptions)` / `unsat_core()`，
  cvc5 `checkSatAssuming` / `getUnsatCore` / `getUnsatCoreLemmas` 都能在不重写公式的前提下回答“是哪几条前提冲突”。
  插件应把每条研究假设命名（如 `H1_pigeon_bound`）并原样回显 core，这是研究者最需要的可解释性。
- *该抄：`solve_limited` 式确定性预算 + 墙钟兜底 + unknown 三态*。PySAT 的 `conf_budget`/`solve_limited` 返回 `None`，
  cvc5 有 `getTimeoutCore`。插件应统一返回 `sat / unsat / unknown`，unknown 时附 `reason_unknown()`，
  绝不允许把 unknown 折叠成 unsat。
- *该抄：证据分级输出*。搜索结果分三档：(1) 模型（可独立复核）→ (2) UNSAT core（假设级解释）→ (3) DRAT/LRAT 文件
  （用本机可编译的 drat-trim / cake_lpr 复验）。cvc5 负责 Alethe，但 Carcara 需 Rust≥1.93 而本机无 cargo，
  所以近期路线是“SMT 建模 + SAT 层出 DRAT”。
- *该避免：用 Kissat 做增量/增量式 MUS*。它非增量、无 assumptions、无 core；增量与 core 用 CaDiCaL 或 Glucose 系（PySAT 的
  `Cadical195`/`Glucose42`），而*限时预算*优先用 Glucose/MiniSat 系（`Glucose4`/`Minisat22`），因为 `solve_limited` 的支持面在文档里并不一致；
  Kissat 只用于一次性的硬实例；`Cadical300` 一旦启用 BVA 就必须绑 `IDPool`。
- *该避免：把 `Int` 当机器整数、把无界 `ForAll` 当猜想验证*。溢出要用显式 `BitVec n` 建模并写清位宽；
  非线性/量词问题先截断成有限域（`And(0 <= x, x <= B)` 或 k 位 BV）并写明“有限域内无反例 ≠ 定理成立”。
- *该避免：假设 `pip` 可用*。本机 `python3 -m pip` 直接报 `No module named pip`，`uv`/`uvx` 才是可用入口；
  插件应把 z3-solver（33 MB）/ cvc5（13.7 MB）/ python-sat（约 4 MB）装进项目本地 venv，
  不要动系统 Python，也不要依赖 Yices（本机无 apt 权限时它必须先装 libyices）。

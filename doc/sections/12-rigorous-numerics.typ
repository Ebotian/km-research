== 严格数值计算与可证明界限

本节要回答的问题很具体：把「浮点实验里看到的那个数」升级成「可以作为定理陈述的严格上界或下界」时，本插件该依赖哪些库、按什么流程走、又该在什么位置把证据交到 Lean 手里。全节区分 `一手事实`（官方文档或源码原文所述，附 URL）与 `推断`（本项目据此作的判断）；无法核实的写 `UNVERIFIED`，不编造 API 名与版本号。

*本机工具链实测*（全部为只读探测，2026-09-14）：`typst 0.15.1`；`python3 3.14.6`（有 `numpy 2.5.2`，*没有* `mpmath`、`sympy`、`python-flint`、`gmpy2`、`scipy`）；`julia 1.12.6`（`~/.julia/packages` 下 92 个包，*没有* IntervalArithmetic.jl / TaylorModels.jl / ArbNumerics.jl）；`lean` + `lake`（`~/.elan` 里 v4.32.2 与 v4.33.0-rc1 两个 toolchain，*没有* mathlib 检出）；`gcc 16.2.1`，且 `ldconfig -p` 与 `/usr/include` 显示 `libmpfr.so.6`、`libgmp.so.10`、`mpfr.h`、`gmp.h` 齐备，但*没有* `libflint`、`libmpfi`。这三条约束（Python 零严格数值库、Julia 零区间库、MPFR 的 C 开发文件可用）贯穿本节所有落地建议。

=== (a) 区间/球算术库：五个候选的事实对照

#table(columns: 3,
  [*库*], [*数值模型与严格性口径*], [*关键事实（`一手事实`，含来源）*],
  [`Arb`（FLINT 3 的 `arb` / `acb`）], [中点-半径*球算术*：每个量是「中点 ± 半径」，结果是保证包含真值的球；精度任意，可调], [FLINT 3（2023 年发布）把原先独立开发的 Arb、Antic、Calcium、Generic-Rings 四个库并入主干，官方 README 原文即此表述。见 #link("https://raw.githubusercontent.com/flintlib/flint/main/README.md")[FLINT README]],
  [`python-flint`], [同上，Cython 绑定；`flint.arb` 实、`flint.acb` 复], [最新 0.9.0 发布 2026-07-03；要求 FLINT ≥ 3.0，0.10.0 起要求 ≥ 3.4。README 自述特点是 "Real and complex numbers with rigorous error tracking"。见 #link("https://github.com/flintlib/python-flint")[仓库 README]],
  [`MPFR`], [任意精度的*点*值浮点，本身不是区间；定位是「带正确舍入的语义明确的基础库」], [官方自述 "multiple-precision floating-point computations with correct rounding"；舍入模式可逐次指定：`MPFR_RNDN` / `MPFR_RNDD`（向 $-infinity$）/ `MPFR_RNDU`（向 $+infinity$）/ `MPFR_RNDZ` / `MPFR_RNDA` / `MPFR_RNDF`（faithful，标注为实验性）。官网同时点名基于它的区间库 MPFI。见 #link("https://www.mpfr.org/mpfr-current/mpfr.html")[MPFR 手册] 与 #link("https://www.mpfr.org/")[MPFR 官网]],
  [`mpmath` 的 `iv` 上下文], [闭区间 `iv.mpf` 与矩形复区间 `iv.mpc`；端点任意精度], [文档自己给的定位是负面的：区间支持 "still experimental, and many functions do not yet properly support intervals"；并且 "iv arithmetic is typically at least two times slower than mp arithmetic"，还会 "sometimes provide far too pessimistic bounds"。见 #link("https://mpmath.readthedocs.io/en/latest/contexts.html")[mpmath contexts 文档]],
  [`IntervalArithmetic.jl`], [IEEE 1788-2015 区间；`Interval{T}` / `BareInterval{T}`，$T$ 限制为 `Rational` 或 `AbstractFloat`], [README 自述 "validated numerics ... the final result is a rigorous enclosure of the true value"，并声明符合 IEEE 1788-2015；要求 Julia ≥ 1.10。见 #link("https://github.com/JuliaIntervals/IntervalArithmetic.jl")[仓库] 与 #link("https://juliaintervals.github.io/IntervalArithmetic.jl/stable/")[官方文档]],
)

*几个决定选型的细节*（`一手事实`）：

- *Arb 的球：中点精度可调、半径精度有上限*：`python-flint` 文档写明「半径使用固定、由实现决定精度的浮点数」，而中点精度由 `ctx.prec`（二进制位）或 `ctx.dps`（十进制位）控制；半径非零时可能被向上取整到略大的值。文档还明确警告 "The error indicated in the output may be much larger than the actual error"——*打印出来的半径不等于内部误差*，所以不能用打印宽度做收敛判据。
- *Arb 的十进制往返会放大区间*：文档原文 "Binary-decimal-binary roundtrips may result in significantly larger intervals, and should therefore be done sparingly"。构造器接受整数、浮点、有理数字符串、十进制字符串、以及表示精确浮点数据 $a dot 2^b$ 的二元组，所以*能用字符串就别用 Python `float`*。
- *Julia 侧把「不可信来源」显式标出来*：`interval(x)` 构造的区间 `isguaranteed(x) == true`；而经由 `convert(Interval, ::Real)` 隐式转换出来的会带 "NG"（not guaranteed）标签，文档用 `!!! danger` 提醒「关注 validated numerics 的人必须追查 NG 标签的来源」。另有一个 `@exact` / `ExactReal` 机制，用来标记「用户手打的字面量」以求精确。
- *Julia 侧初级函数的分工很值得抄*：`Interval{Float64}` 的 `exp`、`expm1`、`log`、`log1p`、`log2`、`log10`、`sin`、`cos`、`tan`、`asin`、`acos`、`atan`、`sinh`、`cosh` 走正确舍入的 CRlibm 例程；而 `^`、`exp2`、`exp10`、`atan`、`atanh` 会内部转到 `BigFloat`（MPFR）再算，文档明说求 `^` 的正确舍入会带来「significant slow-down」。
- *幂函数三个名字语义不同*：`pown(x, n)`（整数幂）、`pow(x, y)` 定义为 $exp(y ln x)$ 所以*负数部分被丢弃*、`rootn(x, n)`；`^` 在指数是整数时退到 `pown`，否则退到 `pow`。`Arb` 侧则在定义域外直接报错——`python-flint` 里对负数求 `sqrt` 抛的是 `ValueError: no convergence`，这类「定义域错误伪装成收敛失败」的报错方式必须在工具层归一化。

来源：#link("https://python-flint.readthedocs.io/en/latest/arb.html")[python-flint arb]、#link("https://github.com/flintlib/python-flint")[python-flint README]、#link("https://raw.githubusercontent.com/flintlib/flint/main/README.md")[FLINT README]、#link("https://mpmath.readthedocs.io/en/latest/contexts.html")[mpmath contexts]、#link("https://www.mpfr.org/")[MPFR]、#link("https://github.com/JuliaIntervals/IntervalArithmetic.jl")[IntervalArithmetic.jl]、#link("https://github.com/JuliaIntervals/IntervalArithmetic.jl/blob/master/docs/src/manual/guarantee.md")[guarantee]、#link("https://github.com/JuliaIntervals/IntervalArithmetic.jl/blob/master/docs/src/manual/usage.md")[usage]。

=== (b) 把浮点实验结果升级成严格上/下界

*先分清两件不同的事*（`推断`）：区间/球算术只能把「已经写对的那个表达式」包起来，它不证明这个表达式*就是你猜想里的那个量*。所以流程必须切成两半——数学归约（由人 + Lean 负责，说明「若 $x in [a,b]$ 则猜想在参数 $T$ 成立」）与数值包围（由机器负责，产出 $[a,b]$ 及依赖它的每一步）。任何把两者混在一个 Python 脚本里的做法都会退化成「相信我的代码」。

*三层升级流程*（`推断`，API 均为 `一手事实`）：

1. *第 0 层：`float` 只用来找线索*。`math.nextafter(x, math.inf)` / `math.nextafter(x, -inf)`（文档明确 "goes up / goes down"）与 `math.ulp(x)` 是把一个双精度结果手工向外推开一格的工具；这一层只用于快速筛选参数区间，不产出任何可引用结论。`math.fsum` 的文档措辞也值得照抄到自己的误差说明里：它是 "an accurate floating-point sum"，并且「精度依赖 IEEE-754 保证以及通常意义上的 half-even 舍入」，在个别平台上还可能因扩展精度二次舍入而在最低位出错——所以*连它也不是天然正确舍入*。
2. *第 1 层：全程用球算术重算*。把第 0 层里「看起来成立」的每个不等式，用不同精度（例如 `ctx.dps` 取 30 / 60 / 120）各算一遍；只要任一次得到方向不同的结论，就说明误差预算不够。文档给出的著名例子是 Ramanujan 常数：用 `mpmath.mp` 在 `mp.dps = 25` 下比较 $e^(pi sqrt(163))$ 与 $640320^3+744$ 会得到*错误*的大小关系（判为 `>`，真值为 `<`），只有到 `mp.dps = 50` 才显示出真实差值是 `262537412640768743.99999999999925007…`；换成 `iv` 上下文后，比较在 `dps = 15` 与 `dps = 30` 都直接抛 `ValueError`，直到 `dps = 60` 才给出确定的 `False`。
3. *第 2 层：把包围盒落成精确有理数*。这一步是「可证明界限」的物理载体。`Arb` 的端点本身就是形如 $m dot 2^e$ 的二进有理数，所以能无损转成 Python 的 `Fraction`：

```python
from flint import arb, ctx
from fractions import Fraction

ctx.dps = 40                       # 球的中点精度；ctx.prec 是等价的二进制位表示
x = arb("0.1").sin()               # 球算术：x 是一整个球，保证包含真值
lo, hi = x.lower(), x.upper()      # 按 -inf / +inf 方向舍入得到的精确浮点端点

def dyadic(v):
    assert v.is_exact()            # man_exp() 要求精确且有限，否则抛 ValueError
    m, e = int(v.man_exp()[0]), int(v.man_exp()[1])
    return Fraction(m * 2**e) if e >= 0 else Fraction(m, 2**-e)

a, b = dyadic(lo), dyadic(hi)      # a <= sin(0.1) <= b，且 a、b 是精确有理数
```

`python-flint` 为这件事准备了一整套读数接口（均为 `一手事实`）：`lower()` / `upper()` 给出方向化端点；`mid()` / `rad()` 取中点与半径；`abs_lower()` / `abs_upper()` 取 $|x|$ 的下界与上界（文档示例：`arb("-5 +/- 2").abs_lower()` 得 $3$）；`contains()` / `contains_interior()` 判断包含；`unique_fmpz()` 在某球只含一个整数时直接把它取出来（用于「某个计数等于 $N$」的判定）；`rel_accuracy_bits()` 与 `rel_one_accuracy_bits()` 给出有效位数；`mid_rad_10exp(n)` 直接给出一个十进制三元组（中点、半径、指数），使真值落在按 $10$ 的幂展开的对应区间里。

- *积分也有严格版本*：`python-flint` 的 README 直接给了 `acb.integral(lambda x, _: (-x**2).exp(), -100, 100) ** 2` 得到 `[3.141592653589793238462643383 +/- 3.11e-28]` 的例子——即 $pi^2$ 的严格包围。凡是要「对连续量积分再比较」的猜想（谱、能量、范数、矩），这条路径比事后误差分析可靠得多。
- *零点/根的存在性有专用封装*：`IntervalRootFinding.jl` 的 `roots(f, -10 .. 10)`（`..` 来自 `IntervalArithmetic.Symbols`）返回 `Root{Interval{Float64}}` 列表，每个根带 `:unique`（该区间内*恰有一个*根）或 `:unknown`（可能 0、1 或多个根）状态；README 明确 "The `:unique` status indicates that each listed interval contains exactly one root"。注意输出里形如 `[-4.42654, -4.42653]_com_NG` 的装饰，`NG` 正是上文那个「不可信来源」标签。
- *浮点程序本身的舍入误差有专门工具*：Gappa 的官网自述是「帮助验证并形式化证明处理浮点或定点算术的数值程序的性质」，可以「作为 Why3 验证平台的后端证明器，或作为 Rocq 证明助手的自动 tactic」。也就是说，如果猜想的实验部分是一段 C/Fortran 浮点代码，可以用 Gappa 直接把「这段代码的计算结果与实数结果之差 ≤ …」变成一个可在证明助手里检验的命题，而不必手写误差分析。

来源：#link("https://docs.python.org/3/library/math.html")[Python math]、#link("https://mpmath.readthedocs.io/en/latest/contexts.html")[mpmath contexts]、#link("https://python-flint.readthedocs.io/en/latest/arb.html")[python-flint arb]、#link("https://github.com/JuliaIntervals/IntervalRootFinding.jl")[IntervalRootFinding.jl]、#link("https://gappa.gitlabpages.inria.fr/")[Gappa]。

=== (c) 有理数与代数数的精确算术

*要点：先问「这个数本该是精确的吗」*（`推断`）。凡是猜想里出现的整数、计数、组合数、代数数，都不该走浮点通道再补救；下面的层次按「精确性强度」从低到高排列。

- *Python 标准库的 `fractions.Fraction`*（`一手事实`）：任意有理数的精确运算，`Fraction('3/7')`、`Fraction('-3/7')`、`Fraction('7e-6')` 都能从字符串精确构造；`numbers.Rational` 的抽象方法全部实现。Python 3.14（正是本机版本）新增 `Fraction.from_number`，并可接受任何带 `as_integer_ratio()` 的对象。
- *`Fraction` 的两个经典坑*（`一手事实`，文档原文即给出这两个例子）：`Fraction(1.1)` 得到 `2476979795053773/2251799813685248`（因为 1.1 这个双精度字面量本来就不是 11/10），而 `Fraction(cos(pi/3))` 得到 `4503599627370497/9007199254740992`，只有配合 `limit_denominator()` 才回到 `1/2`。结论：*从浮点进 `Fraction` 是保留误差，不是消除误差*；要精确就得用字符串或 `Decimal`。
- *`decimal.Decimal`*（`一手事实`）：模块设计围绕「数、上下文、信号」三个概念，`getcontext().prec` 控制有效位；文档明确它可以「用异常拦下任何不精确的操作」从而做精确算术。适用于「用十进制叙述的界」（如 $3.14159 <= pi$）直接落成精确值。
- *`SymPy` 的代数数层*（`一手事实`）：`sympy.polys.numberfields` 以「域 + 极小多项式」为模型，任务表列出 `minimal_polynomial`、`isolate`、`field_isomorphism`、`primitive_element`、`galois_group`、`prime_decomp`、`round_two`（后者接受 `AlgebraicField` 作为输入）。其中 `isolate` 直接返回*有理隔离区间*：文档示例 `isolate(sqrt(2))` 得 `(1, 2)`，`isolate(sqrt(2), eps=Rational(1,100))` 得 `(24/17, 17/12)`——这正是「代数数 → 有理端点」的桥梁。
- *FLINT 的精确类型与它的实验性扩展口*（`一手事实`）：`python-flint` 提供 `fmpz`、`fmpq`（含精确线性代数，README 示例 `fmpq_mat.hilbert(10,10).det()` 返回一个精确分数），以及模 $n$、有限域等类型。0.7.0 的 changelog 说明新增了 FLINT 泛型环 `gr` 的*实验性*接口，从而「可以触达许多尚未被单独包装的 FLINT 类型，例如 Gaussian integer、number fields、`qqbar`、`calcium`」。本节能验证的只是这个接口与这些类型名存在；它们的 API 细节、稳定性与性能 `UNVERIFIED`，插件里若要使用必须先做一次探测性导入。

来源：#link("https://docs.python.org/3/library/fractions.html")[Python fractions]、#link("https://docs.python.org/3/library/decimal.html")[Python decimal]、#link("https://docs.sympy.org/latest/modules/polys/numberfields.html")[SymPy numberfields]、#link("https://github.com/flintlib/python-flint")[python-flint README/CHANGELOG]。

=== (d) 舍入误差与病态问题的陷阱清单

这一节按「会静默给出错误结论」排序，前三条最危险，因为它们都不报错。

- *依赖问题（dependency problem）*（`一手事实`）：区间算术对同一个变量的多次出现不做关联，`X - X` 不等于 `{0}`。Julia 文档原文："Due to the above definition, subtraction of two intervals may give poor enclosures"，并直接以 `X - X` 为例。`推断`：凡是表达式中同一个量出现两次以上的（几乎所有病态问题都是这个形状），朴素区间会立刻把界吹爆，必须先做代数化简、均值形式或改用 Taylor 模型。
- *Taylor 模型才是「非线性 + 多出现」的正解*（`一手事实`）：`TaylorModels.jl` 自述把 `IntervalArithmetic.jl` 与 `TaylorSeries.jl` 结合，提供「带保证误差界的 Taylor 多项式」来逼近函数。也就是说误差项是显式的、可加进证明里的。
- *`mpmath` 的方向舍入只在算术上可靠*（`一手事实`）：其 README 的 Known problems 一节原文——"Directed rounding works for arithmetic operations. It is implemented heuristically for other operations, and their results may be off by one or two units in the last place (even if otherwise accurate)." 同一节还列出「大参数或逼近奇点附近可能返回错误值」「接口未定型、非线程安全」。任何基于 `iv` 的特殊函数严格界都必须叠加自证（或换 Arb）。
- *把 Python `float` 当成精确输入*（`一手事实`）：`iv.mpf(0.1)` 得到的是宽度为零的 `[0.10000000000000000555, 0.10000000000000000555]`（文档注释就写着 "probably not intended"），而 `iv.mpf('0.1')` 才得到包含真值的 `[0.099999999999999991673, 0.10000000000000000555]`。同一节的结论句值得抄进代码规范：「二进制浮点在任何精度下都无法精确表示 1/10」。
- *比较是三值逻辑，`if` 会炸*（`一手事实`）：`iv.mpf([1,2]) < 2` 抛 `ValueError`（不确定），而 `<=`、`>` 在能确定时返回布尔。Julia 侧同样如此，文档明说 "`if ... else ... end` statements used for floating-points will often break with intervals"，因此提供了 `Piecewise` 与 `Domain` 来写分段函数。`推断`：本插件里所有「用区间做条件分支」的代码都应当改成显式的三态返回值。
- *十进制↔二进制往返会放大区间*（`一手事实`）：见 (a) 中 `Arb` 的 `str()` 警告；文档还给了反直觉的例子——设 `more=True` 反而*打印出更小的半径*，因为十进制转换本身的误差减小了。
- *诊断工具要用对*：`arb.rel_accuracy_bits()` 判断「这个球到底有没有信息」，`arb.is_exact()` 区分精确值与近似值，`unique_fmpz()` 判断「某球是否只含一个整数」。`推断`：插件应把这三者做成硬性断言，凡是「半径没到目标位宽就继续算」的循环必须写成循环条件，而不是靠人眼看打印结果。

来源：#link("https://github.com/JuliaIntervals/IntervalArithmetic.jl/blob/master/docs/src/manual/usage.md")[IntervalArithmetic usage]、#link("https://github.com/JuliaIntervals/TaylorModels.jl")[TaylorModels.jl]、#link("https://github.com/mpmath/mpmath")[mpmath README]、#link("https://mpmath.readthedocs.io/en/latest/contexts.html")[mpmath contexts]、#link("https://python-flint.readthedocs.io/en/latest/arb.html")[python-flint arb]。

=== (e) 与 Lean 的 `norm_num` / `interval_cases` 联动

*先看这几个 tactic 的真实能力边界*（`一手事实`，取自 mathlib 源码与文档）：

- `norm_num` 的定位是「在目标里正规化数值表达式」，默认支持 `+` `-` `*` `/` `⁻¹` `^` `%`，作用于至少带 `AddMonoidWithOne` 的类型（文档点名 `ℕ`、`ℤ`、`ℚ`、`ℝ`、`ℂ`）；目标形如 $A = B$、$A != B$、$A < B$、$A <= B$ 且两侧都是数值表达式时它会尝试直接关闭。文档给的可运行例子是 `example : 43 ≤ 74 + (33 : ℤ) := by norm_num` 与 `example : ¬ (7-2)/(2*3) ≥ (1:ℝ) + 2/(3^2) := by norm_num`。它有 `norm_num1`（不调用 `simp` 的裸版本）、`norm_num only`、`norm_num at l` 与 `conv` 形态。
- *扩展点是公开且低门槛的*：`@[norm_num e]` 属性注册一个 `NormNumExt`，`e` 里可以留洞（文档示例 `@[norm_num _ + _]` 匹配任意加法）；mathlib 自己的 `Mathlib/Tactic/NormNum/` 目录下就有近三十个插件文件（`Abs`、`BigOperators`、`DivMod`、`Eq`、`GCD`、`Ineq`、`Inv`、`Irrational`、`IsSquare`、`LegendreSymbol`、`ModEq`、`NatFactorial`、`NatFib`、`NatLog`、`NatSqrt`、`OfScientific`、`Parity`、`Pow`、`PowMod`、`Prime`、`RealSqrt`、`Result` …）。
- *`Real.sqrt` 的插件只认完全平方*（`一手事实`）：`RealSqrt.lean`（2025 年，作者 Frédéric Dupuis）里 `evalRealSqrt` 对有理输入只在其分子分母分别是完全平方时返回结果，否则 `unless y * y = x do failure`。`推断`：所以 `1.41 < √2` 这类*无理数的有理界*不是 `norm_num` 一步能关的，要么手写引理链（把双方平方后归约到有理数比较），要么把「界」写成假设引进来。
- *`interval_cases` 只做整数*（`一手事实`）：文档明说目前 `n` 必须是 `ℕ` 或 `ℤ` 这两个类型之一，推广到其他类型在其源码注释里被标为尚未完成。它会扫描上下文里形如 $a <= n$、$a < n$、$n < b$、$n <= b$ 的假设（`ℕ` 时自动补上 $0 <= n$），合成形如 `n ∈ Set.Ico a b` 的假设再调 `fin_cases`，于是每个整数值给一个目标。文档示例：`example (n : ℕ) (w₁ : n ≥ 3) (w₂ : n < 5) : n = 3 ∨ n = 4 := by interval_cases n; all_goals simp`；也支持显式给界 `interval_cases using hl hu`。
- *`bound` 是「不等式版 `norm_num`」*（`一手事实`）：文档说 `bound` 是把 `positivity` 与 `gcongr` 的功能合起来、可以在 $0 <= x$ 与 $x <= y$ 两类目标间来回跳的 aesop 包装，且*用 `norm_num` 与 `linarith` 关闭数值子目标*。它允许额外假设 `bound [h₀, h₁ n, ...]`，并支持 `calc` 分步。

*联动方案*（`推断`，基于上面这些能力边界）：

1. *Python 只输出精确有理数，不输出「结论」*。由 (b) 的 `dyadic()` 得到 $a <= theta <= b$，且 $a,b$ 都是有理数；证书文件里同时记下 `ctx.dps`、`arb` 的版本、以及每一步的半径，便于复算。
2. *Lean 侧先立引理、再喂有理数*。由人写一条一般性引理（例如「若 $x in [a,b]$ 则 $P(x)$」），具体数值只作为 `norm_num` 的对象出现。关键是 Lean 里的十进制字面量*就是精确有理数*：`OfScientific` 插件会把 `OfScientific.ofScientific m true e` 正规化成 `NNRat.divNat m (10 ^ e)`，所以 `(0.1 : ℝ)` 是精确的 $1/10$ 而不是 Python 那个双精度 0.1——这一点让 Arb 的十进制输出可以近乎逐字搬进 Lean。
3. *整数型目标交给 `interval_cases`*。若猜想是「对区间 $[N_1, N_2]$ 内的每个整数都成立」，最终形态就是 `interval_cases n` 加 `all_goals norm_num`；若原始变量是实数，先把它转成整数索引再交给这个 tactic。
4. *需要「只信核」的时候避开 `native_decide`*。Lean 核心 `Lean/Meta/Native.lean` 的文档说明：该机制取回编译执行得到的布尔值、检查它是否为真，然后*向逻辑里新增一条断言该表达式成立的公理*并返回它，并自述「它是 `native_decide` 与 `bv_decide` 的基础」。也就是说 `native_decide` 的可信度落在编译器和运行环境上，而 `norm_num` 产出的是核可检验的证明项。对「给开放问题存档的界」这种要长期站得住的结论，应当优先用 `norm_num` / `linarith` / `bound` 这类路径。
5. *若实验部分本来就是浮点程序*，用 (b) 提到的 Gappa 把舍入误差命题化，再由 Rocq/Why3 侧检验；这条路径与 mathlib 是两条独立轨道，不要混在一个证明文件里。

*示意（未在本机编译验证：本机 `~/.elan` 有 toolchain 但没有 mathlib 检出，下列片段仅表达接口形状）*：

```lean
-- 前两例逐字取自 mathlib tactic 文档（一手，可直接抄用）
example : 43 ≤ 74 + (33 : ℤ) := by norm_num
example (n : ℕ) (w₁ : n ≥ 3) (w₂ : n < 5) : n = 3 ∨ n = 4 := by
  interval_cases n
  all_goals simp

-- 示意：把 Arb 给出的精确有理端点作为假设引入，剩下的交给数值与线性算术 tactic
example (x : ℝ) (hlo : (1414 / 1000 : ℝ) ≤ x) (hhi : x ≤ 1415 / 1000) : 0 < x := by
  linarith
```

来源：#link("https://raw.githubusercontent.com/leanprover-community/mathlib4/master/Mathlib/Tactic/NormNum/Core.lean")[NormNum/Core.lean]、#link("https://raw.githubusercontent.com/leanprover-community/mathlib4/master/Mathlib/Tactic/NormNum/RealSqrt.lean")[NormNum/RealSqrt.lean]、#link("https://raw.githubusercontent.com/leanprover-community/mathlib4/master/Mathlib/Tactic/NormNum/OfScientific.lean")[NormNum/OfScientific.lean]、#link("https://leanprover-community.github.io/mathlib4_docs/Mathlib/Tactic/IntervalCases.html")[IntervalCases 文档]、#link("https://leanprover-community.github.io/mathlib4_docs/Mathlib/Tactic/Bound.html")[Bound 文档]、#link("https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Meta/Native.lean")[Lean/Meta/Native.lean]。

*一个待验证的空白*：本节没能核实 mathlib 是否存在 `Real.pi_gt_*` 一类「常数的有理界」引理的具体名字（在 `Mathlib/Analysis/SpecialFunctions/Trigonometric/Basic.lean` 里只搜到 `pi_le_four`，且仓库内不存在 `Mathlib/Analysis/SpecialFunctions/Pi/` 目录）。`UNVERIFIED`：这类引理的确切命名与可用性，落地前须在 mathlib 检出里直接 `exact?` 或全文检索确认。

=== (f) 用数值严格化证明猜想特例的公开案例

#table(columns: 2,
  [*案例*], [*做了什么、用了什么*],
  [Lorenz 吸引子 / Smale 第 14 问题（Tucker）], [2002 年用自建的严格 ODE 求解器证明 Lorenz 系统的混沌性，是「区间算术 + 分支定界 + 计算机辅助证明」的范式案例。见 #link("https://doi.org/10.1007/s002080010018")[DOI 10.1007/s002080010018]],
  [同一计算被证明助手复核（Immler）], [用 Isabelle/HOL *形式化验证*一个严格的数值算法，去认证 Tucker 当年证混沌用的那些计算；摘要自述形式化的内容包括 ODE 与 Poincaré 映射，算法包括基于 Runge–Kutta 的低层近似与*仿射算术*，高层含可达性分析、静态杂交与自适应步长/分裂。见 #link("https://doi.org/10.1007/s10817-017-9448-y")[DOI 10.1007/s10817-017-9448-y]],
  [Riemann 假设验证到高度 $3 dot 10^12$（Platt & Trudgian）], [摘要原文即写明「we verify numerically, in a rigorous way using interval arithmetic」——即该高度以下的零点全部落在临界线上。这是「区间算术直接把一个公开的验证纪录往前推」的最干净案例。见 #link("https://doi.org/10.1112/blms.12460")[DOI 10.1112/blms.12460]],
  [Collatz 收敛性验证到 $2^71$（Barina, 2025）], [摘要说明文章先给基线算法再叠加若干加速子算法，最终把验证上界推到 $2^71$。这是*计算密集型验证*（不是区间算术）的代表，说明「反例搜索 / 有限验证」这条线需要的是工程吞吐而非数值严格性。见 #link("https://doi.org/10.1007/s11227-025-07337-0")[DOI 10.1007/s11227-025-07337-0]],
  [三素数 Goldbach 的数值验证到 8.875·10^30（Helfgott）], [把解析证明中「剩下的有限部分」交给数值验证，该文标题即 "Numerical Verification of the Ternary Goldbach Conjecture up to 8.875·10^30"。见 #link("https://doi.org/10.1080/10586458.2013.831742")[DOI 10.1080/10586458.2013.831742]],
  [Brusselator 系统周期轨道存在性], [计算机辅助证明，摘要自述其证明「rooted in the rigorous integration of partial differential equations」，即把严格积分做到了 PDE 上，并给出周期倍化分岔的证据。见 #link("https://doi.org/10.57262/ade029-1112-815")[DOI 10.57262/ade029-1112-815]],
  [Kepler 猜想形式化证明中的外部工具], [#link("https://doi.org/10.29007/2l48")[DOI 10.29007/2l48]（Hales，External Tools for the Formal Proof of the Kepler Conjecture）——大型形式化证明对「外部数值工具」的依赖与账目，正是本项目要预先设计的东西],
  [Ramanujan 常数的精度陷阱（mpmath 文档自带）], [如 (b) 所述：$e^(pi sqrt(163))$ 与 $640320^3+744$ 的大小关系在 `mp.dps = 25` 下会被判错，必须提高到 `mp.dps = 50`；用 `iv` 上下文则在精度不足时直接抛 `ValueError` 而不给答案。见 #link("https://mpmath.readthedocs.io/en/latest/contexts.html")[mpmath contexts]],
)

来源：#link("https://doi.org/10.1007/s002080010018")[Tucker 2002]、#link("https://doi.org/10.1007/s10817-017-9448-y")[Immler 2018]、#link("https://doi.org/10.1112/blms.12460")[Platt–Trudgian]、#link("https://doi.org/10.1007/s11227-025-07337-0")[Barina 2025]、#link("https://doi.org/10.1080/10586458.2013.831742")[Helfgott 2013]、#link("https://doi.org/10.57262/ade029-1112-815")[Brusselator]、#link("https://mpmath.readthedocs.io/en/latest/contexts.html")[mpmath contexts]。

=== 评估

- *抄「球算术产出精确二进有理端点 → 落成 `Fraction` → 当假设喂进 Lean」这条链路，而不是抄任何单一库*：`Arb` 的端点天然是 $m dot 2^e$，`man_exp()` 能无损取出，`Fraction` 能精确承载，Lean 侧的十进制字面量经 `OfScientific` 也是精确有理数（`(0.1 : ℝ)` 就是 $1/10$）。这四段拼起来才是「可证明界限」，任何一段换成 `float` 都会静默失效。
- *抄 `IntervalArithmetic.jl` 的 guaranteed / "NG" 标签设计，把「不可信来源」做成类型级标记*：它的规则是 `interval(x)` 可信、隐式 `convert` 出来的带 `NG` 且文档要求使用者追查来源。本插件的 MCP 工具返回值应当照此带上 `provenance` 字段（区间怎么来的、哪一步是隐式转换），并在打印时把它显示出来。
- *该避免用 `mpmath.iv` 作为严格性的主力*：它的官方 Known problems 白纸黑字写着方向舍入只对算术运算可靠，其他运算「按启发式实现、可能差一两个 ulp」，且区间支持仍被自己标为 experimental。可以拿它做快速筛选，但凡是要写进结论的界必须换 Arb 或 Julia 的区间算术，并在文档里注明这一分工。
- *该避免让 Python 侧输出「结论」而非「区间 + 元数据」*：半径精度有固定上限、十进制往返还会放大区间、定义域错误伪装成 `ValueError: no convergence`——这些都说明 Python 侧只适合产出可复算的原始包围盒（含 `ctx.dps`、库版本、每步半径），判断「界够不够」这件事必须由确定的规则（`rel_accuracy_bits()` 阈值、多次不同精度一致性、必要时换 `ctx.dps` 重算）自动做，不能靠人读打印值。
- *抄 `@[norm_num]` 与 `@[bound]` 两个扩展点，把它们当成插件与证明助手之间的正式接口*：mathlib 的 `norm_num` 插件目录本身就是近三十个文件的样板，表达式里留洞即可匹配；`bound` 又会在收尾时调用 `norm_num` 和 `linarith`。给本项目定制的「证书算术」正规化器应当做成一个 `norm_num` 插件，而不是生成一大段手工证明脚本。
- *该避免把 `native_decide` 当作长期结论的证明手段*：Lean 核心 `Lean/Meta/Native.lean` 的文档自述该机制会向逻辑*新增一条断言公理*，`native_decide` 与 `bv_decide` 都建立在它之上；其可信度落在编译器与运行环境。要给开放问题存档的界，应走 `norm_num` / `linarith` / `bound` 这类产出核可检验证明项的路径。

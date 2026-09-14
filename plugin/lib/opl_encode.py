"""opl_encode —— 把有限域约束规格编码成 CNF 与 CP-SAT 两种模型。

两种编码*独立实现*：一个手写 CNF（one-hot 变量 + 作用域元组枚举），一个用
ortools CP-SAT 的建模 API。它们存在的意义是互相证伪——编码错误是这类研究里
最难发现的一类错（求解器说 UNSAT，你以为是定理，其实是编码把解排掉了），
而两条独立路径不一致是它最便宜的信号。

本模块不做 I/O：解析与求值在 `opl_spec`，命令壳在 `bin/opl-encode`。这样它
可 import、可单测、可被类型检查——而 `bin/` 里那些无扩展名的可执行文件是
类型检查的盲区。
"""

from __future__ import annotations

import importlib
import itertools
from dataclasses import dataclass, field
from typing import Any

from opl_spec import Constraint, Spec, Var

# 编码代价闸门。超过就拒绝编码并报 USAGE，*不静默降级*——一个悄悄截断的编码
# 会让「范围内无反例」这种结论变得毫无意义。
DEFAULT_MAX_TUPLES = 200_000
DEFAULT_MAX_CLAUSES = 2_000_000


class EncodeError(Exception):
    """编码被拒绝或无法进行。调用方应翻成 USAGE（退出码 2）。"""


class SolverMissing(Exception):
    """所需求解器库不可用。调用方应翻成 MISSING（退出码 4）。"""


def _optional(module: str) -> Any:
    """导入一个*运行时可选*的后端库。

    用 importlib 而不是 import 语句，是因为这些库只装在项目 venv 里，而类型
    检查器跑在系统解释器下——直接 `import pysat.solvers` 会让它报 unresolvable，
    逼我们去加 `# type: ignore`。与其在代码里塞免罪符，不如把「这是运行时可选
    依赖」这件事本身写出来。返回 Any 也是诚实的：本来就拿不到这些库的类型信息。

    缺库时抛 SolverMissing，由命令壳翻成退出码 4；绝不回退到估算。
    """
    try:
        return importlib.import_module(module)
    except ImportError as exc:
        raise SolverMissing(f"缺少 {module}：{exc}") from exc


# --------------------------------------------------------------------- CNF 侧


@dataclass
class Cnf:
    """DIMACS CNF 加上反向映射所需的信息。"""

    clauses: list[list[int]] = field(default_factory=list)
    # (变量名, 取值) -> DIMACS 正文字（1 起）
    lit_of: dict[tuple[str, int], int] = field(default_factory=dict)
    nvars: int = 0
    tuples_visited: int = 0

    def to_dimacs(self) -> str:
        head = f"p cnf {self.nvars} {len(self.clauses)}"
        body = "\n".join(" ".join(map(str, c)) + " 0" for c in self.clauses)
        return head + "\n" + (body + "\n" if body else "")

    def decode(self, model: list[int]) -> dict[str, int]:
        """把求解器给的文字集合还原成整数赋值。

        每个变量恰好一个 one-hot 文字为真；一个都没真说明模型不完整 —— 那种
        情况必须报错而不是猜一个值出来。
        """
        truth = {lit for lit in model if lit > 0}
        out: dict[str, int] = {}
        for (name, value), lit in self.lit_of.items():
            if lit in truth:
                if name in out:
                    raise EncodeError(f"模型里 {name} 有两个真文字，one-hot 被破坏")
                out[name] = value
        return out


def to_cnf(spec: Spec, *, max_tuples: int = DEFAULT_MAX_TUPLES,
           max_clauses: int = DEFAULT_MAX_CLAUSES) -> Cnf:
    """把规格编码成 CNF。

    变量用 one-hot：整数变量 v ∈ [lo,hi] 展开成 (hi-lo+1) 个布尔文字，并加
    恰一约束。代价是变量数变多，好处是 alldiff 与线性约束都能用*局部*子句
    精确表达，不需要算术电路。
    """
    cnf = Cnf()
    nxt = 0
    for v in spec.variables:
        for value in v.values():
            nxt += 1
            cnf.lit_of[(v.name, value)] = nxt
    cnf.nvars = nxt

    for v in spec.variables:
        _add_exactly_one(cnf, v)

    for c in spec.constraints:
        # 先算代价再动手：宁可拒绝，也不要产出一个大到没法验的编码。
        cost = c.tuple_count
        if cost > max_tuples:
            raise EncodeError(
                f"约束 {_describe(c)} 的作用域有 {cost} 种赋值组合，超过上限 "
                f"{max_tuples}。这道闸门是故意的：静默产出一个巨型编码，"
                f"会让之后的『范围内无反例』无法验证。缩小定义域或换后端。")
        if c.kind == "alldiff":
            _add_alldiff(cnf, c)
        elif c.kind == "linear":
            _add_linear(cnf, c)
        else:
            raise EncodeError(f"未知约束类型：{c.kind}")

        if len(cnf.clauses) > max_clauses:
            raise EncodeError(
                f"子句数已超过上限 {max_clauses}（当前 {len(cnf.clauses)}），拒绝继续编码")
    return cnf


def _add_exactly_one(cnf: Cnf, v: Var) -> None:
    lits = [cnf.lit_of[(v.name, value)] for value in v.values()]
    if v.size == 1:
        cnf.clauses.append([lits[0]])
        return
    cnf.clauses.append(list(lits))                     # 至少一个
    for a, b in itertools.combinations(lits, 2):        # 至多一个
        cnf.clauses.append([-a, -b])


def _add_alldiff(cnf: Cnf, c: Constraint) -> None:
    """两两不同：对每一对变量、每一个共同取值，禁止两者同时取该值。"""
    for x, y in itertools.combinations(c.scope, 2):
        xs = {value for (n, value) in cnf.lit_of if n == x}
        ys = {value for (n, value) in cnf.lit_of if n == y}
        for value in sorted(xs & ys):
            cnf.clauses.append([-cnf.lit_of[(x, value)], -cnf.lit_of[(y, value)]])


def _add_linear(cnf: Cnf, c: Constraint) -> None:
    """线性约束：枚举作用域上的全部赋值，把每一个*违反*的组合作为禁止子句。"""
    assigns = [[(n, value) for value in _domain_of(cnf, n)] for n in c.scope]
    for combo in itertools.product(*assigns):
        cnf.tuples_visited += 1
        if not c.holds(dict(combo)):
            cnf.clauses.append([-cnf.lit_of[pair] for pair in combo])


def _domain_of(cnf: Cnf, name: str) -> list[int]:
    values = [value for (n, value) in cnf.lit_of if n == name]
    if not values:
        raise EncodeError(f"变量 {name} 没有编码进 CNF")
    return sorted(values)


def _describe(c: Constraint) -> str:
    from opl_spec import describe  # 避免重复实现一套措辞
    return describe(c)


# ------------------------------------------------------------------- 求解与 CP


def _resolve_solver(ps: Any, name: str) -> Any:
    """按名字取 PySAT 的求解器类，大小写不敏感。

    PySAT 的类名是 `Glucose42`、`Cadical195`、`Lingeling` 这样的首字母大写形式，
    而命令行习惯写小写。与其让用户记住大小写，不如在这里解析——但*不猜测*：
    找不到就如实报出可用的名字。
    """
    if hasattr(ps, name):
        return getattr(ps, name)
    low = name.lower()
    for attr in dir(ps):
        if attr.lower() == low:
            return getattr(ps, attr)
    return None


def solve_cnf(cnf: Cnf, *, backend: str = "glucose42") -> tuple[str, list[int] | None]:
    """跑 SAT。返回 (sat|unsat|unknown, model)。

    默认 Glucose42：实测它能产出可被 drat-trim / cake_lpr 独立复核的 DRAT。
    不要用 Cadical195 —— 它在 PySAT 里 with_proof=True 时静默返回*空*证明，
    那比报错危险，下游会把「没有证明」当成「证明为空子句」。

    另外 Kissat404 与 Minisat22 在 PySAT 里不支持 proof logging（前者抛
    NotImplementedError），所以出证书的路径上不能用它们。
    """
    ps = _optional("pysat.solvers")
    cls = _resolve_solver(ps, backend)
    if cls is None:
        available = ", ".join(sorted(a for a in dir(ps) if a[0].isupper()))
        raise SolverMissing(f"PySAT 里没有求解器 {backend!r}；可用：{available}")

    with cls(bootstrap_with=cnf.clauses) as solver:
        ok = solver.solve()
        if not ok:
            return "unsat", None
        model = solver.get_model()
        if model is None:
            return "unknown", None
        return "sat", model


def build_cpsat(spec: Spec) -> tuple[Any, dict[str, Any]]:
    """用 ortools CP-SAT 独立建一遍模型。返回 (model, cpvars)。

    这条路径与手写 CNF 完全无关 —— 它直接用 CP-SAT 的约束 API 表达规格，
    因此两条路径不一致就意味着至少有一个编码错了。
    """
    cp_model = _optional("ortools.sat.python.cp_model")
    model = cp_model.CpModel()
    cpvars: dict[str, Any] = {}
    for v in spec.variables:
        cpvars[v.name] = model.NewIntVar(v.lo, v.hi, v.name)
    for c in spec.constraints:
        if c.kind == "alldiff":
            model.AddAllDifferent([cpvars[n] for n in c.scope])
        elif c.kind == "linear":
            terms: list[Any] = [coef * cpvars[n] for coef, n in c.terms]
            expr = sum(terms)
            rhs = c.rhs
            if c.op == "==":
                model.Add(expr == rhs)
            elif c.op == "!=":
                model.Add(expr != rhs)
            elif c.op == "<=":
                model.Add(expr <= rhs)
            elif c.op == ">=":
                model.Add(expr >= rhs)
            elif c.op == "<":
                model.Add(expr < rhs)
            elif c.op == ">":
                model.Add(expr > rhs)
            else:
                raise EncodeError(f"CP 后端不认识 op={c.op!r}")
        else:
            raise EncodeError(f"未知约束类型：{c.kind}")
    return model, cpvars


def solve_cpsat(spec: Spec, *, timeout_s: float = 60.0) -> tuple[str, dict[str, int] | None]:
    """跑 CP-SAT。返回 (sat|unsat|unknown, assignment)。"""
    model, cpvars = build_cpsat(spec)
    cp_model = _optional("ortools.sat.python.cp_model")

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = timeout_s
    status = solver.Solve(model)
    if status in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return "sat", {n: int(solver.Value(v)) for n, v in cpvars.items()}
    if status == cp_model.INFEASIBLE:
        return "unsat", None
    return "unknown", None

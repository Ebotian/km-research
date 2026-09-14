"""opl_spec —— 有限域约束规格的解析与*直接求值*。

这个模块的存在理由是「独立复核」：编码器把规格翻译成 CNF 或 CP 模型，
翻译过程本身可能出错；而见证是否真的成立，只能靠一个与编码器无关的
路径来判断。所以规格的直接求值必须自己实现一遍，不复用任何编码逻辑。

规格是 JSON，形状：

    {
      "name": "pigeonhole-4-3",
      "vars": [{"name": "x0", "lo": 0, "hi": 2}, ...],
      "constraints": [
        {"kind": "linear", "terms": [[1, "x0"], [-1, "x1"]], "op": "!=", "rhs": 0},
        {"kind": "alldiff", "vars": ["x0", "x1", "x2"]}
      ]
    }

支持的 `op`：`==` `!=` `<=` `>=` `<` `>`。

语义约定：规格描述的是「找一个满足全部约束的赋值」。因此
*找到解 = 反例存在*，无解 = 在给定域内不存在反例。
"""

from __future__ import annotations

import itertools
import json
from dataclasses import dataclass, field

OPS = {
    "==": lambda a, b: a == b,
    "!=": lambda a, b: a != b,
    "<=": lambda a, b: a <= b,
    ">=": lambda a, b: a >= b,
    "<": lambda a, b: a < b,
    ">": lambda a, b: a > b,
}


class SpecError(Exception):
    """规格本身有问题。调用方应当报 USAGE（退出码 2），而不是猜。"""


@dataclass(frozen=True)
class Var:
    name: str
    lo: int
    hi: int

    @property
    def size(self) -> int:
        return self.hi - self.lo + 1

    def values(self):
        return range(self.lo, self.hi + 1)


@dataclass
class Constraint:
    kind: str
    scope: tuple[str, ...]
    op: str | None = None
    terms: tuple[tuple[int, str], ...] = ()
    rhs: int = 0

    def holds(self, assign: dict[str, int]) -> bool:
        """直接求值。这是判定见证的唯一权威，与编码器无关。"""
        if self.kind == "alldiff":
            seen = [assign[v] for v in self.scope]
            return len(set(seen)) == len(seen)
        if self.kind == "linear":
            if self.op is None:
                # 类型上可达、逻辑上不该发生：linear 约束必须带 op。
                # 与其让它在 OPS[...] 抛出难懂的 KeyError，不如自己报清楚。
                raise SpecError("linear 约束缺少 op")
            lhs = sum(coef * assign[name] for coef, name in self.terms)
            return OPS[self.op](lhs, self.rhs)
        raise SpecError(f"未知约束类型：{self.kind}")

    @property
    def tuple_count(self) -> int:
        """该约束的 scope 上共有多少种赋值组合 —— 编码代价的直接度量。"""
        n = 1
        for size in self._sizes:
            n *= size
        return n

    _sizes: tuple[int, ...] = field(default=(), repr=False)


class Spec:
    def __init__(self, name: str, variables: list[Var], constraints: list[Constraint],
                 source: str | None = None):
        self.name = name
        self.variables = variables
        self.constraints = constraints
        self.source = source
        self._by_name = {v.name: v for v in variables}

    # ---------------------------------------------------------------- 载入

    @classmethod
    def load(cls, path: str) -> "Spec":
        try:
            with open(path, encoding="utf-8") as fh:
                raw = json.load(fh)
        except FileNotFoundError:
            raise SpecError(f"规格文件不存在：{path}")
        except json.JSONDecodeError as exc:
            raise SpecError(f"规格不是合法 JSON：{path}:{exc.lineno}: {exc.msg}")
        return cls.from_dict(raw, source=path)

    @classmethod
    def from_dict(cls, raw: dict, source: str | None = None) -> "Spec":
        if not isinstance(raw, dict):
            raise SpecError("规格顶层必须是对象")
        name = raw.get("name")
        if not isinstance(name, str) or not name:
            raise SpecError("规格缺少 name 字段")

        vs_raw = raw.get("vars")
        if not isinstance(vs_raw, list) or not vs_raw:
            raise SpecError("规格缺少 vars 字段（或为空）")
        variables: list[Var] = []
        for i, v in enumerate(vs_raw):
            if not isinstance(v, dict):
                raise SpecError(f"vars[{i}] 必须是对象")
            vn = v.get("name")
            if not isinstance(vn, str) or not vn:
                raise SpecError(f"vars[{i}] 缺少 name")
            lo, hi = v.get("lo"), v.get("hi")
            if not isinstance(lo, int) or not isinstance(hi, int):
                raise SpecError(f"变量 {vn} 的 lo/hi 必须是整数")
            if hi < lo:
                raise SpecError(f"变量 {vn} 的域为空：lo={lo} > hi={hi}")
            variables.append(Var(vn, lo, hi))
        dupes = [n for n in {v.name for v in variables}
                 if sum(1 for v in variables if v.name == n) > 1]
        if dupes:
            raise SpecError(f"变量名重复：{', '.join(sorted(dupes))}")

        by_name = {v.name: v for v in variables}
        cs_raw = raw.get("constraints", [])
        if not isinstance(cs_raw, list):
            raise SpecError("constraints 必须是数组")
        constraints: list[Constraint] = []
        for i, c in enumerate(cs_raw):
            constraints.append(cls._parse_constraint(c, i, by_name))

        return cls(name, variables, constraints, source=source)

    @staticmethod
    def _parse_constraint(c: dict, idx: int, by_name: dict[str, Var]) -> Constraint:
        if not isinstance(c, dict):
            raise SpecError(f"constraints[{idx}] 必须是对象")
        kind = c.get("kind")
        if kind == "alldiff":
            names = c.get("vars")
            if not isinstance(names, list) or len(names) < 2:
                raise SpecError(f"constraints[{idx}] alldiff 需要至少两个变量")
            for n in names:
                if n not in by_name:
                    raise SpecError(f"constraints[{idx}] 引用了未定义的变量 {n!r}")
            sizes = tuple(by_name[n].size for n in names)
            return Constraint("alldiff", tuple(names), _sizes=sizes)
        if kind == "linear":
            terms_raw = c.get("terms")
            if not isinstance(terms_raw, list) or not terms_raw:
                raise SpecError(f"constraints[{idx}] linear 需要 terms")
            terms: list[tuple[int, str]] = []
            for t in terms_raw:
                if not (isinstance(t, list) and len(t) == 2):
                    raise SpecError(f"constraints[{idx}] terms 项须为 [系数, 变量名]")
                coef, vn = t
                if not isinstance(coef, int):
                    raise SpecError(f"constraints[{idx}] 系数必须是整数：{coef!r}")
                if vn not in by_name:
                    raise SpecError(f"constraints[{idx}] 引用了未定义的变量 {vn!r}")
                terms.append((coef, vn))
            op = c.get("op")
            if op not in OPS:
                raise SpecError(f"constraints[{idx}] 非法 op：{op!r}；允许 {', '.join(OPS)}")
            rhs = c.get("rhs", 0)
            if not isinstance(rhs, int):
                raise SpecError(f"constraints[{idx}] rhs 必须是整数")
            scope = tuple(dict.fromkeys(vn for _, vn in terms))  # 保序去重
            sizes = tuple(by_name[n].size for n in scope)
            return Constraint("linear", scope, op=op, terms=tuple(terms), rhs=rhs,
                              _sizes=sizes)
        raise SpecError(f"constraints[{idx}] 未知 kind：{kind!r}（支持 alldiff / linear）")

    # ---------------------------------------------------------------- 求值

    def eval(self, assign: dict[str, int]) -> tuple[bool, str | None]:
        """直接求值。返回 (是否满足, 首个不满足的约束描述)。

        调用方必须能拿到「哪一条不满足」——只回一个 False 无法定位编码错误。
        """
        for v in self.variables:
            if v.name not in assign:
                return False, f"缺少变量 {v.name}"
            val = assign[v.name]
            if not isinstance(val, int) or not (v.lo <= val <= v.hi):
                return False, f"变量 {v.name}={val!r} 不在域 [{v.lo},{v.hi}] 内"
        for c in self.constraints:
            if not c.holds(assign):
                return False, describe(c)
        return True, None

    def solve_brute(self, limit: int = 2_000_000) -> tuple[dict[str, int] | None, int]:
        """穷举求解。仅用于小规模的真值对照 —— 它是「先用暴力对照」这条纪律的落地。

        返回 (assignment | None, 枚举空间大小)；空间超过 limit 时不枚举并返回 (None, 大小)。
        """
        total = 1
        for v in self.variables:
            total *= v.size
        if total > limit:
            return None, total
        names = [v.name for v in self.variables]
        for combo in itertools.product(*(v.values() for v in self.variables)):
            a = dict(zip(names, combo))
            ok, _ = self.eval(a)
            if ok:
                return a, total
        return None, total

    @property
    def search_space(self) -> int:
        total = 1
        for v in self.variables:
            total *= v.size
        return total

    def to_dict(self) -> dict:
        cons_out: list[dict] = []
        for c in self.constraints:
            if c.kind == "alldiff":
                cons_out.append({"kind": "alldiff", "vars": list(c.scope)})
            else:
                cons_out.append({
                    "kind": "linear", "terms": [[k, n] for k, n in c.terms],
                    "op": c.op, "rhs": c.rhs})
        return {
            "name": self.name,
            "vars": [{"name": v.name, "lo": v.lo, "hi": v.hi} for v in self.variables],
            "constraints": cons_out,
        }


def describe(c: Constraint) -> str:
    if c.kind == "alldiff":
        return f"alldiff({', '.join(c.scope)})"
    body = " + ".join(f"{k}*{n}" for k, n in c.terms)
    return f"{body} {c.op} {c.rhs}"


def load_witness(path: str) -> dict[str, int]:
    """读见证文件。接受 {"x": 1, ...} 或 {"assignment": {...}} 两种形状。"""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except FileNotFoundError:
        raise SpecError(f"见证文件不存在：{path}")
    except json.JSONDecodeError as exc:
        raise SpecError(f"见证不是合法 JSON：{path}:{exc.lineno}: {exc.msg}")
    if isinstance(raw, dict) and "assignment" in raw and isinstance(raw["assignment"], dict):
        raw = raw["assignment"]
    if not isinstance(raw, dict):
        raise SpecError("见证必须是一个对象：{变量名: 整数值}")
    out: dict[str, int] = {}
    for k, v in raw.items():
        if isinstance(v, bool) or not isinstance(v, int):
            raise SpecError(f"见证里 {k} 的值必须是整数，得到 {v!r}")
        out[k] = v
    return out

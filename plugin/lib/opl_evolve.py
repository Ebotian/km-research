"""opl_evolve —— 程序库与可进化区的约束。

一个职责：把「一份候选程序」变成一条可去重的库记录，并**强制**可进化区之外不许动。
搜索与评分不在这里（那是 `bin/opl-evolve-*` 与评估器的事）。

== 两条约束都是真约束，不是注释 ==

* **可进化区之外逐字节不许变。** `EVOLVE-BLOCK-START` / `EVOLVE-BLOCK-END` 之间的
  部分才是模型可以改的。区外一旦不同，候选被**拒绝**并给出理由——`doc/plan/04-skills.typ`
  的原话是「研究者写死骨架、模型只填一个函数」，那么「写死」就得由工具执行，不能靠
  自觉。比较是**逐字节**的：区外改一个空格也算改动。这条刻意取严——它会误拒「只重排
  了格式」的候选，但绝不会放过一次真实的区外改动，而两种错的代价不对称。

* **`code_hash` 去重由数据库的 UNIQUE 约束执行，不由调用方自觉。** 同一份程序第二次
  提交时由 `sqlite3.IntegrityError` 拦下，转成 `rejected_reason`。把去重放在「先查再写」
  的位置上，早晚会被并发或忘记检查绕过；放在唯一索引上则由数据库保证。

== 「精确去重」里的「精确」是什么 ==

`code_hash` 取的是**归一化后的 token 序列**的 sha256：

* 丢掉注释与纯换行（`tokenize` 的 `COMMENT` / `NL`）——只改注释不是一次真实变异，
  它不该占到一个新的库位。
* 结构类 token（`NEWLINE` / `INDENT` / `DEDENT`）只留**类型**、不留原文：行尾符
  与缩进用空格还是制表符都属于写法差异，不该改变哈希。它们的**存在**已经编码了块
  结构，所以丢原文不损失判别力。
* 保留标识符、字面量与其原文。所以任何语义改动都会改变哈希。
* 归一化不成立时（候选有语法错）退回「逐行去尾空白」的文本哈希，并在记录里标明
  `hash_mode`。**不**假装语法错的候选被成功归一化了。

也就是说：它吸收的是**写法差异**，不是**等价改写**。`x = a + b` 与 `x = b + a` 是两份
程序——这是有意的，判断等价需要语义分析，而那个判断错了会静默丢掉一个不同的候选。

**一条容易误解的边界**：归一化只在**词法层**做。多行字符串（含 docstring）里的
一切——行尾空白、像注释的文字、`\r\n`——都是字面量的一部分，改它就算真实改动，
哈希会变。实测踩过：给每行行尾补三个空格、或整体转成 CRLF，如果那行落在多行字符串
内部，`code_hash` 必然不同，而且这是**对的**。所以在候选里改 docstring 不是「写法
差异」，是一次真实变异。
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import sqlite3
import sys
import time
import tokenize
from dataclasses import dataclass, field
from typing import Any

BLOCK_START = "# EVOLVE-BLOCK-START"
BLOCK_END = "# EVOLVE-BLOCK-END"

# `doc/plan/05-data-model.typ` 定的表结构。`code_hash` 上的 UNIQUE 是去重的执行点。
SCHEMA = """
CREATE TABLE IF NOT EXISTS programs (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id    INTEGER REFERENCES programs(id),
    generation   INTEGER NOT NULL DEFAULT 0,
    island       TEXT    NOT NULL DEFAULT 'default',
    cell_key     TEXT,
    code_hash    TEXT    NOT NULL UNIQUE,
    hash_mode    TEXT    NOT NULL DEFAULT 'tokens',
    code         TEXT    NOT NULL,
    metrics_json TEXT,
    operation    TEXT,
    created_at   TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS programs_cell ON programs (island, cell_key);

-- 评估运行与程序**身份**分列。一份程序可以跑很多次：换预算、换机器、上次评估器坏了
-- 要补测。`programs.metrics_json` 保留「最近一次**合格**评估」的指标（best() 读它），
-- 而完整的运行史在这里——「这个数字是哪一次跑出来的、当时什么预算」必须查得到。
CREATE TABLE IF NOT EXISTS evaluations (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    program_id    INTEGER NOT NULL REFERENCES programs(id),
    run_dir       TEXT,
    kind          TEXT NOT NULL,
    feasible      INTEGER,
    metrics_json  TEXT,
    problem_sha256 TEXT,
    evaluator_sha256 TEXT,
    budget_json   TEXT,
    note          TEXT,
    created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS evaluations_program ON evaluations (program_id, id);
"""


class EvolveError(Exception):
    """候选本身不合格。调用方翻成退出码，**不**当成「搜索结果为空」。"""


@dataclass
class Block:
    """三块拼起来就是原文：`before + block + after`。"""

    before: str
    block: str
    after: str
    start_line: int
    end_line: int


@dataclass
class AddResult:
    accepted: bool
    program_id: int | None = None
    code_hash: str = ""
    rejected_reason: str | None = None
    notes: list[str] = field(default_factory=list)


# ------------------------------------------------------------------ 冻结的实验定义

PROBLEM_SCHEMA = "opl.evolve.problem/1"
# 指标字段的类型白名单。**`bool` 是独立的类型，不是「真值」**：字符串 "false"
# 在 Python 里是真值，实测它曾被判成通过。所以这里按 `isinstance` 判，而不是按真假。
METRIC_TYPES = ("bool", "int", "number", "string")


@dataclass
class Problem:
    """冻结的实验定义：题目参数 + 指标契约。

    为什么需要它（审阅稿 F2/F4 都指到这里）：**可进化区之外文本不变，不代表题目不变**。
    实测把 `N = 0` 放进区内重新绑定，就能让评估器看到一个零路问题并报 `sorts=True`、
    `comparators=0`。区外逐字节比对抓不到这个——它比的是文本，而题目是**运行时行为**。

    另外，插件的判决原先硬编码 `sorts`，一个返回 `{"feasible": true, "loss": …}` 的
    通用评估器其候选会被判 `NOT_SORTING`。可行性现在由本定义给出，插件不认识 `sorts`。
    """

    path: str
    params: dict[str, Any]
    feasible_field: str
    feasible_equals: Any
    objective_field: str | None
    objective_minimize: bool
    required: dict[str, str]
    title: str = ""

    def check_metrics(self, metrics: Any) -> list[str]:
        """校验指标的形状与类型。返回违规列表，空列表表示合格。

        **类型不对就报违规，不猜**：`sorts: "false"` 既不是真也不是假——它是错的。
        按真假猜会把一个坏记录变成一条判决。
        """
        why: list[str] = []
        if not isinstance(metrics, dict):
            return [f"metrics 应为对象，实为 {type(metrics).__name__}"]
        if not metrics:
            return ["metrics 是空的"]
        for field, want in self.required.items():
            if field not in metrics:
                why.append(f"metrics 缺字段 {field!r}（定义要求 {want}）")
                continue
            v = metrics[field]
            ok = {"bool": isinstance(v, bool),
                  "int": isinstance(v, int) and not isinstance(v, bool),
                  "number": isinstance(v, (int, float)) and not isinstance(v, bool),
                  "string": isinstance(v, str)}.get(want, False)
            if not ok:
                why.append(f"metrics[{field!r}] 应为 {want}，实为 "
                           f"{type(v).__name__}（值 {v!r}）——类型不对不是「假」")
        if self.feasible_field not in metrics:
            why.append(f"缺可行性字段 {self.feasible_field!r}")
        elif metrics[self.feasible_field] != self.feasible_equals:
            # 类型合法但值不等于要求：这是**不可行**，不是记录错误，交给调用方区分
            pass
        return why

    def feasible(self, metrics: dict[str, Any]) -> bool:
        return metrics.get(self.feasible_field) == self.feasible_equals


def load_problem(path: str) -> Problem:
    """读并校验冻结定义。字段缺失就报出来，不取默认值——默认值会让定义悄悄变松。"""
    if not os.path.isfile(path):
        raise EvolveError(f"实验定义不存在：{path}（先跑 opl-evolve-init --problem）")
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except json.JSONDecodeError as exc:
        raise EvolveError(f"实验定义不是合法 JSON：{path}:{exc.lineno}: {exc.msg}") from exc
    if not isinstance(raw, dict) or raw.get("schema") != PROBLEM_SCHEMA:
        raise EvolveError(f"实验定义的 schema 应为 {PROBLEM_SCHEMA!r}：{path}")
    m = raw.get("metrics")
    if not isinstance(m, dict):
        raise EvolveError("实验定义缺 metrics 段")
    feas = m.get("feasible")
    if not isinstance(feas, dict) or "field" not in feas or "equals" not in feas:
        raise EvolveError("实验定义缺 metrics.feasible.{field,equals}——"
                          "「什么算可行」必须由定义给出，不能由插件猜")
    obj = m.get("objective") or {}
    req = m.get("required") or {}
    if not isinstance(req, dict) or not req:
        raise EvolveError("实验定义缺 metrics.required——没有它就无法判断指标类型对不对")
    for f, t in req.items():
        if t not in METRIC_TYPES:
            raise EvolveError(f"metrics.required[{f!r}] 的类型 {t!r} 不在 "
                              f"{list(METRIC_TYPES)} 里")
    params = raw.get("params") or {}
    if not isinstance(params, dict):
        raise EvolveError("实验定义的 params 应为对象")
    return Problem(path=os.path.abspath(path), params=params,
                   feasible_field=str(feas["field"]),
                   feasible_equals=feas["equals"],
                   objective_field=obj.get("field"),
                   objective_minimize=bool(obj.get("minimize", True)),
                   required={str(k): str(v) for k, v in req.items()},
                   title=str(raw.get("title") or ""))


# ------------------------------------------------------------------ 可进化区


def split_block(code: str) -> Block:
    """按标记行切出可进化区。

    标记必须**各出现一次**。缺一个、或者出现两次，都是候选不合格——不猜、不取第一个
    （「猜」在这里的后果是让一次区外改动悄悄过审）。
    """
    lines = code.splitlines(keepends=True)
    starts = [i for i, ln in enumerate(lines) if ln.strip().startswith(BLOCK_START)]
    ends = [i for i, ln in enumerate(lines) if ln.strip().startswith(BLOCK_END)]
    if len(starts) != 1 or len(ends) != 1:
        raise EvolveError(
            f"可进化区标记必须各出现一次：找到 {len(starts)} 个 START、{len(ends)} 个 END")
    s, e = starts[0], ends[0]
    if e < s:
        raise EvolveError("EVOLVE-BLOCK-END 出现在 START 之前")
    return Block(
        before="".join(lines[:s + 1]),
        block="".join(lines[s + 1:e]),
        after="".join(lines[e:]),
        start_line=s + 1,
        end_line=e + 1,
    )


def assert_only_block_changed(skeleton: str, candidate: str) -> None:
    """区外逐字节比对。不同则抛 `EvolveError`，并指出第一处不同在哪。

    报「哪一行不同」而不是只报「区外被改了」：不然使用者得自己 diff 全文。
    """
    sk, cd = split_block(skeleton), split_block(candidate)
    for part, a, b in (("标记之前", sk.before, cd.before), ("标记之后", sk.after, cd.after)):
        if a == b:
            continue
        # 逐行找第一处不同，行号以候选为准（使用者打开的是候选）
        al, bl = a.splitlines(keepends=True), b.splitlines(keepends=True)
        for i, (x, y) in enumerate(zip(al, bl)):
            if x != y:
                raise EvolveError(
                    f"可进化区之外被改动（{part}，第 {i + 1} 行）：\n"
                    f"  骨架：{x.rstrip()!r}\n  候选：{y.rstrip()!r}")
        raise EvolveError(
            f"可进化区之外被改动（{part}）：行数 {len(al)} -> {len(bl)}")


def normalize(code: str) -> tuple[str, str]:
    """返回 (归一化形式, 模式)。模式是 `tokens` 或 `text`。

    `tokens`：丢注释与纯换行，其余 token 按顺序以 `\\x00` 连接。用 `\\x00` 而不是
    换行连接，是为了避免「两个 token 拼起来恰好等于另外两个 token」这类碰撞。
    """
    try:
        parts: list[str] = []
        for tok in tokenize.generate_tokens(io.StringIO(code).readline):
            if tok.type in (tokenize.COMMENT, tokenize.NL, tokenize.ENCODING):
                continue
            # 结构类 token 只留**类型**，丢掉它们的原文：`NEWLINE` 的原文带着行尾符
            # （LF 与 CRLF 于是哈希不同，实测踩到），`INDENT` / `DEDENT` 的原文是缩进
            # 空白（制表符与空格于是哈希不同）。而它们的存在本身就编码了块结构，
            # 所以丢原文不损失判别力。
            if tok.type in (tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT):
                parts.append(f"{tok.type}:")
            else:
                parts.append(f"{tok.type}:{tok.string}")
        return "\x00".join(parts), "tokens"
    except (tokenize.TokenError, IndentationError, SyntaxError):
        # 语法错的候选也可能要入库（记下「它坏了」这个事实），但必须标明用的是文本哈希
        return "\n".join(ln.rstrip() for ln in code.splitlines()).strip(), "text"


def code_hash(code: str) -> tuple[str, str]:
    """(sha256, 模式)。模式随归一化方式变化，进库供事后复核。"""
    norm, mode = normalize(code)
    return hashlib.sha256(norm.encode("utf-8")).hexdigest(), mode


# ------------------------------------------------------------------ 实验目录

EVOLVE_DIR = "evolve"

# 沙箱里能用的 python 必须**另行指定**，不能直接用 `sys.executable`：本机的
# `sys.executable` 在 `plugin/.venv/bin/` 下，而 bwrap 只绑了 `/usr` / `/etc` / `/lib64`
# 与工作目录——那个路径在沙箱里根本不存在。用 `/usr/bin/python3` 是「沙箱内确实有」
# 的那个，找不到时才退回 `sys.executable`（那就可能失败，失败会如实报出来）。
SANDBOX_PYTHON = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable


@dataclass
class InitResult:
    lab_dir: str
    db_path: str
    skeleton: str
    evaluator: str
    problem: str = ""
    seeded_id: int | None = None
    already_existed: bool = False
    metrics: dict[str, Any] | None = None
    baseline_note: str | None = None
    run_dir: str = ""


@dataclass
class EvalOutcome:
    exit_code: int
    kind: str = ""
    program_id: int | None = None
    code_hash: str = ""
    metrics: dict[str, Any] | None = None
    duplicate: bool = False
    reason: str | None = None
    run_dir: str = ""
    # 该打哪几个字段给用户看：来自**实验定义**，不由壳硬编码指标名（判据 F4）。
    summary_fields: list[str] = field(default_factory=list)


def coerce_scalar(v: str) -> Any:
    """把命令行上的 `KEY=VALUE` 里的 VALUE 变成有类型的值。

    不这么做的话 `--where sorts=true` 比不过 `True`（字符串 "true" ≠ 布尔 True），
    而那种失败是静默的——过滤掉了一切，`best` 于是返回 None。
    """
    low = v.strip().lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("none", "null"):
        return None
    for cast in (int, float):
        try:
            return cast(v)
        except ValueError:
            continue
    return v


def parse_where(items: list[str] | None) -> dict[str, Any] | None:
    """把 `["sorts=true", "comparators=5"]` 解析成 `{"sorts": True, "comparators": 5}`。"""
    if not items:
        return None
    out: dict[str, Any] = {}
    for it in items:
        if "=" not in it:
            raise EvolveError(f"--where 需要 KEY=VALUE 形式：{it!r}")
        k, v = it.split("=", 1)
        out[k.strip()] = coerce_scalar(v)
    return out


def lab_paths(lab: str) -> dict[str, str]:
    d = os.path.join(os.path.abspath(lab), EVOLVE_DIR)
    return {"dir": d,
            "skeleton": os.path.join(d, "skeleton.py"),
            "evaluator": os.path.join(d, "evaluator.py"),
            "problem": os.path.join(d, "problem.json"),
            "candidates": os.path.join(d, "candidates"),
            "db": os.path.join(d, "programs.sqlite")}


def _stage_and_evaluate(p: dict[str, str], code: str, h: str, *, problem_path: str,
                        timeout: float, mem_max_mb: int | None,
                        ) -> tuple[dict[str, Any] | None, str, str, dict[str, str]]:
    """把候选与冻结定义**只读**挂进沙箱、跑评估器、读回指标。

    == 沙箱里挂什么，是个安全问题，不是整理问题 ==

    原先把整个实验目录以读写方式挂到 `/work`（`skeleton.py`、`programs.sqlite`、
    `runs/` 全在里面），实测候选可以改写它们——包括改写基线骨架与历史证据。现在：

        /work               ← 本次运行自己的目录，**唯一可写**的地方
        /opt/evaluator.py   ← 从实验目录只读挂入
        /opt/problem.json   ← 冻结定义，只读挂入

    实验目录本身、数据库、历史运行目录**都不在沙箱的视野里**。候选要能跑就得能写
    `/work`，但它伸不到别处。冻结定义只读这一点尤其要紧——**一个能改定义的候选等于
    自己出题自己判**。

    返回 (metrics 或 None, 运行目录, 沙箱结局, 快照路径)。**不**在拿不到 metrics 时
    编一个空的：「没有结论」与「结论是空的」是两回事。
    """
    from opl_run import RunSpec, execute, write_snapshots

    run_dir = _next_run_dir(p, h)
    work = os.path.join(run_dir, "work")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "candidate.py"), "w", encoding="utf-8") as fh:
        fh.write(code)
    metrics_host = os.path.join(work, "metrics.json")

    spec = RunSpec(
        argv=[SANDBOX_PYTHON, "/opt/evaluator.py", "--problem", "/opt/problem.json",
              "--candidate", "/work/candidate.py", "--metrics-out", "/work/metrics.json"],
        workdir=work, run_id=os.path.basename(run_dir), runner_dir=run_dir,
        timeout=timeout, mem_max_mb=mem_max_mb,
        ro_binds=[(os.path.join(p["dir"], "evaluator.py"), "/opt/evaluator.py"),
                  (problem_path, "/opt/problem.json")])
    res = execute(spec)
    # 每次运行都落四份快照：**指标与它的来源必须一起留存**，否则事后无法回答
    # 「这个数字是怎么来的」。原先进化路径只调 execute()，运行目录里只有两个流文件。
    files = write_snapshots(spec, res)
    metrics: dict[str, Any] | None = None
    if os.path.isfile(metrics_host):
        try:
            with open(metrics_host, encoding="utf-8") as fh:
                metrics = json.load(fh)
        except ValueError:
            metrics = None
    return metrics, run_dir, res.kind, files


def _tail(path: str, limit: int = 200) -> str:
    """读一个文件的末尾若干行，压成一行——用来把评估器的拒绝理由带进错误信息。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        return ""
    return " / ".join(lines[-2:])[:limit]


def _next_run_dir(p: dict[str, str], h: str) -> str:
    """每次运行一个**新目录**：同一份程序可以跑很多次（补测、换预算、换机器），
    覆盖会静默销毁上一次的证据。"""
    base = os.path.join(p["dir"], "runs", h[:16])
    run_dir, n = base, 1
    while os.path.exists(run_dir):
        n += 1
        run_dir = f"{base}-{n}"
    return run_dir


def init_lab(lab: str, skeleton_src: str, evaluator_src: str, *, problem_src: str,
             force: bool = False, timeout: float = 60.0,
             mem_max_mb: int | None = None) -> InitResult:
    """建实验目录：把骨架、评估器、**冻结的实验定义**拷进来，评估骨架，入库。

    为什么拷贝而不是记录路径：区外比对的基准、以及「什么算可行」的定义，都必须**稳定**。
    指着会被编辑的外部文件，今天和明天比对的就不是同一个东西。

    为什么 init 就评估骨架：不评估的话第 0 代没有指标，「比骨架好」就没有可比对象——
    而且**你没法补测**（同一份代码再提交会被 `code_hash` 判重复）。所以基线必须在建库
    时就带着指标进来。沙箱起不来时仍能建库，但会明确标注「基线无指标」。
    """
    import shutil

    from opl_ledger import sha256_file

    p = lab_paths(lab)
    if os.path.exists(p["db"]) and not force:
        raise EvolveError(f"实验目录已存在：{p['db']}（要重建加 --force）")
    for src, what in ((skeleton_src, "骨架"), (evaluator_src, "评估器"),
                      (problem_src, "实验定义")):
        if not os.path.isfile(src):
            raise EvolveError(f"{what}文件不存在：{src}")
    problem = load_problem(problem_src)  # 先校验，别把一个坏定义拷进去
    os.makedirs(p["candidates"], exist_ok=True)
    shutil.copyfile(skeleton_src, p["skeleton"])
    shutil.copyfile(evaluator_src, p["evaluator"])
    shutil.copyfile(problem_src, p["problem"])

    code = open(p["skeleton"], encoding="utf-8").read()
    h, _ = code_hash(code)
    metrics, run_dir, kind, _files = _stage_and_evaluate(
        p, code, h, problem_path=p["problem"], timeout=timeout, mem_max_mb=mem_max_mb)

    note = None
    if metrics is None:
        note = (f"骨架未取得指标（沙箱结局 {kind}）；第 0 代没有 metrics，"
                f"在补测之前 best() 对它视而不见")
    else:
        bad = problem.check_metrics(metrics)
        if bad:
            # 指标的**形状**不对：宁可留空也不入库一个坏记录
            note = ("骨架的 metrics 不符合实验定义，未入库：" + "；".join(bad))
            metrics = None
    with ProgramLibrary(p["db"]) as lib:
        res = lib.add(code=code, skeleton=None, generation=0, operation="init",
                      metrics=None)
        if res.program_id is not None:
            # 基线也是一次运行，同样进运行史——「这个数字哪来的」要能一路查到 init
            lib.add_evaluation(
                res.program_id, kind=kind, run_dir=run_dir,
                metrics=metrics if metrics else None,
                feasible=None if metrics is None else problem.feasible(metrics),
                note=None if metrics else (note or "基线未取得指标"),
                problem_sha256=sha256_file(p["problem"]),
                evaluator_sha256=sha256_file(p["evaluator"]),
                budget={"timeout_s": timeout, "mem_max_mb": mem_max_mb})
    return InitResult(lab_dir=p["dir"], db_path=p["db"], skeleton=p["skeleton"],
                      evaluator=p["evaluator"], problem=p["problem"],
                      seeded_id=res.program_id, already_existed=force,
                      metrics=metrics, baseline_note=note, run_dir=run_dir)


def eval_candidate(lab: str, candidate: str, *, generation: int = 1,
                   parent_id: int | None = None, operation: str | None = None,
                   timeout: float = 60.0, mem_max_mb: int | None = None,
                   reevaluate: bool = False) -> EvalOutcome:
    """评估一份候选并入库。这是判据 8/9 与两条判据（F3/F4）在命令层的落点。

    判决的顺序是**先问「这次跑完了吗」，再问「它说行不行」**：

        1 沙箱结局不是 ok/payload_failed  → 3（**即使产物存在也不采信**）
        2 没有 metrics 产物                → 3
        3 metrics 不符合实验定义（含类型） → 2（记录坏了，不是「不可行」）
        4 可行性由**冻结定义**给出         → 0 / 1

    第 1 步是这个顺序里最要紧的：实测「评估器先写了 metrics 再卡死」会被判成通过。
    产物存在只说明写过文件，**不说明这次运行正常结束**。
    """
    from opl_common import EMPTY, MISSING, PASS, REJECT, UNKNOWN, USAGE
    from opl_ledger import sha256_file  # 与台账共用同一份实现，不复制第二份
    from opl_run import OK, PAYLOAD_FAILED

    p = lab_paths(lab)
    if not os.path.isfile(p["db"]):
        raise EvolveError(f"实验目录不存在：{p['db']}（先跑 opl-evolve-init）")
    if not os.path.isfile(candidate):
        raise EvolveError(f"候选文件不存在：{candidate}")
    if not os.path.isfile(p["evaluator"]):
        raise EvolveError(f"实验目录里缺评估器：{p['evaluator']}")
    problem = load_problem(p["problem"])
    summary = [problem.feasible_field] + (
        [problem.objective_field] if problem.objective_field else []) + \
        [f for f in problem.required if f not in (problem.feasible_field,
                                                  problem.objective_field)]

    code = open(candidate, encoding="utf-8").read()
    skeleton = open(p["skeleton"], encoding="utf-8").read()
    # 1 便宜且确定的：区外不许变（判据 9）
    assert_only_block_changed(skeleton, code)

    # 2 去重：命中就不必花钱跑沙箱了（判据 8）。唯一索引仍是最终保证，见 add()。
    h, _ = code_hash(code)
    with ProgramLibrary(p["db"]) as lib:
        dup = lib.by_hash(h)
    # 已知程序默认**不再跑**（判据 8：第二次提交因 code_hash 被拒，且不花沙箱的钱）。
    # 但「同一份程序要能再评估一次」是另一件事——补测、换预算、换机器都要它。
    # 两件事都用「提交同一份候选」触发，所以必须能区分：**补测要显式说**。
    # 默认拒绝、显式补测，比反过来安全：反过来会让「重复提交」静默地又跑一遍。
    if dup and not reevaluate:
        return EvalOutcome(exit_code=EMPTY, kind="duplicate", code_hash=h,
                           program_id=dup["id"], duplicate=True,
                           metrics=dup.get("metrics"),
                           reason=f"duplicate: code_hash 命中 {h[:12]}…"
                                  f"（已有 id={dup['id']}，第 {dup['generation']} 代）。"
                                  f"要再跑一次加 --reevaluate")

    metrics, run_dir, kind, _files = _stage_and_evaluate(
        p, code, h, problem_path=p["problem"], timeout=timeout, mem_max_mb=mem_max_mb)
    # 这次运行「在什么条件下、由什么评估器」跑的——运行史里必须查得到这些
    fp = {"problem_sha256": sha256_file(p["problem"]),
          "evaluator_sha256": sha256_file(p["evaluator"])}
    budget = {"timeout_s": timeout, "mem_max_mb": mem_max_mb}

    def record(program_id: int | None, *, feasible: bool | None, note: str | None = None,
               metrics_for_row: dict[str, Any] | None = None) -> None:
        if program_id is None:
            return
        with ProgramLibrary(p["db"]) as lib:
            lib.add_evaluation(program_id, kind=kind, run_dir=run_dir,
                               metrics=metrics_for_row, feasible=feasible,
                               note=note, budget=budget, **fp)

    # ---- F3：运行没正常结束就是「没有判决」，产物存在也不改这一条 ----
    existing_id = dup["id"] if dup else None
    if kind == "backend_missing":
        record(existing_id, feasible=None, note="沙箱后端缺失")
        return EvalOutcome(exit_code=MISSING, kind=kind, code_hash=h,
                           reason="找不到 bwrap：不降级到裸跑", run_dir=run_dir,
                           summary_fields=summary)
    if kind not in (OK, PAYLOAD_FAILED):
        extra = "（评估器写出了 metrics，但这次运行没有正常结束——不采信）" \
            if metrics is not None else ""
        # 这次没有结论：**不入 metrics**，只留一条运行史。旧指标也不动。
        record(existing_id, feasible=None, note=f"无判决：{kind}")
        return EvalOutcome(exit_code=UNKNOWN, kind=kind, code_hash=h,
                           reason=f"沙箱结局 {kind}{extra}", run_dir=run_dir,
                           summary_fields=summary)
    if metrics is None:
        # 「评估器没写出指标」本身不是结论，但它往往**有**理由——比如评估器按冻结定义
        # 拒了候选（实测：区内把 N 改成 0，评估器报「与冻结定义不一致」）。把那段
        # stderr 带出来；否则用户只看到「没有指标」，得自己去翻运行目录才知道为什么。
        tail = _tail(os.path.join(run_dir, "stderr.txt"))
        record(existing_id, feasible=None, note="评估器没写出指标")
        return EvalOutcome(exit_code=UNKNOWN, kind="no_metrics", code_hash=h,
                           reason=(f"评估器没写出指标（{run_dir}/work/metrics.json）"
                                   + (f"；它的 stderr 末尾：{tail}" if tail else "")),
                           run_dir=run_dir, summary_fields=summary)

    # ---- F4：指标的合法性由**冻结定义**判定，插件不认识具体字段名 ----
    bad = problem.check_metrics(metrics)
    if bad:
        record(existing_id, feasible=None, note="指标不合格：" + "；".join(bad))
        return EvalOutcome(exit_code=USAGE, kind="metrics_invalid", code_hash=h,
                           metrics=metrics, run_dir=run_dir,
                           reason="评估器产出的 metrics 不符合实验定义：" + "；".join(bad),
                           summary_fields=summary)

    ok = problem.feasible(metrics)
    if dup:
        # 补测：**身份不变**，只追加一次运行
        record(dup["id"], feasible=ok, metrics_for_row=metrics)
        return EvalOutcome(exit_code=PASS if ok else REJECT,
                           kind="reevaluated" if ok else "reevaluated_infeasible",
                           program_id=dup["id"], code_hash=h, duplicate=True,
                           metrics=metrics, run_dir=run_dir, summary_fields=summary,
                           reason=f"补测：id={dup['id']} 的又一次运行（身份未变）")
    with ProgramLibrary(p["db"]) as lib:
        added = lib.add(code=code, skeleton=skeleton, parent_id=parent_id,
                        generation=generation, operation=operation, metrics=None)
    if not added.accepted:
        reason = added.rejected_reason or ""
        return EvalOutcome(exit_code=USAGE, kind="candidate_invalid", code_hash=h,
                           metrics=metrics, reason=reason, run_dir=run_dir,
                           summary_fields=summary)
    record(added.program_id, feasible=ok, metrics_for_row=metrics)
    return EvalOutcome(exit_code=PASS if ok else REJECT,
                       kind="feasible" if ok else "infeasible",
                       program_id=added.program_id, code_hash=h, metrics=metrics,
                       run_dir=run_dir, summary_fields=summary)


# ------------------------------------------------------------------ 出题


@dataclass
class SuggestBrief:
    lab_dir: str
    skeleton_path: str
    block: str = ""
    outside: str = ""
    parents: list[dict[str, Any]] = field(default_factory=list)
    constraints: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def suggest(lab: str, *, parents: int = 3, metric: str | None = None,
            minimize: bool = True, where: dict[str, Any] | None = None) -> SuggestBrief:
    """给宿主 agent 出一份**可执行的变异任务书**。

    工具不替你做变异（`doc/plan/01-overview.typ`：变异算子留给宿主 agent，可执行文件
    只做「数据库 + 评估器 + 沙箱」）。它做的是让变异**有据可依、有据可查**：

    * 交出可进化区与**不可动的区外**（后者逐字节不许变，提交时会被拒）；
    * 挑出亲本，并逐条说明**为什么挑它**——一份没有理由的亲本清单是不可复核的；
    * 把提交时会被执行的约束原样列出，省掉一轮「提交→被拒」的往返。

    挑亲本的策略说清楚（单目标最好者 + 尽量覆盖不同代以保证多样性）。它**不**声称
    是 MAP-Elites：`cell_key` 的坐标还没定，编一个出来只会让「多样性」变成装饰。
    """
    p = lab_paths(lab)
    if not os.path.isfile(p["db"]):
        raise EvolveError(f"实验目录不存在：{p['db']}（先跑 opl-evolve-init）")
    skeleton = open(p["skeleton"], encoding="utf-8").read()
    parts = split_block(skeleton)

    brief = SuggestBrief(lab_dir=p["dir"], skeleton_path=p["skeleton"],
                         block=parts.block,
                         outside=parts.before + "…（此处不许改）…" + parts.after)
    brief.constraints = [
        f"可进化区由 `{BLOCK_START}` 与 `{BLOCK_END}` 标出，必须各出现一次；",
        "区外**逐字节**不许变——改一个空格也会被拒（退出码 2）；",
        "提交时按归一化 token 序列算 `code_hash`，重复的程序会被拒（退出码 5）；",
        "产物必须是**完整文件**（含区外原文），不是片段。",
    ]

    with ProgramLibrary(p["db"]) as lib:
        rows = [r for r in lib.all_programs() if r.get("metrics")]
        if not rows:
            brief.notes.append(
                "库里没有任何带指标的程序：先 `opl-evolve-eval` 一次骨架或某个候选，"
                "否则挑亲本没有依据")
            return brief
        feas = [r for r in rows
                if not where or all((r["metrics"] or {}).get(k) == v for k, v in where.items())]
        if not feas:
            brief.notes.append(f"没有程序满足过滤条件 {where}——退回按全部候选挑")
            feas = rows

        def sort_key(r: dict) -> tuple[float, int]:
            v = (r["metrics"] or {}).get(metric) if metric else 0.0
            v = float(v) if isinstance(v, (int, float)) else 0.0
            # 升序排列；最小化时直接按值升序，最大化时才取负。写反的话「当前最好」
            # 会指向一个更差的行——实测踩到：comparators 有 5 的时候把 6 当成了最好。
            return ((v if minimize else -v), int(r["id"]))

        ordered = sorted(feas, key=sort_key)
        chosen: list[dict[str, Any]] = []
        seen_gen: set[int] = set()
        if ordered:
            top = ordered[0]
            chosen.append(top | {"why": "当前最好"
                                 + (f"（按 {metric} {'最小' if minimize else '最大'}）"
                                    if metric else "")})
            seen_gen.add(int(top["generation"]))
        for r in ordered[1:]:
            if len(chosen) >= parents:
                break
            if int(r["generation"]) in seen_gen:
                continue
            chosen.append(r | {"why": f"第 {r['generation']} 代的其他代表（多样性）"})
            seen_gen.add(int(r["generation"]))
        for r in ordered[1:]:
            if len(chosen) >= parents:
                break
            if any(c["id"] == r["id"] for c in chosen):
                continue
            chosen.append(r | {"why": "次优（多样性已用尽）"})
        brief.parents = chosen
        if metric and not any(metric in (r["metrics"] or {}) for r in rows):
            brief.notes.append(f"没有任何程序带指标 {metric!r}，排序退化为按 id")
    return brief


# ------------------------------------------------------------------ 程序库


class ProgramLibrary:
    """SQLite 程序库。**派生索引而非真源**：删掉它不丢信息（`doc/plan/05-data-model.typ`）。"""

    def __init__(self, path: str) -> None:
        self.path = path
        parent = os.path.dirname(os.path.abspath(path))
        os.makedirs(parent, exist_ok=True)
        self.conn = sqlite3.connect(path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "ProgramLibrary":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -------------------------------------------------------------- 写入

    def add(self, *, code: str, skeleton: str | None = None, parent_id: int | None = None,
            generation: int = 0, island: str = "default", cell_key: str | None = None,
            operation: str | None = None, metrics: dict[str, Any] | None = None) -> AddResult:
        """提交一份候选。被拒时**给出理由**，不只是返回 False。

        检查顺序：标记齐全 → 区外未变 → 去重。前两条是候选不合格（调用方该去修候选），
        第三条是「已存在」（调用方该换个变异）。三种结局分别有各自的理由文本。
        """
        try:
            split_block(code)
        except EvolveError as exc:
            return AddResult(False, rejected_reason=f"invalid: {exc}")
        if skeleton is not None:
            try:
                assert_only_block_changed(skeleton, code)
            except EvolveError as exc:
                return AddResult(False, rejected_reason=f"outside_block_changed: {exc}")

        h, mode = code_hash(code)
        try:
            cur = self.conn.execute(
                "INSERT INTO programs (parent_id, generation, island, cell_key, code_hash,"
                " hash_mode, code, metrics_json, operation, created_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (parent_id, generation, island, cell_key, h, mode, code,
                 json.dumps(metrics, ensure_ascii=False, sort_keys=True) if metrics else None,
                 operation, time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        except sqlite3.IntegrityError as exc:
            # 唯一索引拦下的就是「同一份程序」。把已有那条报出来，方便调用方看它是什么。
            dup = self.by_hash(h)
            where = f"（已有 id={dup['id']}，第 {dup['generation']} 代）" if dup else ""
            return AddResult(False, code_hash=h,
                             rejected_reason=f"duplicate: code_hash 命中 {h[:12]}…{where} "
                                             f"[{exc.__class__.__name__}]")
        self.conn.commit()
        new_id = cur.lastrowid
        if new_id is None:
            # 理论上 INSERT 成功就有 id；真拿不到就如实说，不编一个。
            return AddResult(False, code_hash=h,
                             rejected_reason="internal: INSERT 成功但拿不到 lastrowid")
        return AddResult(True, program_id=int(new_id), code_hash=h)

    def add_evaluation(self, program_id: int, *, kind: str, run_dir: str | None = None,
                       metrics: dict[str, Any] | None = None, feasible: bool | None = None,
                       problem_sha256: str | None = None,
                       evaluator_sha256: str | None = None,
                       budget: dict[str, Any] | None = None,
                       note: str | None = None) -> int:
        """记一次运行。**只有合格且可行的新结果才更新程序的头条指标。**

        不覆盖的理由：一次后来的坏运行（超时、评估器坏了）不该抹掉已经拿到的成绩——
        那会让库里的最好结果随运气漂移。旧指标留在 `programs.metrics_json`，
        这次运行如实进 `evaluations`，两者都能查到。
        """
        cur = self.conn.execute(
            "INSERT INTO evaluations (program_id, run_dir, kind, feasible, metrics_json,"
            " problem_sha256, evaluator_sha256, budget_json, note, created_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (program_id, run_dir, kind,
             None if feasible is None else int(feasible),
             json.dumps(metrics, ensure_ascii=False, sort_keys=True) if metrics else None,
             problem_sha256, evaluator_sha256,
             json.dumps(budget, ensure_ascii=False, sort_keys=True) if budget else None,
             note, time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        if metrics is not None:
            self.conn.execute("UPDATE programs SET metrics_json = ? WHERE id = ?",
                              (json.dumps(metrics, ensure_ascii=False, sort_keys=True),
                               program_id))
        self.conn.commit()
        return int(cur.lastrowid or 0)

    def evaluations(self, program_id: int) -> list[dict[str, Any]]:
        rows = self.conn.execute(
            "SELECT * FROM evaluations WHERE program_id = ? ORDER BY id",
            (program_id,)).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            raw = d.pop("metrics_json", None)
            d["metrics"] = json.loads(raw) if raw else None
            out.append(d)
        return out

    # -------------------------------------------------------------- 读取

    def by_hash(self, h: str) -> dict[str, Any] | None:
        row = self.conn.execute("SELECT * FROM programs WHERE code_hash = ?", (h,)).fetchone()
        return dict(row) if row else None

    def get(self, program_id: int) -> dict[str, Any] | None:
        row = self.conn.execute("SELECT * FROM programs WHERE id = ?", (program_id,)).fetchone()
        return self._decode(dict(row)) if row else None

    def all_programs(self, *, island: str | None = None,
                     limit: int | None = None) -> list[dict[str, Any]]:
        """**不要**把这个方法叫 `list`：类体里 `list[...]` 的注解会解析到它，
        于是同一作用域内的类型注解全坏掉（`ty` 会直接报
        `Invalid subscript of object of type def list(...)`）。这个名字换来的是
        一个不显眼的雷。"""
        q = "SELECT * FROM programs"
        args: list[Any] = []
        if island:
            q += " WHERE island = ?"
            args.append(island)
        q += " ORDER BY id"
        if limit:
            q += " LIMIT ?"
            args.append(limit)
        return [self._decode(dict(r)) for r in self.conn.execute(q, args)]

    def best(self, metric: str, *, minimize: bool = True, island: str | None = None,
             where: dict[str, Any] | None = None) -> dict[str, Any] | None:
        """按 `metrics_json` 里的某个字段取最好的一条。

        **两条如实记录的坑，都是实测踩出来的：**

        * **没有可比指标的行被跳过，而不是当成 0。** 把「没测出这个指标」当成最小值，
          正好会在「改进」这件事上造出假结论。
        * **不过滤的话，数字最小不等于最好。** 实测：库里有一条 4 个比较器的候选，
          它**并不排序**（`sorts=False`）。`best("comparators", minimize=True)` 会选中它
          ——于是「从 6 个改进到 4 个」听起来像一次提升，实际上是一个坏程序。所以
          可行性必须由调用方以 `where` 显式给出（比如 `{"sorts": True}`）；这个原语
          刻意不替调用方猜哪个字段意味着「可行」。
        """
        cands: list[tuple[float, dict[str, Any]]] = []
        for rec in self.all_programs(island=island):
            m = rec.get("metrics") or {}
            if metric not in m or not isinstance(m[metric], (int, float)):
                continue
            if where and any(m.get(k) != v for k, v in where.items()):
                continue
            cands.append((float(m[metric]), rec))
        if not cands:
            return None
        cands.sort(key=lambda t: (-t[0] if not minimize else t[0], t[1]["id"]))
        return cands[0][1]

    def count(self) -> int:
        return int(self.conn.execute("SELECT COUNT(*) AS n FROM programs").fetchone()["n"])

    @staticmethod
    def _decode(rec: dict[str, Any]) -> dict[str, Any]:
        raw = rec.get("metrics_json")
        rec["metrics"] = json.loads(raw) if raw else None
        return rec

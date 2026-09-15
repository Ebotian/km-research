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
            "candidates": os.path.join(d, "candidates"),
            "db": os.path.join(d, "programs.sqlite")}


def _stage_and_evaluate(p: dict[str, str], code: str, h: str, *,
                        timeout: float, mem_max_mb: int | None,
                        ) -> tuple[dict[str, Any] | None, str, str]:
    """把候选拷进沙箱工作目录、跑评估器、读回 metrics。

    返回 (metrics 或 None, 运行目录, 沙箱结局)。**不**在拿不到 metrics 时编一个空的：
    「没有结论」与「结论是空的」是两回事，调用方要能分开。
    """
    from opl_run import RunSpec, execute

    # 运行目录**不覆盖**：同一个 hash 第二次跑（比如上次超时、这次给了更长的预算）
    # 会拿到 `-2`、`-3` 这样的后缀。覆盖会静默销毁上一次的证据，而运行快照正是
    # 这个工具要留存的东西。实测正是这一点让「重复候选没花沙箱的钱」变得可断言：
    # 按 hash 命名时，一次真实的重复评估与「什么都没跑」在目录清单上看起来一样。
    base_id = h[:16]
    run_id, run_dir = base_id, os.path.join(p["dir"], "runs", base_id)
    n = 1
    while os.path.exists(run_dir):
        n += 1
        run_id = f"{base_id}-{n}"
        run_dir = os.path.join(p["dir"], "runs", run_id)

    os.makedirs(p["candidates"], exist_ok=True)
    staged = os.path.join(p["candidates"], f"{base_id}.py")
    with open(staged, "w", encoding="utf-8") as fh:
        fh.write(code)
    metrics_rel = f"candidates/{run_id}.metrics.json"
    metrics_host = os.path.join(p["dir"], metrics_rel)

    spec = RunSpec(
        argv=[SANDBOX_PYTHON, "/work/evaluator.py", "--candidate",
              f"/work/candidates/{base_id}.py", "--metrics-out", f"/work/{metrics_rel}"],
        workdir=p["dir"], run_id=run_id, runner_dir=run_dir,
        timeout=timeout, mem_max_mb=mem_max_mb)
    res = execute(spec)
    metrics: dict[str, Any] | None = None
    if os.path.isfile(metrics_host):
        try:
            with open(metrics_host, encoding="utf-8") as fh:
                metrics = json.load(fh)
        except ValueError:
            metrics = None
    return metrics, run_dir, res.kind


def init_lab(lab: str, skeleton_src: str, evaluator_src: str, *,
             force: bool = False, timeout: float = 60.0,
             mem_max_mb: int | None = None) -> InitResult:
    """建实验目录：把骨架与评估器**拷进来**，评估骨架，再把骨架作为第 0 代入库。

    为什么拷贝而不是记录路径：区外比对的基准必须是**稳定的**。指着一个会被编辑的
    外部文件，今天和明天比对的是两份不同的骨架，而「区外没变」这个判断就失去意义。

    为什么 init 就评估骨架：不评估的话库里第 0 代**没有指标**，于是 `best(comparators)`
    一开始空着，而「比骨架好」这件事就没有可比对象——更糟的是你**没法补评估**：
    同一份代码再次提交会被 `code_hash` 判为重复（实测踩到）。所以基线必须在建库时
    就带着指标进来。
    """
    import shutil

    p = lab_paths(lab)
    if os.path.exists(p["db"]) and not force:
        raise EvolveError(f"实验目录已存在：{p['db']}（要重建加 --force）")
    for src, what in ((skeleton_src, "骨架"), (evaluator_src, "评估器")):
        if not os.path.isfile(src):
            raise EvolveError(f"{what}文件不存在：{src}")
    os.makedirs(p["candidates"], exist_ok=True)
    shutil.copyfile(skeleton_src, p["skeleton"])
    shutil.copyfile(evaluator_src, p["evaluator"])

    code = open(p["skeleton"], encoding="utf-8").read()
    h, _ = code_hash(code)
    metrics, run_dir, kind = _stage_and_evaluate(p, code, h, timeout=timeout,
                                                mem_max_mb=mem_max_mb)
    note = None
    if metrics is None:
        # 沙箱起不来时仍要能建库（否则没法做别的事），但必须标明基线**没有指标**。
        note = (f"骨架未取得指标（沙箱结局 {kind}）；第 0 代没有 metrics，"
                f"best() 在补测之前对它视而不见")
    with ProgramLibrary(p["db"]) as lib:
        res = lib.add(code=code, skeleton=None, generation=0, operation="init",
                      metrics=metrics)
    return InitResult(lab_dir=p["dir"], db_path=p["db"], skeleton=p["skeleton"],
                      evaluator=p["evaluator"], seeded_id=res.program_id,
                      already_existed=force, metrics=metrics, baseline_note=note,
                      run_dir=run_dir)


def eval_candidate(lab: str, candidate: str, *, generation: int = 1,
                   parent_id: int | None = None, operation: str | None = None,
                   timeout: float = 60.0, mem_max_mb: int | None = None) -> EvalOutcome:
    """评估一份候选并入库。这是判据 8/9 在命令层的落点。

    顺序是刻意的：**先做便宜且确定的检查，再花沙箱的钱**。
    区外改动是候选不合格（该去修候选），重复是「已经知道」（该换个变异），
    沙箱没给出判决是「还不知道」——三种结局的退出码各不相同，混起来就没法处置。
    """
    from opl_common import EMPTY, MISSING, PASS, REJECT, UNKNOWN, USAGE
    from opl_run import PAYLOAD_FAILED, OK

    p = lab_paths(lab)
    if not os.path.isfile(p["db"]):
        raise EvolveError(f"实验目录不存在：{p['db']}（先跑 opl-evolve-init）")
    if not os.path.isfile(candidate):
        raise EvolveError(f"候选文件不存在：{candidate}")
    if not os.path.isfile(p["evaluator"]):
        raise EvolveError(f"实验目录里缺评估器：{p['evaluator']}")

    code = open(candidate, encoding="utf-8").read()
    skeleton = open(p["skeleton"], encoding="utf-8").read()
    # 1 便宜且确定的：区外不许变（判据 9）
    assert_only_block_changed(skeleton, code)

    # 2 去重：命中就不必花钱跑沙箱了（判据 8）。唯一索引仍是最终保证，见 add()。
    h, _ = code_hash(code)
    with ProgramLibrary(p["db"]) as lib:
        dup = lib.by_hash(h)
    if dup:
        return EvalOutcome(exit_code=EMPTY, kind="duplicate", code_hash=h,
                           program_id=dup["id"], duplicate=True,
                           metrics=dup.get("metrics"),
                           reason=f"duplicate: code_hash 命中 {h[:12]}…"
                                  f"（已有 id={dup['id']}，第 {dup['generation']} 代）")

    # 3 花沙箱的钱
    metrics, run_dir, kind = _stage_and_evaluate(p, code, h, timeout=timeout,
                                                mem_max_mb=mem_max_mb)
    if kind == "backend_missing":
        return EvalOutcome(exit_code=MISSING, kind=kind, code_hash=h,
                           reason="找不到 bwrap：不降级到裸跑", run_dir=run_dir)
    if metrics is None:
        # 超时 / OOM / 被杀 / 沙箱起不来：**没有判决**，不要读成「候选不行」
        return EvalOutcome(exit_code=UNKNOWN, kind=kind, code_hash=h,
                           reason=f"沙箱结局 {kind}，评估器没写出 metrics", run_dir=run_dir)

    with ProgramLibrary(p["db"]) as lib:
        added = lib.add(code=code, skeleton=skeleton, parent_id=parent_id,
                        generation=generation, operation=operation, metrics=metrics)
    if not added.accepted:
        # `add()` 是**第二道**关，它也会做区外检查（纵深防御）。所以这里不能一律
        # 当成「重复」——把「候选不合格」记成「已经知道」会让调用方去换变异，
        # 而它其实该去修候选。按 add() 给的理由分类，而不是按我们的猜测。
        reason = added.rejected_reason or ""
        if reason.startswith("duplicate"):
            return EvalOutcome(exit_code=EMPTY, kind="duplicate", code_hash=h,
                               duplicate=True, metrics=metrics,
                               reason=reason, run_dir=run_dir)
        return EvalOutcome(exit_code=USAGE, kind="candidate_invalid", code_hash=h,
                           metrics=metrics, reason=reason, run_dir=run_dir)
    sorts = bool(metrics.get("sorts"))
    return EvalOutcome(exit_code=PASS if sorts else REJECT,
                       kind="evaluated" if sorts else "not_sorting",
                       program_id=added.program_id, code_hash=h, metrics=metrics,
                       run_dir=run_dir)



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

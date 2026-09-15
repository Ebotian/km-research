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

    def best(self, metric: str, *, minimize: bool = True,
             island: str | None = None) -> dict[str, Any] | None:
        """按 `metrics_json` 里的某个字段取最好的一条。

        **没有可比指标的行被跳过，而不是当成 0。** 把「没测出这个指标」当成最小值，
        正好会在「改进」这件事上造出假结论——那是最不能出现的一类错。
        """
        cands: list[tuple[float, dict[str, Any]]] = []
        for rec in self.all_programs(island=island):
            m = rec.get("metrics") or {}
            if metric not in m or not isinstance(m[metric], (int, float)):
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

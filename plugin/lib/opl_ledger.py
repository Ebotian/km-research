"""opl_ledger —— 猜想台账的记录模型、派生状态与读写。

一题一文件、纯文本、可入版本控制，`SQLite` 之类只配当派生索引。

两条设计要点，都是为了让「自欺」在结构上无法*表达*：

* **总状态是派生的，不存盘。** 它由 `informal_status` 与 `formal_status` 两个独立
  字段算出——单一枚举写不出「机器已证、人未消化」这类中间态（那是 `open (Lean)`）。
  所以直接读台账文件是**看不到** `status` 的，必须经 `derive_status` 或向命令要。
* **状态变更必须带证据指针。** 这不是文档里的约定，而是被拒绝的操作：
  `apply_changes` 在没有 evidence 时抛 `LedgerError`。没有证据指针的状态变更
  正是本项目最想防的那件事，所以它必须由代码拦，不能靠提示词劝。

本模块不做 I/O 输出、不解析 argv——那些在 `bin/opl-conj`。这样它可 import、
可单测、可被类型检查（`bin/` 下的无扩展名文件是类型检查的盲区）。
"""

from __future__ import annotations

import glob
import json
import os
import time
from typing import Any, Required, TypedDict

STATUSES = ["open", "proved_by_hand", "disproved"]
FORMAL_STATUSES = ["open", "refuted", "proved", "no_counterexample_in_range", "inconclusive"]
FORMALIZATION = ["none", "draft", "compiles", "faithfulness_checked"]
LEVELS = ["empirical", "exact_certificate", "lean_checked", "human_peer_reviewed"]


class LedgerError(Exception):
    """记录或参数不合法。调用方翻成 USAGE（退出码 2）。"""


class Source(TypedDict):
    url: str | None
    attribution: str | None
    retrieved_at: str


# `from` 是 Python 关键字，类语法写不出来，所以用函数式形式。
HistoryEntry = TypedDict("HistoryEntry", {
    "at": str, "field": str, "from": Any, "to": Any,
    "evidence": str | None, "run_id": str | None,
})


class Conjecture(TypedDict, total=False):
    """一条猜想记录。

    `total=False` 配 `Required[...]`（PEP 655）而不是全可选：`status` 只在输出时
    临时加上，所以整体不能是 total；但 `id` 之类的字段一旦标成可选，`rec["id"]`
    就成了「可能不存在的访问」——pyright 会报 `Could not access item in TypedDict`，
    而 mypy 与 ty 不报。三个检查器里只有 pyright 抓到这一处，是它值回票价的地方。
    """

    id: Required[str]
    statement_nl: Required[str]
    informal_status: Required[str]
    formal_status: Required[str]
    formalization_status: Required[str]
    verification_level: Required[str]
    falsifiable: Required[bool]
    decidable: Required[str]
    history: Required[list[HistoryEntry]]
    title: str
    statement_formal: dict[str, str | None] | None
    verified_range: dict[str, Any] | None
    known_bounds: list[dict[str, Any]]
    counterexamples: list[dict[str, Any]]
    source: Source
    status: str


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


# ------------------------------------------------------------------ 路径与读写


def lab_dir(explicit: str | None = None) -> str:
    return explicit or os.environ.get("OPL_LAB") or "lab"


def conj_dir(lab: str | None = None) -> str:
    return os.path.join(lab_dir(lab), "conjectures")


def record_path(cid: str, lab: str | None = None) -> str:
    return os.path.join(conj_dir(lab), f"{cid}.json")


def load(cid: str, lab: str | None = None) -> Conjecture | None:
    p = record_path(cid, lab)
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as fh:
            rec: Conjecture = json.load(fh)
    except json.JSONDecodeError as exc:
        raise LedgerError(f"台账文件不是合法 JSON：{p}:{exc.lineno}: {exc.msg}") from exc
    return rec


def save(rec: Conjecture, lab: str | None = None) -> str:
    """原子写入：先写 .tmp 再 replace，避免半个文件留在盘上。"""
    d = conj_dir(lab)
    os.makedirs(d, exist_ok=True)
    p = record_path(rec["id"], lab)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, p)
    return p


def list_records(lab: str | None = None, *, status: str | None = None,
                 limit: int | None = None) -> tuple[list[Conjecture], int]:
    """返回 (匹配的记录, 扫描过的文件数)。scanned 让调用方能说「扫了几条」。"""
    files = sorted(glob.glob(os.path.join(conj_dir(lab), "*.json")))
    rows: list[Conjecture] = []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                rec: Conjecture = json.load(fh)
        except json.JSONDecodeError:
            continue
        derived = derive_status(rec)
        rec["status"] = derived
        if status and derived != status:
            continue
        rows.append(rec)
    return (rows[:limit] if limit else rows), len(files)


# ------------------------------------------------------------------ 派生状态


def derive_status(rec: Conjecture) -> str:
    """由两个独立状态字段派生总状态。

    引入这个派生字段是为了表达「机器已证、人未消化」——单一枚举写不出这个语义。
    """
    fs = rec.get("formal_status", "open")
    inf = rec.get("informal_status", "open")
    if fs == "refuted":
        return "refuted"
    if inf == "disproved":
        return "disproved (unformalized)"
    if inf == "open" and fs == "proved":
        return "open (Lean)"
    if fs == "proved":
        return "proved"
    if fs == "no_counterexample_in_range":
        vr = rec.get("verified_range") or {}
        return f"open (bounded {vr.get('lo')}..{vr.get('hi')})"
    if fs == "inconclusive":
        return "open (inconclusive)"
    return "open"


# ------------------------------------------------------------------ 写入


def new_record(*, cid: str, statement: str, title: str | None = None,
               source: str | None = None, attribution: str | None = None,
               falsifiable: bool = True, decidable: str = "unknown",
               informal_status: str = "open") -> Conjecture:
    now = now_iso()
    if informal_status not in STATUSES:
        raise LedgerError(f"非法 informal_status，允许：{', '.join(STATUSES)}")
    return {
        "id": cid,
        "title": title or cid,
        "statement_nl": statement,
        "statement_formal": None,
        "informal_status": informal_status,
        "formal_status": "open",
        "formalization_status": "none",
        "falsifiable": falsifiable,
        "decidable": decidable,
        "verified_range": None,
        "known_bounds": [],
        "counterexamples": [],
        "source": {"url": source, "attribution": attribution, "retrieved_at": now},
        "verification_level": "empirical",
        "history": [{"at": now, "field": "id", "from": None, "to": cid,
                     "evidence": None, "run_id": None}],
    }


def _touch(rec: Conjecture, field: str, old: Any, new: Any, *,
           evidence: str | None, run_id: str | None) -> None:
    rec.setdefault("history", []).append({
        "at": now_iso(), "field": field, "from": old, "to": new,
        "evidence": evidence, "run_id": run_id,
    })


def _parse_range(spec: str) -> tuple[int, int]:
    if ".." not in spec:
        raise LedgerError(f"--verified-range 需要 LO..HI 形式，得到 {spec!r}")
    lo_s, _, hi_s = spec.partition("..")
    try:
        lo, hi = int(lo_s), int(hi_s)
    except ValueError as exc:
        raise LedgerError(f"--verified-range 的两端必须是整数：{spec!r}") from exc
    if hi < lo:
        raise LedgerError(f"--verified-range 的域为空：lo={lo} > hi={hi}")
    return lo, hi


def apply_changes(rec: Conjecture, *, evidence: str | None = None,
                  run_id: str | None = None,
                  formal_status: str | None = None,
                  informal_status: str | None = None,
                  formalization_status: str | None = None,
                  statement_formal: str | None = None,
                  decl: str | None = None,
                  verified_range: str | None = None,
                  method: str | None = None,
                  add_bound: list[str] | None = None,
                  add_counterexample: list[str] | None = None,
                  verification_level: str | None = None,
                  ) -> tuple[Conjecture, list[str]]:
    """把一批改动应用到记录上，返回 (记录, 警告列表)。

    唯一的硬规则：**任何状态变更都必须带 evidence**，否则抛 LedgerError。
    其余非法的取值也抛 LedgerError；可容忍的情形（如反例缺证书指针）走警告。
    """
    if (formal_status or informal_status) and not evidence:
        raise LedgerError(
            "拒绝写入：状态变更必须带 --evidence <指针>。"
            "没有证据指针的状态变更正是本项目要防的自欺。")

    if formal_status:
        if formal_status not in FORMAL_STATUSES:
            raise LedgerError(f"非法 formal_status，允许：{', '.join(FORMAL_STATUSES)}")
        _touch(rec, "formal_status", rec.get("formal_status"), formal_status,
               evidence=evidence, run_id=run_id)
        rec["formal_status"] = formal_status
    if informal_status:
        if informal_status not in STATUSES:
            raise LedgerError(f"非法 informal_status，允许：{', '.join(STATUSES)}")
        _touch(rec, "informal_status", rec.get("informal_status"), informal_status,
               evidence=evidence, run_id=run_id)
        rec["informal_status"] = informal_status

    warnings: list[str] = []
    if formalization_status:
        if formalization_status not in FORMALIZATION:
            raise LedgerError(f"非法 formalization_status，允许：{', '.join(FORMALIZATION)}")
        if formalization_status == "faithfulness_checked":
            warnings.append(
                "faithfulness_checked 是人工确认项。自动形式化的编译率会系统性高估"
                "忠实度（实测语义正确率约 76%），工具不会替你下这个判断。")
        _touch(rec, "formalization_status", rec.get("formalization_status"),
               formalization_status, evidence=evidence, run_id=run_id)
        rec["formalization_status"] = formalization_status

    if statement_formal:
        rec["statement_formal"] = {"file": statement_formal, "decl": decl}

    if verified_range:
        lo, hi = _parse_range(verified_range)
        rec["verified_range"] = {"lo": lo, "hi": hi,
                                 "method": method or "unknown",
                                 "run_id": run_id,
                                 "statement": "仅在该有限域内无反例"}

    for spec in add_bound or []:
        claim, _, rest = spec.partition("=")
        value, _, src = rest.partition("@")
        rec.setdefault("known_bounds", []).append(
            {"claim": claim, "value": value, "source": src or None})

    for witness in add_counterexample or []:
        rec.setdefault("counterexamples", []).append(
            {"witness": witness, "certificate": evidence,
             "verified_by": "independent" if evidence else "UNVERIFIED",
             "verification_level": "exact_certificate" if evidence else "empirical",
             "recorded_at": now_iso()})
        if not evidence:
            warnings.append(f"反例 {witness!r} 没有证书指针，请补 --evidence")

    if verification_level:
        if verification_level not in LEVELS:
            raise LedgerError(f"非法 verification_level，允许：{', '.join(LEVELS)}")
        _touch(rec, "verification_level", rec.get("verification_level"),
               verification_level, evidence=evidence, run_id=run_id)
        rec["verification_level"] = verification_level

    return rec, warnings

"""opl_ledger —— 猜想台账的记录模型、派生状态与读写。

一题一文件、纯文本、可入版本控制，`SQLite` 之类只配当派生索引。

三条设计要点，都是为了让「自欺」在结构上无法*表达*：

* **总状态是派生的，不存盘。** 它由 `informal_status` 与 `formal_status` 两个独立
  字段算出——单一枚举写不出「机器已证、人未消化」这类中间态（那是 `open (Lean)`）。
  所以直接读台账文件是**看不到** `status` 的，必须经 `derive_status` 或向命令要。
* **任何状态变更都必须带证据指针。** 这不是文档里的约定，而是被拒绝的操作：
  `apply_changes` 在没有 evidence 时抛 `LedgerError`。
* **档位（`verification_level`）不能没有依据地升。** 指针非空只是「填了」，
  不等于「复核过」。所以升到 `exact_certificate` / `lean_checked` 时，指针必须指向
  一份**结构化证据记录**，且该记录的判决要支撑这个档位；见 `load_evidence`。

== 台账只认「验证器说了什么」，不替它作证 ==

`load_evidence` 做三件事，一件比一件强：

1. **存在且格式对**：文件在、是 JSON、`schema == "opl.evidence/1"`。
2. **判决支撑档位**：`exact_certificate` 要求 `verdict == "VERIFIED"`（来自
   `opl-certcheck`）；`lean_checked` 要求 `verdict == "proved"`（来自 `opl-leancheck`）。
   一份「未通过」的记录不能用来升档。
3. **记录与输入绑定**：记录里引用的文件（`certificate` / `formula` / `file` / `witness`）
   必须存在，且**其 sha256 与记录里写的一致**。这一条挡的是「记录是真的、但它说的是
   另一个文件」——证书被换掉之后旧记录就自动失效。

**残留缺口，如实写在这里**：以上都挡不住「手写一份格式正确的记录」——那需要验证器
签名，而当前没有密钥体系。所以本模块保证的是「这是某个验证器对**这些字节**的判决」，
不是「某个验证器真的说过」。台账会把证据文件自身的 sha256 记进 history，让事后篡改
可见（`evidence_sha256`），但可见 ≠ 阻止。要真正关闭这个缺口得先有签名，那是另一个
设计决定，不在台账里悄悄假装。

== 人工确认与机器判决分列 ==

`faithfulness_checked`（陈述忠实度）与 `human_peer_reviewed` 是**人的判断**，不是验证器
的输出。它们必须带 `--confirmed-by`，并写进独立的 `human_confirmations` 列表——
不与机器判决混在同一列。理由：实测自动形式化的语义正确率约 76%，把「编译通过」
与「忠实」写进同一个字段，正是这个项目要防的那类混淆。

本模块不做 I/O 输出、不解析 argv——那些在 `bin/opl-conj`。这样它可 import、
可单测、可被类型检查（`bin/` 下的无扩展名文件是类型检查的盲区）。
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Required, TypedDict

STATUSES = ["open", "proved_by_hand", "disproved"]
FORMAL_STATUSES = ["open", "refuted", "proved", "no_counterexample_in_range", "inconclusive"]
FORMALIZATION = ["none", "draft", "compiles", "faithfulness_checked"]
LEVELS = ["empirical", "exact_certificate", "lean_checked", "human_peer_reviewed"]

# 证据记录的 schema；由 `opl-certcheck` / `opl-leancheck` / `opl-encode` 产生。
EVIDENCE_SCHEMA = "opl.evidence/1"

# 档位 → 该档位要求的机器判决。不在表里的档位不走机器判决：
# `empirical` 不需要证据；`human_peer_reviewed` 要人工确认（见 HUMAN_LEVEL）。
LEVEL_VERDICTS: dict[str, frozenset[str]] = {
    "exact_certificate": frozenset({"VERIFIED"}),
    "lean_checked": frozenset({"proved"}),
}

# 需要人工确认的档位与状态：它们的依据是「人看过」，不是验证器的输出。
HUMAN_LEVEL = "human_peer_reviewed"
HUMAN_FORMALIZATION = "faithfulness_checked"

# 结论方向 ↔ 证据种类：**证据必须支持它被用来支持的那个结论**。
# 一份「见证求值通过」的记录说的是「这个见证满足规格」，它说不了「该范围内没有反例」；
# 反过来，一份不可满足证书也说不了「存在反例」。拿错方向的证据去支撑结论，
# 就是在用真证据说假话。
CONCLUSION_EVIDENCE: dict[str, tuple[str | None, str | None]] = {
    "refuted": ("witness_eval", "VERIFIED"),
    "no_counterexample_in_range": ("cert", "VERIFIED"),
    "proved": ("lean_audit", "proved"),
    "open": (None, None),          # 不声称结论，不需要证据
    "inconclusive": (None, None),
}

# 结论 → 它能支撑的档位（再由证据是否合格决定能否真给到这一档）
CONCLUSION_LEVEL: dict[str, str] = {
    "refuted": "exact_certificate",
    "no_counterexample_in_range": "exact_certificate",
    "proved": "lean_checked",
}

# 证据记录里「文件字段 → 哈希字段」的对应。**按种类必填**：缺了就拒，不跳过。
# 早先的写法是「有就查，没有就跳过」，于是一份只写了 schema 与 verdict 的 JSON
# 也能支撑 exact_certificate——那等于给「随便写个文件」开了后门。
EVIDENCE_BINDINGS: tuple[tuple[str, str], ...] = (
    ("certificate", "certificate_sha256"),
    ("formula", "formula_sha256"),
    ("file", "file_sha256"),
    ("witness", "witness_sha256"),
    ("spec", "spec_sha256"),
)

# 每种证据**必须**带哪些绑定字段
KIND_REQUIRED_BINDINGS: dict[str, tuple[tuple[str, str], ...]] = {
    "cert": (("certificate", "certificate_sha256"), ("formula", "formula_sha256")),
    "witness_eval": (("witness", "witness_sha256"), ("spec", "spec_sha256")),
    "lean_audit": (("file", "file_sha256"),),
}


class LedgerError(Exception):
    """记录或参数不合法。调用方翻成 USAGE（退出码 2）。"""


@dataclass
class Evidence:
    """一份校验过的证据记录。`sha256` 是**文件本身**的哈希，进 history 供事后比对。"""

    path: str
    sha256: str
    verdict: str
    level: str | None
    kind: str | None
    record: dict[str, Any]


class Source(TypedDict):
    url: str | None
    attribution: str | None
    retrieved_at: str


# `from` 是 Python 关键字，类语法写不出来，所以用函数式形式。
HistoryEntry = TypedDict("HistoryEntry", {
    "at": str, "field": str, "from": Any, "to": Any,
    "evidence": str | None, "run_id": str | None, "evidence_sha256": str | None,
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
    human_confirmations: list[dict[str, Any]]
    source: Source
    status: str


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


# ------------------------------------------------------------------ 证据校验


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_evidence(path: str | None, *, required_level: str | None = None,
                  subject: str | None = None, expect_kind: str | None = None,
                  expect_range: str | None = None,
                  expect_subject: str | None = None) -> Evidence:
    """读并校验一份证据记录。任何一处不合格都抛 `LedgerError`，理由写到点上。

    `path` 允许为 `None`：**「没给指针」也是在这一层被拒的**。升档却什么都不带，
    是最该拦下的那一种，把它留在这里处理比让每个调用方各写一遍更不容易漏。

    `subject` 只是给报错用的对象名（猜想 id 之类），不参与判定——台账不假装知道
    证据应该长什么样才算「对得上这个命题」，那需要验证器把命题写进记录里。
    """
    who = f"（对象 {subject}）" if subject else ""
    if not path:
        raise LedgerError(f"缺少证据指针{who}")
    if not os.path.isfile(path):
        raise LedgerError(f"证据文件不存在{who}：{path}")
    try:
        with open(path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except json.JSONDecodeError as exc:
        raise LedgerError(f"证据文件不是合法 JSON{who}：{path}:{exc.lineno}: {exc.msg}") from exc
    if not isinstance(rec, dict):
        raise LedgerError(f"证据记录的顶层应为对象{who}，实为 {type(rec).__name__}")
    schema = rec.get("schema")
    if schema != EVIDENCE_SCHEMA:
        raise LedgerError(
            f"证据记录的 schema 是 {schema!r}，本台账只认 {EVIDENCE_SCHEMA!r}{who}。"
            f"手写的自由文本、或验证器以外的产物，都不是证据。")
    verdict = rec.get("verdict")
    if required_level is not None:
        want = LEVEL_VERDICTS.get(required_level)
        if want is not None and verdict not in want:
            raise LedgerError(
                f"证据记录的判决是 {verdict!r}，不足以支撑 {required_level}{who}；"
                f"该档位需要 {sorted(want)}。"
                f"（`none` / `UNKNOWN` / `NOT VERIFIED` / `sorry_ax` 都属此列）")
    # 种类与方向：这份证据讲的是哪一类事实
    kind = rec.get("kind")
    if expect_kind is not None and kind != expect_kind:
        raise LedgerError(
            f"证据的种类是 {kind!r}，而这个结论需要 {expect_kind!r}{who}。"
            f"一份「见证求值通过」说不了「该范围内没有反例」，反过来也一样——"
            f"拿错方向的证据去支撑结论，就是在用真证据说假话。")
    # 对象：这份证据是为哪个猜想出的
    if expect_subject is not None and rec.get("subject") != expect_subject:
        raise LedgerError(
            f"证据的 subject 是 {rec.get('subject')!r}，而这次要记的是 "
            f"{expect_subject!r}{who}。没有这一项，一份真证据可以给**另一个**猜想背书。")
    # 范围：结论里那句「某范围内」必须与证据里的一致
    if expect_range is not None and str(rec.get("range") or "") != expect_range:
        raise LedgerError(
            f"证据记录的 range 是 {rec.get('range')!r}，而登记的范围是 "
            f"{expect_range!r}{who}。范围不一致时，「该范围内没有反例」这句话无法核对。")
    # 绑定性：**按种类必填**，缺了就拒
    required = KIND_REQUIRED_BINDINGS.get(str(kind), ())
    for file_key, hash_key in required:
        if not rec.get(file_key) or not rec.get(hash_key):
            raise LedgerError(
                f"{kind!r} 类证据必须带 {file_key!r} 与 {hash_key!r}{who}——"
                f"缺了它们，这份记录没有绑定到任何输入。")
    for file_key, hash_key in EVIDENCE_BINDINGS:
        f, h = rec.get(file_key), rec.get(hash_key)
        if not f or not h:
            continue
        if not os.path.isfile(f):
            raise LedgerError(f"证据引用的文件不存在{who}：{f}")
        got = sha256_file(f)
        if got != h:
            raise LedgerError(
                f"证据与文件对不上{who}：{f}\n  记录写的是 {h[:16]}…，实际是 {got[:16]}…\n"
                f"  记录过期或被改过——旧记录不该继续给新文件背书。")
    return Evidence(path=path, sha256=sha256_file(path), verdict=str(verdict),
                    level=rec.get("verification_level"), kind=kind, record=rec)


def require_human(confirmed_by: str | None, what: str) -> dict[str, Any]:
    """人工确认项的守卫。**机器判决不能替代人的复核**，所以这里只要人签字。"""
    if not confirmed_by or not confirmed_by.strip():
        raise LedgerError(
            f"拒绝写入：{what} 是人工确认项，必须带 --confirmed-by <谁>。"
            f"理由：实测自动形式化的语义正确率约 76%，编译通过看不出那 24%——"
            f"工具不会替你下这个判断，也不会接受一个空的签字。")
    return {"at": now_iso(), "by": confirmed_by.strip(), "what": what}


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
                     "evidence": None, "run_id": None, "evidence_sha256": None}],
    }


def _touch(rec: Conjecture, field: str, old: Any, new: Any, *,
           evidence: str | None, run_id: str | None,
           evidence_sha256: str | None = None) -> None:
    rec.setdefault("history", []).append({
        "at": now_iso(), "field": field, "from": old, "to": new,
        "evidence": evidence, "run_id": run_id,
        "evidence_sha256": evidence_sha256,
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
                  confirmed_by: str | None = None,
                  confirmation_note: str | None = None,
                  ) -> tuple[Conjecture, list[str]]:
    """把一批改动应用到记录上，返回 (记录, 警告列表)。

    两级硬规则，都由代码拦而不是靠提示词劝：

    1. **任何状态变更都必须带 evidence 指针**，否则抛 `LedgerError`。
    2. **档位不能没有依据地升**：升到 `exact_certificate` / `lean_checked` 时，
       指针必须指向一份判决支撑该档位的结构化证据记录（见 `load_evidence`）；
       升到 `human_peer_reviewed`、或写 `faithfulness_checked`，必须带
       `--confirmed-by`（见 `require_human`）。

    可容忍的情形（反例缺证据、证据不足）走警告：**记下来，但记成 UNVERIFIED**，
    不拒收——台账的价值之一是留住「试过但没成」的事实。拒收与降级是两件事。
    """
    if (formal_status or informal_status) and not evidence:
        raise LedgerError(
            "拒绝写入：状态变更必须带 --evidence <指针>。"
            "没有证据指针的状态变更正是本项目要防的自欺。")

    warnings: list[str] = []
    # 先验证据，再落字段：验不过就什么都不改，避免半个变更留在记录里。
    ev: Evidence | None = None
    if verification_level:
        if verification_level not in LEVELS:
            raise LedgerError(f"非法 verification_level，允许：{', '.join(LEVELS)}")
    if formal_status:
        if formal_status not in FORMAL_STATUSES:
            raise LedgerError(f"非法 formal_status，允许：{', '.join(FORMAL_STATUSES)}")

    # == 每次改结论都重新校验证据 ==
    #
    # 上一版只在**显式传 --verification-level** 时才验证据，于是「改结论 + 一个不存在的
    # 证据路径」拿得到退出码 0，而旧的高档位（exact_certificate）**原样保留**——
    # 换了个结论，徽章没换。所以这里把「改结论」本身当成一次重新校验：
    # 证据必须支持**新结论的方向**，档位由此**重新定**，而不是继承。
    #
    # 触发条件是**显式改结论**（传了 `--formal-status`），不是「任何一次 set」：
    # 加一个反例、写一次 formalization_status 都不改变已经成立的那个结论，
    # 不该因此把记录打回原形（实测踩到：加反例与写签字都被这条误拦）。
    pending = formal_status if formal_status else None
    want_kind, want_verdict = CONCLUSION_EVIDENCE.get(str(pending), (None, None))
    level_from_evidence: str | None = None
    if formal_status and want_kind is not None:
        want_range = None
        if pending == "no_counterexample_in_range":
            # 范围必须一起核：只说「某范围内没有反例」而不说范围，等于什么都没说。
            if verified_range:
                lo, hi = _parse_range(verified_range)
                want_range = f"{lo}..{hi}"
            else:
                existing = rec.get("verified_range") or {}
                if existing.get("lo") is not None:
                    want_range = f"{existing['lo']}..{existing['hi']}"
            if want_range is None:
                raise LedgerError(
                    "登记 no_counterexample_in_range 必须带 --verified-range："
                    "「没找到」只在说清在哪个范围内时才有意义")
        ev = load_evidence(evidence, required_level="exact_certificate"
                           if want_kind != "lean_audit" else "lean_checked",
                           subject=rec.get("id"), expect_kind=want_kind,
                           expect_range=want_range, expect_subject=rec.get("id"))
        if ev.verdict != want_verdict:
            raise LedgerError(
                f"证据的判决是 {ev.verdict!r}，不足以支撑结论 {pending!r}"
                f"（需要 {want_verdict!r}）")
        level_from_evidence = CONCLUSION_LEVEL.get(str(pending))

    if formal_status:
        _touch(rec, "formal_status", rec.get("formal_status"), formal_status,
               evidence=evidence, run_id=run_id,
               evidence_sha256=ev.sha256 if ev else None)
        rec["formal_status"] = formal_status
        # 档位**重新定**，不继承。证据支持到哪一档就是哪一档；没证据就是 empirical。
        # 这一步是「换结论不换徽章」那个 bug 的正面修法。
        new_level = level_from_evidence or "empirical"
        if rec.get("verification_level") != new_level:
            _touch(rec, "verification_level", rec.get("verification_level"), new_level,
                   evidence=evidence, run_id=run_id,
                   evidence_sha256=ev.sha256 if ev else None)
            rec["verification_level"] = new_level
            warnings.append(
                f"结论改成 {formal_status!r} 后，档位按新证据重新定为 {new_level!r}"
                f"（不再继承旧档位）")
    if informal_status:
        if informal_status not in STATUSES:
            raise LedgerError(f"非法 informal_status，允许：{', '.join(STATUSES)}")
        _touch(rec, "informal_status", rec.get("informal_status"), informal_status,
               evidence=evidence, run_id=run_id,
               evidence_sha256=ev.sha256 if ev else None)
        rec["informal_status"] = informal_status

    if formalization_status:
        if formalization_status not in FORMALIZATION:
            raise LedgerError(f"非法 formalization_status，允许：{', '.join(FORMALIZATION)}")
        if formalization_status == HUMAN_FORMALIZATION:
            # 人工确认单独建模：不进 history 的证据列，进 human_confirmations
            conf = require_human(confirmed_by, f"formalization_status={HUMAN_FORMALIZATION}")
            if confirmation_note:
                conf["note"] = confirmation_note
            rec.setdefault("human_confirmations", []).append(conf)
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
        # 反例的「独立复核」必须由证据支撑。以前只要 evidence 非空就写 independent，
        # 于是随便一个字符串就能给反例盖上一个复核章——那是直接伪造复核。
        entry: dict[str, Any] = {"witness": witness, "certificate": evidence,
                                 "recorded_at": now_iso()}
        if evidence:
            try:
                ev2 = load_evidence(evidence, required_level="exact_certificate",
                                    subject=rec.get("id"))
            except LedgerError as exc:
                entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
                warnings.append(f"反例 {witness!r} 的证据不足以支撑独立复核，"
                                f"记为 UNVERIFIED：{exc}")
            else:
                entry |= {"verified_by": "independent",
                          "verification_level": "exact_certificate",
                          "evidence_sha256": ev2.sha256}
        else:
            entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
            warnings.append(f"反例 {witness!r} 没有证书指针，请补 --evidence")
        rec.setdefault("counterexamples", []).append(entry)

    if verification_level:
        if verification_level == HUMAN_LEVEL:
            conf = require_human(confirmed_by, f"verification_level={HUMAN_LEVEL}")
            if confirmation_note:
                conf["note"] = confirmation_note
            rec.setdefault("human_confirmations", []).append(conf)
        elif verification_level != "empirical":
            # 显式升档：证据要支撑得住。这里与上面的「结论驱动」是两条路，
            # 但用的是同一套证据校验。
            ev2 = load_evidence(evidence, required_level=verification_level,
                                subject=rec.get("id"))
            ev = ev2
        _touch(rec, "verification_level", rec.get("verification_level"),
               verification_level, evidence=evidence, run_id=run_id,
               evidence_sha256=ev.sha256 if ev else None)
        rec["verification_level"] = verification_level

    return rec, warnings

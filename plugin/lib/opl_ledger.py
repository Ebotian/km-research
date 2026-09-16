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


class SignError(RuntimeError):
    """签名器不可用，或签名/验签失败。调用方翻成 MISSING（退出码 4）。

    单独一个异常类型而不是复用 `LedgerError`：这两件事的出路不同——「记录不自洽」要
    去修记录，「没有签名器」要去配密钥（或换台机器）。把它们并成一个码，用户会在一件
    与参数无关的事情上来回改参数。
    """


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
    evidence: dict[str, Any]
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
    # 种类必须是**已知**的：未知或缺失的 kind 会让「按种类必填绑定」的集合变成空集，
    # 于是一份只写了 schema+verdict 的 JSON 也能升档（实测复现过）。
    if kind is None or kind not in KIND_REQUIRED_BINDINGS:
        raise LedgerError(
            f"证据记录的 kind 是 {kind!r}，不是已知的证据种类 "
            f"{sorted(KIND_REQUIRED_BINDINGS)}{who}。缺失或未知的种类无法确定该要求"
            f"哪些绑定字段——那正是「随便写个文件」能升档的原因。")
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
    # == 最后一道：这份证据是**谁写的** ==
    #
    # 前面所有检查加起来证明的是「这份文件自洽」：字段齐全、方向对、哈希与它引用的
    # 文件对得上。而哈希是**自证**的——写文件的人同时写了被引用的文件，于是手写一份
    # 自洽的假证据可以全部通过（实测：手写的 `{"kind":"witness_eval","verdict":
    # "VERIFIED",…}` 曾被台账全盘接受，把猜想定成 refuted / exact_certificate）。
    # `verdict` 只是文件里的一行字，没有任何东西验过它；签名才是「这句话是谁说的」。
    #
    # 放在**最后**而不是最前：结构性问题更常见、更好修，理由也更具体；先把「字段缺了」
    # 说清楚，比先甩一句「没签名」有用。顺序不影响强度——签名不过照样拒。
    from opl_sign import verify_file

    ok, why = verify_file(path)
    if not ok:
        raise LedgerError(
            f"这份证据没有可信的签名{who}：{why}\n"
            f"  证据必须由产出它的命令（opl-certcheck / opl-encode --eval-witness / "
            f"opl-leancheck）写盘时签出；手写的 JSON 与工具写出的 JSON 在这里必须分得开。\n"
            f"  本机还没有密钥就跑 `opl-sign init`；证据来自别的机器，就把那边的公钥"
            f"用 `opl-sign trust` 加进验签清单。")
    return Evidence(path=path, sha256=sha256_file(path), verdict=str(verdict),
                    level=rec.get("verification_level"), kind=kind, record=rec)


def adopt_unsupported(rec: Conjecture, *, confirmed_by: str | None,
                      note: str | None = None) -> tuple[Conjecture, list[str]]:
    """收编一条**签名核不过**的记录：保住事实，**降掉撑不住的结论**。

    为什么要能收编：记录由 `save()` 写出时签名，所以「签名核不过」只有三种来路——
    手写的、被工具之外的东西改过、从别处拷来的。没有出路的话，用户会去手改文件，
    而那正是最该避免的动作；或者他会另建一条记录，于是原来那条的边界、反例、历史
    全丢。收编给的是第三条路：**人签字负责这份内容，同时把无法支持的声称降下来**。

    降级是级联的，每一步都记进 history，且每一步之后重新校验：

    1. 档位压回 `empirical`；
    2. 还不行就把结论退回 `open`（结论是「声称一个事实」，撑不住就不能留）；
    3. 还不行就把**核不过的复核章**降成 `UNVERIFIED`。

    三条走完仍不自洽就如实抛错——那是别的问题，收编不该替它兜底。
    """
    import copy

    cand: Conjecture = copy.deepcopy(rec)
    warnings: list[str] = []
    conf = require_human(confirmed_by, "adopt-unsigned-record")
    conf["note"] = note or "签名核不过，人工确认内容后收编"
    cand.setdefault("human_confirmations", []).append(conf)

    if not validate_record(cand):
        return cand, warnings

    lvl = cand.get("verification_level")
    if lvl not in (None, "empirical"):
        _touch(cand, "verification_level", lvl, "empirical", evidence=None, run_id=None)
        cand["verification_level"] = "empirical"
        warnings.append(f"收编时档位从 {lvl!r} 压回 'empirical'——核不过的依据撑不起档位")
    if not validate_record(cand):
        return cand, warnings

    st = cand.get("formal_status")
    if st not in (None, "open"):
        _touch(cand, "formal_status", st, "open", evidence=None, run_id=None)
        cand["formal_status"] = "open"
        warnings.append(f"收编时结论从 {st!r} 退回 'open'——"
                        f"拿不到可信签名的依据，就不能继续声称这个结论")
    if not validate_record(cand):
        return cand, warnings

    stamped = [c for c in cand.get("counterexamples") or []
               if c.get("verified_by") == "independent"]
    for c in stamped:
        c["verified_by"] = "UNVERIFIED"
        c["verification_level"] = "empirical"
    if stamped:
        warnings.append(f"收编时 {len(stamped)} 个复核章降成 UNVERIFIED——"
                        f"它们引用的证据现在验不过，章就立不住")
    problems = validate_record(cand)
    if problems:
        raise LedgerError("这条记录收编之后仍然不自洽，请先修好它：\n  - "
                          + "\n  - ".join(problems))
    return cand, warnings


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
    """原子写入 + **签名**：先写 `.tmp` 再 replace，然后给记录签一份 `<path>.sig`。

    为什么写在库层而不是命令层：签名是「这份记录是工具写的」这个判据的唯一来源，
    绕过它的入口一个都不该有。签名器不可用就**不写**（抛 `SignError`）——半个承诺比
    没有承诺更坏：盘上留着一份没签名的记录，读的时候分不出它和手写的 JSON。
    """
    from opl_sign import sign_file, signer_state

    state, why = signer_state()
    if state != "ready":
        raise SignError(f"没有可用的签名器，拒绝写台账：{why}")
    d = conj_dir(lab)
    os.makedirs(d, exist_ok=True)
    p = record_path(rec["id"], lab)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, p)
    try:
        sign_file(p)
    except SignError:
        # 写成了但没签上：把这份半成品清掉，连同可能遗留的旧签名（否则盘上会留下一份
        # 「有签名、但签名不是这份内容」的记录，读的人会以为它可信）。
        for stale in (p, p + ".sig"):
            if os.path.exists(stale):
                os.unlink(stale)
        raise
    return p


def record_provenance(cid: str, lab: str | None = None) -> tuple[bool, str]:
    """这条记录的签名可信吗？返回 (是否可信, 理由)。

    **没有签名也是「不可信」**：本插件的记录由 `save()` 写、写完即签；盘上一条没有
    签名的记录，只可能是手写的、从别处拷来的、或者被外部程序改过。读的人有权知道
    自己看的是一份「工具写的」还是「来历不明的」文件。
    """
    from opl_sign import verify_file

    p = record_path(cid, lab)
    if not os.path.isfile(p):
        return False, f"记录不存在：{p}"
    return verify_file(p)


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


def _check_counterexamples(rec: Conjecture, why: list[str]) -> None:
    """反例的复核章：**独立于主结论**，而且必须当场还能立得住。

    第四轮审阅 F1 抓到的就是「独立」与「当场」这两件事都没做到：

    * `validate_record` 在主结论不声称事实（`open`）时**提前返回**，于是反例的约束
      在那种记录上根本不执行——约束跟着主结论的取值走，本身就是个缺口；
    * 只要证据读得出来、种类是 `witness_eval`、见证名一样就盖章，**不看判决、不看对象**。
      实测两种假复核：一份 `verdict: NOT VERIFIED` 的见证（全零赋值违反规格）拿到
      `independent`；一份 `subject: OTHER` 的有效证据也能给本猜想盖章。
    * 记录里只剩一个摘要（`evidence_sha256`），**不重读证据**。凭空写一个哈希就能
      让章看起来有出处；而真正的办法是让它**每次写入都重新核一遍**——章的价值就在于
      事后还能复查，不能被复查的章只是字符串。
    """
    for c in rec.get("counterexamples") or []:
        if c.get("verified_by") != "independent":
            continue
        w = str(c.get("witness"))
        if not c.get("evidence_sha256"):
            why.append(f"反例 {w[:40]!r} 声称独立复核，却没有记下所依据证据的哈希"
                       f"——一次没有 artifact 的复核")
            continue
        vw = c.get("verified_witness")
        if not vw:
            why.append(f"反例 {w[:40]!r} 声称独立复核，却没记下被验证的是哪份见证")
            continue
        if str(vw) != w:
            why.append(f"反例写的是 {c.get('witness')!r}，复核章却来自见证 {vw!r}"
                       f"——章盖在了另一份见证上")
            continue
        cert = c.get("certificate")
        if not cert or not os.path.isfile(str(cert)):
            why.append(f"反例 {w[:40]!r} 的复核章指向的证书读不到（{cert!r}）"
                       f"——复核章必须能当场复核，读不该走的证书记不了独立复核")
            continue
        try:
            cev = load_evidence(str(cert), subject=rec.get("id"),
                                expect_subject=rec.get("id") or None,
                                required_level="exact_certificate")
        except LedgerError as exc:
            why.append(f"反例 {w[:40]!r} 的复核章现在核不过：{exc}")
            continue
        if cev.sha256 != c.get("evidence_sha256"):
            why.append(f"反例 {w[:40]!r} 的证书文件被换过：章底下记的是 "
                       f"{str(c.get('evidence_sha256'))[:16]}…，现在这份是 "
                       f"{cev.sha256[:16]}…")
        elif str(cev.record.get("witness")) != w:
            why.append(f"这份证据验证的见证是 {cev.record.get('witness')!r}，"
                       f"不是盖章的 {w!r}")


def validate_record(rec: Conjecture) -> list[str]:
    """检查**修改后的完整记录**是否自洽。返回违规列表，空列表表示合格。

    为什么校验的对象是「记录」而不是「这次传了哪些参数」：二轮审阅的教训是
    **检查绑定在某些参数上，而不是修改后的记录上**，于是每个没传参数的入口都成了一个
    缺口——实测三条：

    * 只改 `verified_range`（不给新证据）→ 范围扩了 10 万倍，`exact_certificate` 原样保留；
    * 只升档 + 一份 `{{"schema", "verdict"}}` 的最小 JSON → 因为缺少 `kind`，必填绑定
      集合是空的，于是「随便写个文件」也能升到 `lean_checked`；
    * 追加反例时给一份**别的**见证的证据 → 那个无关文件照样被标成 `verified_by=independent`。

    逐条给命令参数补条件的做法会一直漏（每加一个参数就多一个入口）。所以改成一次成型：
    **先把改动全部应用到一个副本上，再检查整个副本**，不自洽就整笔拒绝、一个字段都不写。

    第四轮又补了两件「一次成型」也没覆盖的事：

    * **摘要不是证据。** `rec["evidence"]` 里存的只是路径 + 哈希 + 几个字段，校验若只
      读这份摘要，那么「把被验证的见证文件换掉、路径不变」就查不出来——记录会继续挂着
      `exact_certificate`。所以每次写入都**重新加载**那份证据，核对它自己的哈希、以及
      它引用的输入文件的哈希（`load_evidence` 本来就查后者，只是没人再调它）。
    * **`evidence_path` 参数原来收下不用**，等于把「这次给的是哪份证据」当摆设。这一版
      改成从记录里的 `path` 重新加载：记录说它依据哪份，就核哪份，不靠调用方转述。
    """
    why: list[str] = []
    # 反例的约束**先查、且与主结论无关**：主结论是 open 不代表反例可以随便盖章。
    _check_counterexamples(rec, why)

    pending = str(rec.get("formal_status", "open"))
    want_kind, want_verdict = CONCLUSION_EVIDENCE.get(pending, (None, None))
    ev = rec.get("evidence")
    humans = rec.get("human_confirmations") or []
    human_level = any(h.get("what", "").startswith("verification_level") for h in humans)

    if want_kind is None:
        # 结论不声称任何事实 → 档位不该虚高
        lvl = rec.get("verification_level", "empirical")
        if lvl != "empirical" and not (lvl == HUMAN_LEVEL and human_level):
            why.append(f"结论是 {pending!r}（不声称任何事实），档位却是 {lvl!r}"
                       f"——没有依据的档位")
        return why

    if not isinstance(ev, dict) or not ev:
        why.append(f"结论是 {pending!r}，但记录里**没有**它所依据的证据"
                   f"（改范围、改形式化目标、改结论都会走到这里）")
        return why

    # == 重新加载那份证据（第四轮审阅 F2）==
    # 记录里的摘要是**过去某次写入时**抄下来的；证据文件、以及它引用的见证/公式/Lean
    # 文件都还是普通文件，事后都能被改。摘要过期了却继续当依据用，就是「路径一致」
    # 冒充「对象没变」。核不过就如实报，不拿旧摘要把结论糊过去。
    use = ev
    try:
        fresh = load_evidence(str(ev.get("path") or ""), subject=rec.get("id"),
                              expect_subject=rec.get("id") or None)
    except LedgerError as exc:
        why.append(f"依据的证据现在核不过（{ev.get('path')!r}）：{exc}")
    else:
        if fresh.sha256 != ev.get("sha256"):
            why.append(f"依据的证据文件本身被改过：记录写的是 "
                       f"{str(ev.get('sha256'))[:16]}…，现在是 {fresh.sha256[:16]}…")
        use = {"kind": fresh.kind, "verdict": fresh.verdict,
               "subject": fresh.record.get("subject"), "range": fresh.record.get("range"),
               "file": fresh.record.get("file"), "decls": fresh.record.get("decls")}

    if use.get("kind") != want_kind:
        why.append(f"依据的证据种类是 {use.get('kind')!r}，而结论 {pending!r} 需要 "
                   f"{want_kind!r}")
    if use.get("verdict") != want_verdict:
        why.append(f"依据的证据判决是 {use.get('verdict')!r}，而结论 {pending!r} 需要 "
                   f"{want_verdict!r}")
    if use.get("subject") != rec.get("id"):
        why.append(f"依据的证据 subject 是 {use.get('subject')!r}，而这条记录的 id 是 "
                   f"{rec.get('id')!r}")
    # 范围：结论里那句「某范围内」必须与证据里记的完全一致
    if pending == "no_counterexample_in_range":
        vr = rec.get("verified_range") or {}
        if vr.get("lo") is None or vr.get("hi") is None:
            why.append("no_counterexample_in_range 必须带 verified_range")
        else:
            want = f"{vr['lo']}..{vr['hi']}"
            if str(use.get("range") or "") != want:
                why.append(f"范围（range）是 {want!r}，而依据的证据记的是 "
                           f"{use.get('range')!r}——范围与证据不一致时，"
                           f"「该范围内没有反例」无法核对")
    # 形式化目标：被证明的对象变了，原来的证据就不再是它的依据。
    # **路径一致不等于对象没变**：同一个 `.lean` 文件里换个声明，就是换了被证明的命题。
    if pending == "proved":
        sf = rec.get("statement_formal") or {}
        decl = sf.get("decl")
        audited = [str(x) for x in (use.get("decls") or [])]
        # 路径按**绝对路径**比：`tests/fixtures/x.lean` 与 `/abs/tests/fixtures/x.lean`
        # 是同一个文件（实测：证据那边写的是绝对路径，这边手敲相对路径就被误判）。
        # 只比路径形态会放过「同文件换声明」，只比字符串会误伤同一个文件的两种写法。
        sf_file = os.path.abspath(str(sf["file"])) if sf.get("file") else ""
        ev_file = os.path.abspath(str(use["file"])) if use.get("file") else ""
        if sf_file and ev_file and sf_file != ev_file:
            why.append(f"形式化目标是 {sf['file']!r}，而依据的证据审的是 {use['file']!r}")
        elif not decl:
            why.append(f"结论是 proved，但记录没有点名证明了**哪个声明**"
                       f"（`--statement-formal F.lean --decl NAME`）。"
                       f"这份证据点的是 {audited or '（没点名）'}——"
                       f"不点名，就分不出「同文件里另一个定理」是不是被证明了")
        elif decl not in audited:
            why.append(f"记录声称证明的是 {decl!r}，而这份证据点的是 "
                       f"{audited or '（没点名）'}——同一个文件里换一个声明，"
                       f"就是换了一个被证明的对象")
    # 档位：不能高于该结论 + 该证据支持到的档位
    supported = CONCLUSION_LEVEL.get(pending, "empirical")
    lvl = rec.get("verification_level", "empirical")
    ok_levels = {supported, "empirical"}
    if human_level:
        ok_levels.add(HUMAN_LEVEL)
    if lvl not in ok_levels:
        why.append(f"档位是 {lvl!r}，而这个结论 + 这份证据只支持 "
                   f"{sorted(ok_levels)}")
    return why


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
    """把一批改动**事务式**地应用到记录上：构造 → 校验 → 写入。

    顺序是这次重构的全部要点：先在副本上把改动全部应用完，再检查**修改后的完整记录**
    是否自洽（`validate_record`），不合格就整笔拒绝、一个字段都不写。这样每个入口
    （改范围、改形式化目标、加反例、单独升档）都自动被同一套检查覆盖，不需要逐个
    为参数补条件——**这一轮审阅的三条缺口正是从那里来的**。

    仍然保留的两条硬规则：状态变更必须带 evidence 指针；人工确认项必须签字。
    """
    import copy

    if (formal_status or informal_status) and not evidence:
        raise LedgerError(
            "拒绝写入：状态变更必须带 --evidence <指针>。"
            "没有证据指针的状态变更正是本项目要防的自欺。")

    # == 这次改动是否**在主张一个事实** ==
    #
    # 主张事实时证据读不出来就必须拒；只是给反例附一份证书时，证据读不出来按
    # UNVERIFIED 降级。**「拒收」与「降级」是两件事**：台账的价值之一是留住
    # 「试过但没成」的事实，所以反例缺证据不该被拒之门外。
    #
    # 实测踩到（回归第 129 项）：把这一层写成「只要给了 evidence 就先读」之后，
    # `--add-counterexample n=99 --evidence 随便一个字符串` 从「记 UNVERIFIED + 警告」
    # 变成了硬拒收——正好把降级路径删掉了。
    claims_fact = bool(formal_status or informal_status
                       or (verification_level and verification_level != "empirical"))
    rec_id = rec.get("id")
    warnings: list[str] = []
    cand: Conjecture = copy.deepcopy(rec)
    ev: Evidence | None = None
    ev_ref: dict[str, Any] | None = None
    if evidence:
        try:
            # `expect_subject` 才是**核对**对象，`subject` 只是报错时显示的名字——
            # 第四轮审阅 F1 实测：只传 `subject=` 时，一份 `subject: OTHER` 的真证据
            # 照样能给出独立复核章。两个参数长得像，作用完全不同。
            ev = load_evidence(evidence, subject=rec_id,
                               expect_subject=rec_id if rec_id else None)
        except LedgerError as exc:
            if claims_fact:
                raise
            warnings.append(
                f"证据指针 {evidence!r} 读不出可用记录，而这次改动不主张事实，"
                f"按 UNVERIFIED 记下而不是拒收：{exc}")
        if ev is not None:
            ev_ref = {"path": ev.path, "sha256": ev.sha256, "kind": ev.kind,
                      "subject": ev.record.get("subject"), "verdict": ev.verdict,
                      "range": ev.record.get("range"), "file": ev.record.get("file"),
                      "decls": ev.record.get("decls"),
                      "witness": ev.record.get("witness"), "at": now_iso()}
    if formal_status:
        if formal_status not in FORMAL_STATUSES:
            raise LedgerError(f"非法 formal_status，允许：{', '.join(FORMAL_STATUSES)}")
        _touch(cand, "formal_status", cand.get("formal_status"), formal_status,
               evidence=evidence, run_id=run_id,
               evidence_sha256=ev.sha256 if ev else None)
        cand["formal_status"] = formal_status
    if informal_status:
        if informal_status not in STATUSES:
            raise LedgerError(f"非法 informal_status，允许：{', '.join(STATUSES)}")
        _touch(cand, "informal_status", cand.get("informal_status"), informal_status,
               evidence=evidence, run_id=run_id,
               evidence_sha256=ev.sha256 if ev else None)
        cand["informal_status"] = informal_status

    if formalization_status:
        if formalization_status not in FORMALIZATION:
            raise LedgerError(f"非法 formalization_status，允许：{', '.join(FORMALIZATION)}")
        if formalization_status == HUMAN_FORMALIZATION:
            conf = require_human(confirmed_by, f"formalization_status={HUMAN_FORMALIZATION}")
            if confirmation_note:
                conf["note"] = confirmation_note
            cand.setdefault("human_confirmations", []).append(conf)
        _touch(cand, "formalization_status", cand.get("formalization_status"),
               formalization_status, evidence=evidence, run_id=run_id)
        cand["formalization_status"] = formalization_status

    if statement_formal:
        cand["statement_formal"] = {"file": statement_formal, "decl": decl}

    if verified_range:
        lo, hi = _parse_range(verified_range)
        cand["verified_range"] = {"lo": lo, "hi": hi,
                                  "method": method or "unknown",
                                  "run_id": run_id,
                                  "statement": "仅在该有限域内无反例"}

    for spec in add_bound or []:
        claim, _, rest = spec.partition("=")
        value, _, src = rest.partition("@")
        cand.setdefault("known_bounds", []).append(
            {"claim": claim, "value": value, "source": src or None})

    for witness in add_counterexample or []:
        # 反例的「独立复核」必须由证据支撑，**而且必须就是这份证据验证过的那个见证**。
        # 以前只要 evidence 非空就写 independent，于是随便一个字符串、甚至一个无关的
        # 文件路径都能拿到复核标记——那是直接伪造复核。
        #
        # 第四轮审阅 F1 又指出两处：**判决**和**对象**没看。一份 `verdict: NOT VERIFIED`
        # 的见证（全零赋值违反规格）照样盖到 `independent` 上——**「证据读得出来」被当成了
        # 「证据说它成立」**；一份 `subject: OTHER` 的有效证据也能给本猜想盖章。四项缺
        # 一不可：种类、判决、对象、见证身份（对象那项在读取时由 `expect_subject` 兜住）。
        entry: dict[str, Any] = {"witness": witness, "certificate": evidence,
                                 "recorded_at": now_iso()}
        want_verdicts = LEVEL_VERDICTS.get("exact_certificate", ())
        if ev is None:
            entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
            warnings.append(f"反例 {witness!r} 没有可用的证书指针，请补 --evidence")
        elif ev.kind != "witness_eval":
            entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
            warnings.append(
                f"反例 {witness!r} 的证据种类是 {ev.kind!r}，不是 witness_eval，"
                f"记为 UNVERIFIED")
        elif str(ev.verdict) not in want_verdicts:
            # 「见证不满足规格」也是有价值的结论，但它**不是**独立复核过的反例。
            entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
            warnings.append(
                f"反例 {witness!r} 的证据判决是 {ev.verdict!r}（该档位需要 "
                f"{sorted(want_verdicts)}）——一份「没验证通过」的记录撑不起复核章，"
                f"记为 UNVERIFIED")
        elif not ev.record.get("witness"):
            entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
            warnings.append(
                f"证据 {ev.path!r} 里没有 witness 字段，无从确认它验证的是哪份见证，"
                f"反例 {witness!r} 记为 UNVERIFIED")
        elif str(ev.record.get("witness")) != str(witness):
            entry |= {"verified_by": "UNVERIFIED", "verification_level": "empirical"}
            warnings.append(
                f"反例写的是 {witness!r}，而这份证据验证的是 "
                f"{ev.record.get('witness')!r}——验证的是哪份见证，就只能给那份见证"
                f"加复核标记，记为 UNVERIFIED")
        else:
            entry |= {"verified_by": "independent",
                      "verification_level": "exact_certificate",
                      "evidence_sha256": ev.sha256,
                      "verified_witness": ev.record.get("witness")}
        cand.setdefault("counterexamples", []).append(entry)

    if verification_level:
        if verification_level not in LEVELS:
            raise LedgerError(f"非法 verification_level，允许：{', '.join(LEVELS)}")
        if verification_level == HUMAN_LEVEL:
            conf = require_human(confirmed_by, f"verification_level={HUMAN_LEVEL}")
            if confirmation_note:
                conf["note"] = confirmation_note
            cand.setdefault("human_confirmations", []).append(conf)
        _touch(cand, "verification_level", cand.get("verification_level"),
               verification_level, evidence=evidence, run_id=run_id,
               evidence_sha256=ev.sha256 if ev else None)
        cand["verification_level"] = verification_level
    elif formal_status:
        # 结论变了而没显式给档位：按新证据重新定，**不继承**旧档位
        new_level = CONCLUSION_LEVEL.get(formal_status) if ev is not None else None
        new_level = new_level or "empirical"
        if cand.get("verification_level") != new_level:
            _touch(cand, "verification_level", cand.get("verification_level"), new_level,
                   evidence=evidence, run_id=run_id,
                   evidence_sha256=ev.sha256 if ev else None)
            cand["verification_level"] = new_level
            warnings.append(f"结论改成 {formal_status!r} 后，档位按新证据重新定为 "
                            f"{new_level!r}（不再继承旧档位）")

    # == 记录的依据只在**重新确立结论**时改 ==
    #
    # `--evidence` 这一个开关身兼两职：既可能是「我改的这个结论依据它」，也可能只是
    # 「这个反例的证书是它」。后者不该把已有结论的依据换掉——换了之后
    # `validate_record` 会发现「结论是 no_counterexample_in_range，而依据的是
    # 一份 witness_eval」，于是把一次合法的加反例拒之门外（实测踩到）。
    # 反例的证书记在它自己的条目里（`certificate` / `evidence_sha256`），不抢这个位置。
    if ev_ref is not None and claims_fact:
        cand["evidence"] = ev_ref          # 记录自带它的依据

    problems = validate_record(cand)
    if problems:
        raise LedgerError("拒绝写入：修改后的记录不自洽——\n  - " + "\n  - ".join(problems))

    # 返回**新记录**而不是原地改：调用方本来就是 `rec, _ = apply_changes(rec, ...)`
    # 重新绑定，而 `TypedDict` 上没有 `clear()`。
    return cand, warnings

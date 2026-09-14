"""opl_lean —— Lean 证明的编译与*内核审计*。

判决来自内核报告的公理集合，而不是「编译通过」。这不是洁癖，是实测：

    文件                退出码   #print axioms
    干净证明（norm_num）   0      [propext]
    sorry                0      [sorryAx]
    native_decide        0      [<定理名>._native.native_decide.ax_1_1]
    错误证明              1      （无）

**`sorry` 与 `native_decide` 都退出 0。** 所以「编译通过」完全不能作为「命题已证」
的证据——这与 `cake_lpr`、`carcara` 是同一类陷阱：工具的退出码不携带我们要的那个
区别。本模块因此只把退出码用于区分「编译失败」，证明状态一律以公理集合判定。

两条通道互补，缺一不可：

* *定理级*：`#print axioms <decl>` 给出该定理依赖的公理。白名单用**子集**判定——
  `{propext, Classical.choice, Quot.sound}` 之外的任何名字都判未证明。
  `native_decide` 会生成形如 `<decl>._native.native_decide.ax_N_M` 的公理，
  因此不需要为它特判：它只是不在白名单里。
* *文件级*：`kind == "hasSorry"` 的诊断。实测它能抓到 `#print axioms` 覆盖不到的
  `sorry`（文件里另一个没被点名的声明）。只看定理级会漏掉这些。
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from dataclasses import dataclass, field

from opl_common import find_tool, run

# 允许的公理。用子集判定而非黑名单——黑名单永远漏，白名单只会误严。
AXIOM_WHITELIST = frozenset({"propext", "Classical.choice", "Quot.sound"})

# 判定结果。四值而非三值：`native_decide` 与 `sorry` 都不是「有 sorry」，
# 合成一个标签会让失败原因无法定位。
PROVED = "proved"
SORRY_AX = "sorry_ax"
UNPROVED_AXIOMS = "unproved_axioms"
FAILED = "failed"

_AXIOM_RE = re.compile(r"'(?P<decl>[^']+)' depends on axioms: \[(?P<axioms>[^\]]*)\]")


class LeanError(Exception):
    """调用 Lean 之前就失败，或 Lean 不可用。调用方翻成退出码。"""


class ToolchainUnpinned(LeanError):
    """目标目录及其祖先均无 lean-toolchain。

    这时**绝不能调用** lean/lake：elan 的 default_toolchain = "stable" 会让每次
    调用都联网解析版本。两轮实测，同一命令在无 lean-toolchain 的目录里分别是
    5.0 / 3.0 / 5.0 秒与 12.0 / 3.0 / 9.9 秒（后一轮有一次撞上 12 秒上限），
    定点后是 0.02 秒——**每次都是数秒量级，且哪一次卡住纯看网络**。
    在离线环境下还会直接卡住。所以这里直接拒绝运行，让调用方报错。
    """


@dataclass
class LeanAudit:
    verdict: str = FAILED
    axioms: dict[str, list[str]] = field(default_factory=dict)
    offending: dict[str, list[str]] = field(default_factory=dict)
    sorries: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    project: str = ""
    toolchain: str = ""
    elapsed_ms: int = 0
    exit_code: int | None = None
    # 超时*不是*判决，而是「没有判决」。单列一个字段，让调用方先看它再决定
    # 退出码——把超时塞进 verdict 会把「没跑出来」和「跑出来是错的」混为一谈。
    timed_out: bool = False
    notes: list[str] = field(default_factory=list)


# ------------------------------------------------------------------ 项目解析


def find_toolchain(start: str) -> tuple[str, str] | None:
    """从 start 向上找 lean-toolchain，返回 (目录, 内容)。找不到返回 None。"""
    d = os.path.abspath(start)
    while True:
        f = os.path.join(d, "lean-toolchain")
        if os.path.isfile(f):
            try:
                return d, open(f, encoding="utf-8").read().strip()
            except OSError:
                return d, ""
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def resolve_project(explicit: str | None = None) -> tuple[str, str]:
    """确定要在哪个 Lean 项目里跑，并*强制*要求 toolchain 已定点。

    返回 (项目目录, toolchain 内容)。未定点时抛 ToolchainUnpinned。
    """
    from opl_common import plugin_root

    cand = (explicit or os.environ.get("OPL_LEAN_PROJECT")
            or os.path.join(plugin_root(), "lean"))
    if not os.path.isdir(cand):
        raise LeanError(f"Lean 项目目录不存在：{cand}；"
                        f"设 OPL_LEAN_PROJECT 或把项目链到 <plugin>/lean")
    found = find_toolchain(cand)
    if found is None:
        raise ToolchainUnpinned(
            f"{os.path.realpath(cand)} 及其祖先都没有 lean-toolchain。"
            f"拒绝运行：elan 的 default_toolchain = stable 会让每次调用联网解析版本"
            f"（实测每次数秒且随机，最坏一次 12 秒撞上限），离线时还会卡住。"
            f"在该项目里放一个 lean-toolchain 再试。")
    return os.path.realpath(found[0]), found[1]


# ------------------------------------------------------------------ 审计


def audit(lean_file: str, *, project: str | None = None,
          decls: list[str] | None = None, timeout: float = 300.0) -> LeanAudit:
    """编译一个 .lean 文件并审计其证明状态。

    `decls` 里给的定理名会被追加为 `#print axioms <name>` 行（写在临时副本里，
    不动原文件）。若原文件已经自己写了 `#print axioms`，这里会给出去重后的结果。
    """
    if not os.path.isfile(lean_file):
        raise LeanError(f"Lean 文件不存在：{lean_file}")

    # 先看 Lean 装了没有。「系统里没有 lake」报 MISSING(4) 比报「项目未定点」准确
    # ——后者会让人去翻项目目录，而问题其实在系统侧。两个都错时才无所谓顺序。
    lake = find_tool("lake")
    if lake is None:
        raise LeanError("找不到 lake（Lean 工具链未安装？）")
    proj, toolchain = resolve_project(project)
    target = os.path.abspath(lean_file)
    tmp = None
    if decls:
        # 追加到*副本*，绝不改用户的文件。
        body = open(target, encoding="utf-8").read()
        extra = "".join(f"\n#print axioms {d}\n" for d in decls)
        fd, tmp = tempfile.mkstemp(suffix=".lean", prefix="opl_leancheck_")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body + extra)
        target = tmp

    res = LeanAudit(project=proj, toolchain=toolchain)
    try:
        # cwd 必须是*定点*的项目目录 —— 否则 elan 每次联网解析 stable。
        rc, out, err = run([lake, "env", "lean", "--json", target],
                           timeout=timeout, cwd=proj)
        if rc is None:
            res.timed_out = True
            res.notes.append(
                f"超时：{timeout}s 内未返回。这是「暂不可用」而非「不可用」——"
                f"调用方应据此报 UNKNOWN(3)，且*不要*把它缓存成后端缺失。")
            return res
        res.exit_code = rc
        text = out.decode("utf-8", "replace")
        if err.strip():
            res.notes.append("stderr：" + err.decode("utf-8", "replace").strip()[:300])
        _parse_jsonl(text, res)
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)

    res.verdict = _decide(res)
    return res


def _parse_jsonl(text: str, res: LeanAudit) -> None:
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        if msg.get("kind") == "hasSorry":
            pos = msg.get("pos") or {}
            res.sorries.append(f"line {pos.get('line', '?')}")

        if msg.get("severity") == "error":
            data = (msg.get("data") or "").strip().splitlines()
            pos = msg.get("pos") or {}
            res.errors.append(f"line {pos.get('line', '?')}: {data[0] if data else '?'}")

        data = msg.get("data") or ""
        m = _AXIOM_RE.search(data)
        if m:
            names = [a.strip() for a in m.group("axioms").split(",") if a.strip()]
            res.axioms[m.group("decl")] = names
        else:
            # Lean 对*无公理*的证明打印的是「does not depend on any axioms」，
            # 而不是「depends on axioms: []」。漏掉这条措辞会把一个干净的已证明
            # 文件判成「无法判定」——这是实测踩出来的。
            m2 = re.search(r"'(?P<decl>[^']+)' does not depend on any axioms", data)
            if m2:
                res.axioms[m2.group("decl")] = []


def _decide(res: LeanAudit) -> str:
    """四值判定。顺序重要：编译失败优先，其次 sorry，再次非白名单公理。"""
    if res.exit_code != 0 or res.errors:
        return FAILED
    res.offending = {d: ax for d, ax in res.axioms.items()
                     if not set(ax) <= AXIOM_WHITELIST}
    if res.sorries:
        # 文件级通道：能抓到 #print axioms 覆盖不到的 sorry。
        return SORRY_AX
    if any("sorryAx" in ax for ax in res.offending.values()):
        return SORRY_AX
    if res.offending:
        return UNPROVED_AXIOMS
    if not res.axioms:
        res.notes.append("没有任何 #print axioms 输出：无法判定证明状态。"
                         "用 --decl <定理名> 点明要审计的定理。")
        return UNPROVED_AXIOMS
    return PROVED


def describe(res: LeanAudit) -> str:
    """一行人类可读的判决说明，供 stderr。"""
    if res.verdict == PROVED:
        names = ", ".join(f"{d}→{ax}" for d, ax in res.axioms.items())
        return f"内核接受且公理落在白名单内（{names}）"
    if res.verdict == SORRY_AX:
        where = f"文件级 sorry {len(res.sorries)} 处" if res.sorries else "定理依赖 sorryAx"
        return f"未证明：{where}"
    if res.verdict == UNPROVED_AXIOMS:
        bad = ", ".join(f"{d}→{ax}" for d, ax in res.offending.items())
        return f"未证明：依赖白名单外的公理（{bad or '无公理信息'}）"
    first = res.errors[0] if res.errors else "（无错误诊断）"
    return f"编译失败：{first}"

"""opl_probe —— 后端能力探测。

一个职责：把「本机现在有什么」变成可查询的事实，而不是假设。
只做只读探测：不安装任何东西、不修改系统，**也不发起会触发安装的调用**。

三条来自实测的要求：

* **版本探测必须带硬超时。** `~/.elan/settings.toml` 的 `default_toolchain = "stable"`
  使每次 `lean` / `lake` 调用都要联网解析版本。实测在无 `lean-toolchain` 的目录里，
  同一条 `lake --version` 三轮分别耗 5.0/3.0/5.0、12.0/3.0/9.9、7.4/3.8/1.3 秒
  ——跨度 1.3 到 12 秒，哪一次卡住纯看网络；在定点 toolchain 的目录里是 0.02 秒。
  超时只能标为「暂不可用」，**不得**缓存成「不存在」——一次网络抖动不该让某一层
  被永久降级。
* **存在性不等于可用。** `decompress` 是「存在但坏了」：上游 `read_lit` 内有一句
  遗留 `printf`，输出不是合法 LRAT，只查 `command -v` 会把它当可用。
* **除可执行文件外还要探 Python 模块，而且要按解释器分别探。** 实测本机曾出现
  系统 3.14 有 `z3` / `sympy`、另一个 venv（基于 uv 下载的 3.12）有 `cvc5` / `ortools`，
  没有任何一个解释器同时看得见两者。这种分裂会让「缺 cvc5」的降级路径被无谓触发。

== Lean 另有一条规则：未定点就一次都不探 ==

上面第一条（硬超时）是对**其它**工具的规则。Lean 不行——超时只能限制等待，
**限制不了副作用**：在**没有 `lean-toolchain`** 的目录及其祖先里调用 `lean` / `lake`，
elan 会去联网解析 `stable`，本机若没装过它就会**把那个 toolchain 下下来**（几百 MB）。
一条自称只读的诊断命令不该干这个。实测代价也难看：未定点的 cwd 里跑一次
`opl-capabilities`，`probe_lean_project` 等满 30 秒超时、两个通用探针各卡 5 秒，
合计 **40 秒**换回三个 `probe_timeout`、零条有效信息。

所以凡是 Lean 相关探测（`probe_lean_project`，以及 `LAYERS["lean"]` 里的
`lean` / `lake`）在未定点时**一次都不调用** `lake`，只报三样：为什么没探、
怎么修（`advice`）、以及不含子进程的环境事实（elan 装了哪些 toolchain、
默认会解析到哪个）。**定点了就照常探**——那时 `lake --version` 是 0.02 秒的本地调用。

本模块不打印任何东西：探测函数返回结构化结果，`build_snapshot` 额外返回日志行，
由 `bin/opl-capabilities` 负责输出。这样它可 import、可单测、可被类型检查。
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from typing import Any

from opl_common import find_tool, plugin_root, run
# 「向上找 lean-toolchain」是 Lean 的定制规则（找的是哪个文件名、找到了算什么），
# 所以它住在 opl_lean 里。这里借用而不是复制一份——两份实现必然会分叉，
# 而分叉的后果是「opl-capabilities 说有定点、opl-leancheck 说没有」。
from opl_lean import find_toolchain

# 可执行文件层。required 层缺任何一个即视为环境不完整；其余层按「存在即启用」降级。
LAYERS: dict[str, list[tuple[str, str | None]]] = {
    "required":   [("python3", "--version"), ("typst", "--version")],
    "proof":      [("drat-trim", None), ("lrat-check", None)],
    "lean":       [("lean", "--version"), ("lake", "--version")],
    "smt":        [("z3", "--version"), ("minisat", None),
                   ("cryptominisat5", "--version"), ("cadical", "--version"),
                   ("kissat", "--version")],
    "cas":        [("gp", "--version"), ("fplll", "--version")],
    "bench":      [("hyperfine", "--version"), ("perf", "--version"),
                   ("cpupower", "--version"), ("numactl", "--version")],
    "sandbox":    [("bwrap", "--version"), ("docker", "--version"),
                   ("systemd-run", "--version")],
    "literature": [("uv", "--version"), ("git", "--version")],
}

# Python 模块层。库型后端放这里，不放进上面的可执行文件层——`cvc5` 在本机是库而非
# 命令行，若同时出现在可执行文件层会报 not_found，让消费者误判为「不可用」。
PY_LAYERS: dict[str, list[str]] = {
    "py-smt":   ["z3", "cvc5", "pysat"],
    "py-cas":   ["sympy", "flint", "fpylll", "mpmath"],
    "py-stats": ["numpy", "scipy", "pandas", "statsmodels", "lifelines", "optuna"],
}

# 模块名与发行名不一致的少数几个，取版本时用发行名。
DIST_NAMES = {"z3": "z3-solver", "pysat": "python-sat", "flint": "python-flint",
              "sklearn": "scikit-learn"}

# 合法 LRAT 行：`<id> d <ids>* 0` 或 `<id> <lits>* 0 <hints>* 0`
LRAT_LINE = re.compile(r"^\d+ (?:d(?: -?\d+)* 0|(?:-?\d+\s+)*0\s+(?:-?\d+\s+)*0)$")

PY_PROBE = """
import importlib.util as iu, json, sys
try:
    import importlib.metadata as md
except Exception:
    md = None
dists = %(dists)r
mods = %(mods)r
res = {}
for m in mods:
    if iu.find_spec(m) is None:
        res[m] = None
        continue
    v = None
    if md is not None:
        try:
            v = md.version(dists.get(m, m))
        except Exception:
            v = None
    if v is None:
        try:
            v = getattr(__import__(m), "__version__", None)
        except Exception:
            v = None
    res[m] = v or "?"
print("@@OPL@@" + json.dumps({"executable": sys.executable,
                              "version": sys.version.split()[0],
                              "modules": res}))
"""


class ProbeError(Exception):
    """参数错误。调用方翻成 USAGE(2)。"""


def fixtures_dir() -> str:
    return os.path.join(plugin_root(), "tests", "fixtures")


# ------------------------------------------------------------------ 可执行文件


def probe_executable(name: str, varg: str | None, timeout: float, *,
                     cwd: str | None = None,
                     skip_version: str | None = None) -> dict[str, Any]:
    """先试 `--version`，失败则试无参调用并取首行。一律带超时。

    `skip_version` 给出理由时**不启进程**：只报「在不在 PATH 上」这个文件系统事实。
    Lean 的两个可执行文件在没有定点项目时走这条路（见模块 docstring）——那时调用
    `lake --version` 会让 elan 联网解析并可能安装 `stable`，硬超时挡不住那件事。

    `cwd` 是子进程的工作目录。对 Lean 而言**它是必需能力而非便利**：只有落在一个
    定点了 `lean-toolchain` 的目录里，`lake --version` 才是 0.02 秒的本地调用。
    其它工具不需要它，留 None 即继承调用方的 cwd（与既有行为一致）。
    """
    path = find_tool(name)
    if path is None:
        return {"available": False, "error": "not_found"}
    if skip_version:
        return {"available": True, "path": path, "version": "",
                "probe_skipped": "unpinned", "note": skip_version}
    for argv in ([[varg]] if varg else []) + [[]]:
        t0 = time.monotonic()
        rc, out, err = run([path, *argv], timeout=timeout, cwd=cwd)
        if rc is None:
            return {"available": False, "path": path, "error": "probe_timeout",
                    "probe_ms": int((time.monotonic() - t0) * 1000),
                    "detail": "超时不等于不可用：elan 的 default_toolchain = stable "
                              "会让每次调用联网解析版本，定点 toolchain 后约 0.02 秒"}
        text = (out or err).decode("utf-8", "replace").strip()
        if text:
            return {"available": True, "path": path,
                    "version": text.splitlines()[0].strip()[:120],
                    "probe_ms": int((time.monotonic() - t0) * 1000)}
    return {"available": True, "path": path, "version": "", "note": "no_version_output"}


def probe_decompress(timeout: float = 10.0) -> dict[str, Any]:
    """功能探测：`decompress` 能否产出合法 LRAT。仅存在性检查不够。"""
    exe = find_tool("decompress")
    if exe is None:
        return {"available": False, "error": "not_found"}
    clrat = os.path.join(fixtures_dir(), "tiny.clrat")
    if not os.path.isfile(clrat):
        return {"available": True, "path": exe, "functional": "untested",
                "error": "fixture_missing"}
    rc, out, _ = run([exe, "-m", clrat], timeout=timeout)
    if rc is None:
        return {"available": True, "path": exe, "error": "probe_timeout"}
    lines = [ln for ln in out.decode("utf-8", "replace").splitlines() if ln.strip()]
    bad = [ln for ln in lines if not LRAT_LINE.match(ln.strip())]
    if bad:
        return {"available": False, "path": exe, "error": "output_malformed",
                "functional": "broken",
                "detail": (f"{len(bad)}/{len(lines)} 行不是合法 LRAT；"
                           f"首个：{bad[0][:60]!r}。已知上游 bug：decompress.c 的 "
                           f"read_lit 内有一句遗留 printf，把原始字节混入 stdout")}
    return {"available": True, "path": exe, "functional": "ok", "lines": len(lines)}


# ------------------------------------------------------------------ Lean 项目

# 「为什么未定点就不探」的那段理由，两个调用点共用一份，免得说法分叉。
UNPINNED_ADVICE = (
    "在这个项目（或它的任一祖先目录）里放一个 lean-toolchain，"
    "或把 OPL_LEAN_PROJECT 指向一个已定点的项目。未定点时不探测：elan 的 "
    "default_toolchain 会让每次 lean/lake 调用联网解析（实测 1.3–12 秒且随机，"
    "本机 30 秒超时都拿不到版本），本机没装过时还会把那个 toolchain 下下来。"
)


def lean_pin(root: str) -> tuple[bool, str, str | None]:
    """`root` 及其祖先里有没有 `lean-toolchain`。纯文件系统，不启进程。

    返回 (是否定点, toolchain 内容, 提供它的目录)。「祖先里也算」不是宽松，而是
    跟事实对齐：elan 自己往上找，`opl_lean.resolve_project()` 也是这么找的。
    """
    found = find_toolchain(root)
    if found is None:
        return False, "", None
    where, content = found
    return bool(content), content, where


def lean_context() -> dict[str, Any]:
    """Lean 探测的上下文：有效的项目目录 + 是否定点。纯文件系统，不启进程。

    有效项目取 `OPL_LEAN_PROJECT`，否则 `<plugin>/lean`——与
    `opl_lean.resolve_project()` 同一套规则。两条命令对「哪个项目」必须给同一个
    答案，否则会出现「capabilities 说有定点、leancheck 说没有」。
    """
    proj = os.environ.get("OPL_LEAN_PROJECT") or os.path.join(plugin_root(), "lean")
    exists = os.path.isdir(proj)
    pinned, toolchain, pinned_by = lean_pin(proj) if exists else (False, "", None)
    return {"project": proj, "exists": exists, "pinned": pinned,
            "toolchain": toolchain, "pinned_by": pinned_by}


def lean_probe_cwd(ctx: dict[str, Any]) -> str | None:
    """在哪个目录里探 `lean`/`lake` 才安全。

    定点了就返回**装着 lean-toolchain 的那个目录**（`pinned_by`）——elan 在那里
    不用联网，`lake --version` 是 0.02 秒的本地调用。没定点返回 None，调用方据此
    走「不探只报存在性」那条路。

    为什么不直接用项目目录：`lean-toolchain` 可能在上层（monorepo 常见），
    落到 `pinned_by` 是最紧的保证。
    """
    if not ctx.get("pinned"):
        return None
    return ctx.get("pinned_by") or ctx.get("project")


def elan_env() -> dict[str, Any]:
    """不含子进程的 elan 环境事实。全部只读，用来回答「那我该定点到哪个版本」。"""
    home = os.environ.get("ELAN_HOME") or os.path.join(os.path.expanduser("~"), ".elan")
    facts: dict[str, Any] = {"elan_home": home, "exists": os.path.isdir(home)}
    settings = os.path.join(home, "settings.toml")
    if os.path.isfile(settings):
        try:
            text = open(settings, encoding="utf-8").read()
            m = re.search(r'^\s*default_toolchain\s*=\s*"([^"]*)"', text, re.M)
            facts["default_toolchain"] = m.group(1) if m else None
        except OSError as exc:
            facts["default_toolchain"] = None
            facts["settings_error"] = str(exc)
    tc_dir = os.path.join(home, "toolchains")
    if os.path.isdir(tc_dir):
        try:
            facts["installed_toolchains"] = sorted(os.listdir(tc_dir))
        except OSError:
            pass
    facts["lean_on_path"] = find_tool("lean")
    facts["lake_on_path"] = find_tool("lake")
    return facts


def probe_lean_project(timeout: float = 30.0) -> dict[str, Any]:
    """探测 Lean 项目上下文。

    未定点时**一次都不调用 lake**（原因见模块 docstring）——那时只报三样：为什么
    没探、怎么修、以及不含子进程的环境事实。定点了才真的去问版本，那时是 0.02 秒
    的本地调用。

    为什么不能只探 `lean --version`：见模块 docstring。探测必须在一个*定点*的目录里
    做，并把「是否定点」本身当成事实报出来——`pinned_fast` 就是用来在它退化回联网时
    报警的。
    """
    proj = lean_context()["project"]
    info: dict[str, Any] = {
        "project": proj,
        "resolved": os.path.realpath(proj) if os.path.exists(proj) else None,
    }
    if not os.path.isdir(proj):
        return info | {"available": False, "error": "no_project",
                       "advice": "设 OPL_LEAN_PROJECT，或把 Lean 项目链到 <plugin>/lean",
                       "env": elan_env()}

    ctx = lean_context()
    pinned = bool(ctx["pinned"])
    info["pinned"] = pinned
    if ctx["toolchain"]:
        info["toolchain"] = ctx["toolchain"]
    if ctx["pinned_by"]:
        info["pinned_by"] = ctx["pinned_by"]
    # Mathlib 是否已构建是纯文件系统事实，与「探不探 lake」无关，所以两条分支都给。
    # 用代表性产物判断，避免遍历 8000+ 个 .olean。
    mldir = os.path.join(proj, ".lake", "packages", "mathlib")
    if os.path.isdir(mldir):
        marker = os.path.join(mldir, ".lake", "build", "lib", "lean", "Mathlib.olean")
        info["mathlib"] = {"present": True, "built": os.path.isfile(marker),
                           "marker": marker if os.path.isfile(marker) else None}
    else:
        info["mathlib"] = {"present": False}

    if not pinned:
        # 「没问出来」不是「不可用」：`available` 用 None 而不是 False。这与退出码
        # 那套是同一条纪律——「无法判定」不能报成「后端缺失」。
        return info | {"available": None, "probe_skipped": "unpinned",
                       "advice": UNPINNED_ADVICE, "env": elan_env()}

    lake = find_tool("lake")
    if lake is None:
        return info | {"available": False, "error": "lake_not_found", "env": elan_env()}
    t0 = time.monotonic()
    # cwd 必须是装着 lean-toolchain 的那个目录，否则 elan 又去联网解析 stable。
    # 这一步只在*定点*之后才可能走到——未定点的那条路在上面已经返回了。
    rc, out, err = run([lake, "--version"], timeout=timeout,
                       cwd=lean_probe_cwd(ctx) or proj)
    ms = int((time.monotonic() - t0) * 1000)
    text = (out or err).decode("utf-8", "replace").strip().splitlines()
    info["lake"] = {"exit": rc, "probe_ms": ms,
                    "version": text[0][:120] if text else "",
                    "error": "probe_timeout" if rc is None else None}
    info["available"] = rc == 0
    # 定点之后 lake 本身应当在毫秒级；超过 1 秒说明仍在联网。
    # 这条报警只在「看起来定点、实际仍在联网」时才有意义（比如项目里那个
    # lean-toolchain 被删了），未定点的情形不靠它——那时 pinned=false 已经是结论。
    info["pinned_fast"] = ms < 1000
    return info


# ------------------------------------------------------------------ 解释器


def default_interpreters() -> list[str]:
    """默认探测哪几个解释器：显式路径、插件 venv、系统 python3。

    去重键取（所在 bin 目录，解释器）而非解释器的 realpath。原因：venv 的
    `bin/python` 通常是指向同一个基础解释器的符号链接，只按 realpath 去重会把
    venv 与系统 python 合并成一条——而它们的 site-packages 并不相同，
    恰恰是分裂最需要被看见的地方。
    """
    cands: list[str] = []
    if os.environ.get("OPL_PYTHON"):
        cands.append(os.environ["OPL_PYTHON"])
    v = os.path.expanduser("~/.local/share/open-problem-lab/venv/bin/python")
    if os.path.isfile(v):
        cands.append(v)
    sys_py = find_tool("python3")
    if sys_py:
        cands.append(sys_py)
    cands.append(sys.executable)
    seen: set[tuple[str, str]] = set()
    out: list[str] = []
    for p in cands:
        try:
            key = (os.path.realpath(os.path.dirname(p)), os.path.realpath(p))
        except OSError:
            continue
        if key not in seen and os.path.isfile(p):
            seen.add(key)
            out.append(p)
    return out


def probe_python(interp: str, timeout: float) -> dict[str, Any]:
    """在指定解释器里探测 Python 模块。"""
    mods = sorted({m for ms in PY_LAYERS.values() for m in ms})
    code = PY_PROBE % {"dists": DIST_NAMES, "mods": mods}
    t0 = time.monotonic()
    rc, out, err = run([interp, "-c", code], timeout=timeout)
    ms = int((time.monotonic() - t0) * 1000)
    if rc is None:
        return {"interpreter": interp, "error": "probe_timeout", "probe_ms": ms}
    for line in (out or b"").decode("utf-8", "replace").splitlines():
        if line.startswith("@@OPL@@"):
            data: dict[str, Any] = json.loads(line[len("@@OPL@@"):])
            data["path"] = interp
            data["probe_ms"] = ms
            return data
    detail = (err or b"").decode("utf-8", "replace").strip()[:200]
    return {"interpreter": interp, "error": detail or "no_output", "probe_ms": ms}


# ------------------------------------------------------------------ 快照


def build_snapshot(*, layers: list[str] | None = None,
                   pythons: list[str] | None = None,
                   timeout: float = 5.0, python_timeout: float = 30.0,
                   do_python: bool = True,
                   ) -> tuple[dict[str, Any], list[str]]:
    """探测并组装能力快照。返回 (快照, 日志行) —— 日志交由调用方输出。"""
    wanted = layers or list(LAYERS)
    unknown = [l for l in wanted if l not in LAYERS]
    if unknown:
        raise ProbeError(f"未知层：{', '.join(unknown)}；可用层：{', '.join(LAYERS)}")

    log: list[str] = []
    t0 = time.monotonic()
    tools: dict[str, dict[str, Any]] = {}
    # Lean 的两个可执行文件要特殊对待：有定点项目就**在那个目录里**探（0.02 秒的本地
    # 调用，且答案正确），没有就一次都不探，只报存在性 + 推荐。判据不是「调用方当前
    # 在哪个目录」而是「有没有可用定点项目」——在仓库根跑 opl-capabilities 时 cwd 祖先
    # 没有 lean-toolchain，但 plugin/lean 里有一个，那时照样应该探，否则能力快照
    # 会在最常用的场景下丢失版本信息。
    lean_ctx = lean_context()
    lean_cwd = lean_probe_cwd(lean_ctx)
    for layer in wanted:
        for name, varg in LAYERS[layer]:
            if name in tools:
                continue
            is_lean_bin = layer == "lean" and name in ("lean", "lake")
            info = probe_executable(
                name, varg, timeout,
                cwd=lean_cwd if is_lean_bin else None,
                skip_version=(UNPINNED_ADVICE if is_lean_bin and lean_cwd is None
                              else None))
            info["layer"] = layer
            tools[name] = info
            if info.get("probe_skipped"):
                state = "presence-only"
            else:
                state = "ok" if info["available"] else info.get("error", "missing")
            log.append(f"{name:<16} {layer:<10} {state}"
                       + (f"  {info.get('version', '')[:48]}" if info.get("version") else ""))

    if "proof" in wanted:
        info = probe_decompress()
        info["layer"] = "proof"
        tools["decompress"] = info
        log.append(f"{'decompress':<16} {'proof':<10} "
                   f"{info.get('functional', info.get('error'))}")

    # Lean 层的可用性由*项目上下文*决定，而不是由任意 cwd 下的 `lean --version`
    # 决定：只有定点了 toolchain 的目录里才不会联网。
    lean_project = probe_lean_project(python_timeout)
    if "lean" in wanted:
        if lean_project.get("probe_skipped"):
            # 没探不是没装。把「为什么没探」和「怎么修」直接打在日志里，
            # 免得读者把这一行误读成 lean 不可用。
            log.append(f"{'lean-project':<16} {'lean':<10} unpinned（未探测）")
            log.append(f"{'':<16} {'':<10} → {lean_project.get('advice')}")
        elif lean_project.get("available"):
            ms = (lean_project.get("lake") or {}).get("probe_ms")
            log.append(f"{'lean-project':<16} {'lean':<10} ok  "
                       f"{lean_project.get('toolchain', '?')}  lake {ms}ms"
                       f"{'' if lean_project.get('pinned_fast') else '  ← 偏慢，疑似仍在联网'}")
        else:
            log.append(f"{'lean-project':<16} {'lean':<10} {lean_project.get('error')}")
        ml = lean_project.get("mathlib") or {}
        log.append(f"{'mathlib':<16} {'lean':<10} "
                   f"{'built' if ml.get('built') else ('present_unbuilt' if ml.get('present') else 'absent')}")

    interpreters: dict[str, dict[str, Any]] = {}
    py_layers: dict[str, dict[str, Any]] = {}
    if do_python:
        for interp in (pythons or default_interpreters()):
            info = probe_python(interp, python_timeout)
            interpreters[interp] = info
            if "modules" in info:
                seen = sum(1 for v in info["modules"].values() if v)
                log.append(f"{info.get('version', '?'):<16} py         {interp}  看得见 "
                           f"{seen}/{len(info['modules'])} 个模块")
            else:
                log.append(f"{'?':<16} py         {interp}  {info.get('error')}")
        # 每个 Python 层：有没有任何一个解释器同时看得见该层全部模块
        for layer, mods in PY_LAYERS.items():
            ok_interps = [p for p, i in interpreters.items()
                          if "modules" in i and all(i["modules"].get(m) for m in mods)]
            missing_by = {p: [m for m in mods if not i.get("modules", {}).get(m)]
                          for p, i in interpreters.items() if "modules" in i}
            py_layers[layer] = {
                "modules": mods,
                "satisfied_by": ok_interps,
                "split_brain": not ok_interps,
                "missing_by_interpreter": {p: m for p, m in missing_by.items() if m},
            }

    required_missing = [n for n, i in tools.items()
                        if i["layer"] == "required" and not i.get("available")]
    broken = [n for n, i in tools.items() if i.get("functional") == "broken"]
    split = [l for l, v in py_layers.items() if v["split_brain"]]

    snapshot = {
        "schema": "opl.capabilities/2",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": {"nproc": os.cpu_count()},
        "probe_ms": int((time.monotonic() - t0) * 1000),
        "tools": tools,
        "lean_project": lean_project,
        "interpreters": interpreters,
        "py_layers": py_layers,
        "required_missing": required_missing,
        "broken": broken,
        "split_brain": split,
        "layers": {l: [n for n, i in tools.items() if i["layer"] == l] for l in wanted},
    }
    return snapshot, log

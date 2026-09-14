"""opl_probe —— 后端能力探测。

一个职责：把「本机现在有什么」变成可查询的事实，而不是假设。
只做只读探测，不安装任何东西、不修改系统。

三条来自实测的要求：

* **版本探测必须带硬超时。** `~/.elan/settings.toml` 的 `default_toolchain = "stable"`
  使每次 `lean` / `lake` 调用都要联网解析版本。实测在无 `lean-toolchain` 的目录里，
  同一命令两轮分别是 5.0 / 3.0 / 5.0 秒与 12.0 / 3.0 / 9.9 秒（后者有一次撞上 12 秒
  上限），在定点 toolchain 的目录里是 0.02 秒。
  超时只能标为「暂不可用」，**不得**缓存成「不存在」——一次网络抖动不该让某一层
  被永久降级。
* **存在性不等于可用。** `decompress` 是「存在但坏了」：上游 `read_lit` 内有一句
  遗留 `printf`，输出不是合法 LRAT，只查 `command -v` 会把它当可用。
* **除可执行文件外还要探 Python 模块，而且要按解释器分别探。** 实测本机曾出现
  系统 3.14 有 `z3` / `sympy`、另一个 venv（基于 uv 下载的 3.12）有 `cvc5` / `ortools`，
  没有任何一个解释器同时看得见两者。这种分裂会让「缺 cvc5」的降级路径被无谓触发。

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


def probe_executable(name: str, varg: str | None, timeout: float) -> dict[str, Any]:
    """先试 `--version`，失败则试无参调用并取首行。一律带超时。"""
    path = find_tool(name)
    if path is None:
        return {"available": False, "error": "not_found"}
    for argv in ([[varg]] if varg else []) + [[]]:
        t0 = time.monotonic()
        rc, out, err = run([path, *argv], timeout=timeout)
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


def probe_lean_project(timeout: float = 30.0) -> dict[str, Any]:
    """探测 Lean 项目上下文。

    为什么不能只探 `lean --version`：见模块 docstring。探测必须在一个*定点*的目录里
    做，并把「是否定点」本身当成事实报出来——`pinned_fast` 就是用来在它退化回联网时
    报警的。
    """
    proj = os.environ.get("OPL_LEAN_PROJECT") or os.path.join(plugin_root(), "lean")
    info: dict[str, Any] = {
        "project": proj,
        "resolved": os.path.realpath(proj) if os.path.exists(proj) else None,
    }
    if not os.path.isdir(proj):
        return info | {"available": False, "error": "no_project",
                       "hint": "设 OPL_LEAN_PROJECT，或把 Lean 项目链到 <plugin>/lean"}

    tc = os.path.join(proj, "lean-toolchain")
    if os.path.isfile(tc):
        try:
            info["toolchain"] = open(tc, encoding="utf-8").read().strip()
        except OSError as exc:
            info["toolchain"] = None
            info["toolchain_error"] = str(exc)
        info["pinned"] = bool(info.get("toolchain"))
    else:
        info["pinned"] = False
        info["note"] = ("无 lean-toolchain：elan 每次调用都要联网解析 stable，"
                        "实测每次数秒且随机（最坏一次 12 秒），定点后 0.02 秒")

    lake = find_tool("lake")
    if lake is None:
        return info | {"available": False, "error": "lake_not_found"}
    t0 = time.monotonic()
    # cwd 必须是项目目录本身，否则 elan 又去联网解析 stable。
    rc, out, err = run([lake, "--version"], timeout=timeout, cwd=proj)
    ms = int((time.monotonic() - t0) * 1000)
    text = (out or err).decode("utf-8", "replace").strip().splitlines()
    info["lake"] = {"exit": rc, "probe_ms": ms,
                    "version": text[0][:120] if text else "",
                    "error": "probe_timeout" if rc is None else None}
    info["available"] = rc == 0
    # 定点之后 lake 本身应当在毫秒级；超过 1 秒说明仍在联网。
    info["pinned_fast"] = ms < 1000

    ml = os.path.join(proj, ".lake", "packages", "mathlib")
    if os.path.isdir(ml):
        # 用代表性产物判断，避免遍历 8000+ 个 .olean。
        marker = os.path.join(ml, ".lake", "build", "lib", "lean", "Mathlib.olean")
        info["mathlib"] = {"present": True, "built": os.path.isfile(marker),
                           "marker": marker if os.path.isfile(marker) else None}
    else:
        info["mathlib"] = {"present": False}
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
    for layer in wanted:
        for name, varg in LAYERS[layer]:
            if name in tools:
                continue
            info = probe_executable(name, varg, timeout)
            info["layer"] = layer
            tools[name] = info
            state = "ok" if info["available"] else info.get("error", "missing")
            log.append(f"{name:<16} {layer:<10} {state}"
                       + (f"  {info.get('version', '')[:48]}" if info.get("available") else ""))

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
        if lean_project.get("available"):
            ms = (lean_project.get("lake") or {}).get("probe_ms")
            log.append(f"{'lean-project':<16} {'lean':<10} ok  "
                       f"{lean_project.get('toolchain', '?')}  lake {ms}ms"
                       f"{'' if lean_project.get('pinned_fast') else '  ← 偏慢，疑似仍在联网'}")
            ml = lean_project.get("mathlib") or {}
            log.append(f"{'mathlib':<16} {'lean':<10} "
                       f"{'built' if ml.get('built') else ('present_unbuilt' if ml.get('present') else 'absent')}")
        else:
            log.append(f"{'lean-project':<16} {'lean':<10} {lean_project.get('error')}")

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

"""open-problem-lab 的共享契约。

所有 opl-* 可执行文件共用同一套接口约定，这是整个工具链能像管道一样组合的前提：

退出码 —— 判决走退出码，不走人读的文本：
    0  PASS     断言成立，且已被独立复核
    1  REJECT   断言被推翻（找到见证 / 证书无效）
    2  USAGE    参数或输入错误
    3  UNKNOWN  后端给出 unknown（必须附原因）
    4  MISSING  所需后端不存在（能力探测失败）
    5  EMPTY    正常运行，但没有任何结果（0 候选 / 0 次执行）

流 —— stdout 是机器接口，stderr 是人读诊断：
    stdout 只允许出现机器可解析的内容：一行 `s <判决>`，或一个 JSON 对象。
    stderr 承载注释、进度、被包装工具的输出。--verbose 只影响 stderr。
这样 `a | b` 的管道里永远不会混进诊断噪声，且 `unknown` 与 `unsat` 在数值上就无法混淆。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from typing import Never, Sequence

PASS, REJECT, USAGE, UNKNOWN, MISSING, EMPTY = 0, 1, 2, 3, 4, 5

VERDICT_NAME = {
    PASS: "PASS",
    REJECT: "REJECT",
    USAGE: "USAGE",
    UNKNOWN: "UNKNOWN",
    MISSING: "MISSING",
    EMPTY: "EMPTY",
}


def c(msg: str = "") -> None:
    """诊断行，一律写 stderr。"""
    print(f"c {msg}" if msg else "c", file=sys.stderr)


def s(verdict: str, reason: str | None = None) -> None:
    """判决行，一律写 stdout，且只有它写 stdout。"""
    print(f"s {verdict}" if reason is None else f"s {verdict} {reason}")


def die(code: int, msg: str, **extra) -> Never:
    """以指定退出码结束。extra 以 JSON 写到 stdout，便于管道下游消费失败原因。"""
    if msg:
        c(msg)
    if extra:
        json.dump({"exit": code, "verdict": VERDICT_NAME.get(code, "?"), **extra},
                  sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    sys.exit(code)


def out_json(obj, path: str | None = None) -> None:
    text = json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True)
    if path:
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        c(f"wrote {path}")
    else:
        print(text)


def bin_dirs() -> list[str]:
    """按优先级返回可执行文件搜索目录。

    OPL_BINDIR 显式覆盖 > 插件自身的 bin/ > PATH。
    插件根由 KIMI_PLUGIN_ROOT 注入（调研确认这是平台唯一注入的路径变量）。
    """
    root = os.environ.get("KIMI_PLUGIN_ROOT") or plugin_root()
    dirs = []
    if os.environ.get("OPL_BINDIR"):
        dirs.append(os.environ["OPL_BINDIR"])
    dirs.append(os.path.join(root, "bin"))
    dirs.append(os.path.join(root, "bin", "third-party"))
    return dirs


def plugin_root() -> str:
    """插件根目录，由本文件位置反推（`lib/` 的上一级）。"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_tool(name: str) -> str | None:
    for d in bin_dirs():
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return shutil.which(name)


def probe_version(tool: str, args=("--version",), timeout: float = 5.0) -> dict:
    """探测工具并取其版本。

    超时是硬要求：本机 elan 的 default_toolchain = "stable" 使每次调用都要联网
    解析版本；无 lean-toolchain 的目录里实测 5.0 / 3.0 / 5.0 秒。这里把超时当作
    「暂不可用」处理并记录 probe_timeout——注意不要把它缓存成「不存在」，
    一次网络抖动不该让某一层被永久降级。
    """
    path = find_tool(tool)
    if path is None:
        return {"available": False, "error": "not_found"}
    t0 = time.monotonic()
    try:
        p = subprocess.run([path, *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"available": False, "path": path, "error": "probe_timeout",
                "probe_ms": int((time.monotonic() - t0) * 1000)}
    except OSError as exc:
        return {"available": False, "path": path, "error": f"oserror: {exc}"}
    first = (p.stdout or p.stderr or "").strip().splitlines()
    return {
        "available": True,
        "path": path,
        "version": first[0].strip() if first else "",
        "probe_ms": int((time.monotonic() - t0) * 1000),
    }


def run(cmd: list[str], timeout: float | None = None, stdin: bytes | None = None,
        cwd: str | None = None) -> tuple[int | None, bytes, bytes]:
    """执行子进程，返回 (returncode, stdout, stderr)。超时返回 rc=None。

    `cwd` 是必需能力而非便利：Lean 必须在定点了 `lean-toolchain` 的目录里执行，
    否则 elan 每次调用都要联网解析 `stable`（实测 5.0 / 3.0 / 5.0 秒，
    定点后 0.021 秒）。
    """
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, input=stdin,
                           cwd=cwd)
    except subprocess.TimeoutExpired:
        return None, b"", b""
    return p.returncode, p.stdout, p.stderr


# --------------------------------------------------------- 解释器解析（重执行）


class MissingBackend(Exception):
    """所需后端（Python 模块）不存在。调用方应翻成退出码 4。"""


def interpreter_candidates() -> list[str]:
    """可能带着求解器的解释器，按优先级排列。"""
    cands: list[str] = []
    if os.environ.get("OPL_PYTHON"):
        cands.append(os.environ["OPL_PYTHON"])
    for base in (b for b in (os.environ.get("OPL_VENV"),
                             "~/.local/share/open-problem-lab/venv") if b):
        cands.append(os.path.join(os.path.expanduser(base), "bin", "python"))
    sys_py = find_tool("python3")
    if sys_py:
        cands.append(sys_py)
    return cands


def _can_import(python: str, module: str, timeout: float = 15.0) -> bool:
    code = ("import importlib.util, sys; "
            f"sys.exit(0 if importlib.util.find_spec({module!r}) else 1)")
    rc, _, _ = run([python, "-c", code], timeout=timeout)
    return rc == 0


def ensure_modules(modules: Sequence[str]) -> None:
    """确保当前解释器能 import 这些模块，否则换解释器重跑本程序。

    为什么需要：命令按 Unix 约定是 `#!/usr/bin/env python3` 的可执行文件，而
    求解器（pysat / ortools / cvc5）装在项目 venv 里——实测系统 python3 看不到
    它们。把 shebang 写死成 venv 绝对路径能跑，但换机器就废、进压缩包更不行。
    所以这里在运行时解析：这正是 `opl-capabilities` 报出的 `split_brain`
    在命令侧的具体处置。

    正常路径直接返回；需要换解释器时 `os.execv` 不返回。找不到候选就抛
    `MissingBackend`，由调用方翻成退出码 4——绝不回退到估算。
    """
    import importlib.util

    missing = [m for m in modules if importlib.util.find_spec(m) is None]
    if not missing:
        return

    # 还原被调用的脚本路径。sys.argv[0] 可能只是裸命令名（走 PATH 调用时），
    # 那时 abspath 会按 cwd 解析成错的东西。
    argv0 = sys.argv[0]
    script = (os.path.abspath(argv0) if os.sep in argv0
              else (shutil.which(argv0) or argv0))

    # 防重入：候选之间可能互为同一环境的不同路径，没有这道标记会 exec 成死循环。
    # 另外*不要*用 realpath 判断「是不是当前解释器」——venv 的 bin/python 通常是
    # 指向同一个基础解释器的符号链接，realpath 相同但 site-packages 完全不同，
    # 按 realpath 跳过会把唯一可用的候选（venv）当成「自己」丢掉。
    env = dict(os.environ)
    tried = [p for p in env.get("OPL_REEXEC", "").split(os.pathsep) if p]

    for cand in interpreter_candidates():
        if not os.path.isfile(cand) or cand == sys.executable or cand in tried:
            continue
        if all(_can_import(cand, m) for m in missing):
            env["OPL_REEXEC"] = os.pathsep.join([*tried, cand])
            os.execve(cand, [cand, script, *sys.argv[1:]], env)

    raise MissingBackend(
        f"当前解释器缺 {'、'.join(missing)}，且找不到能提供它们的解释器"
        f"（试过 {len(interpreter_candidates())} 个候选："
        f"{'、'.join(interpreter_candidates())}）。"
        f"运行 opl-capabilities 看 split_brain——不要回退到估算。")

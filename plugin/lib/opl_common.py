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


def die(code: int, msg: str, **extra) -> "NoReturn":  # noqa: F821
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
    dirs = []
    if os.environ.get("OPL_BINDIR"):
        dirs.append(os.environ["OPL_BINDIR"])
    if os.environ.get("KIMI_PLUGIN_ROOT"):
        dirs.append(os.path.join(os.environ["KIMI_PLUGIN_ROOT"], "bin"))
    dirs.append(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin"))
    return dirs


def find_tool(name: str) -> str | None:
    for d in bin_dirs():
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return shutil.which(name)


def probe_version(tool: str, args=("--version",), timeout: float = 5.0) -> dict:
    """探测工具并取其版本。

    超时是硬要求：本机 elan 的 stable 指向未安装版本，裸 `lean --version` 会触发
    联网下载工具链并挂住。这里把超时当作「不可用」处理，并记录 probe_timeout。
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


def run(cmd: list[str], timeout: float | None = None, stdin: bytes | None = None):
    """执行子进程，返回 (returncode, stdout, stderr)。超时返回 rc=None。"""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, input=stdin)
    except subprocess.TimeoutExpired:
        return None, b"", b""
    return p.returncode, p.stdout, p.stderr

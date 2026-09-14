"""opl_certcheck —— 调度独立校验器复核证书。

一个职责：把「求解器说 UNSAT」变成「第三方可以在不信任求解器的前提下复核」。
本模块自己不判断数学，只调度校验器并把结果翻译成结构化结论。

**最不能犯的错，是把「我读不懂这份证书」报成「这份证书是错的」**——那是伪证。
所以每条路径都必须自己回答「证书被完整读入了吗」：

    drat 路径   校验器自报 `read N bytes from proof file`，与证书实际字节数比对。
    lrat 路径   校验器自报 `Last line checked = N`；N=0 说明一行证明都没读进去。
    clrat 路径  上游 decompress 在 read_lit 里有一句遗留 printf，会把原始字节混入
                stdout，输出不是合法 LRAT。解压后先验语法，不合法即判解压器有问题。

对应的结构设计：`CheckResult` 把「没拿到判决」（`failure`）与「判决是 NOT
VERIFIED」（`verdict`）分成两个字段。这样调用方在类型层面就无法把二者混为一谈——
比在注释里叮嘱可靠。

各校验器的判决信道并不统一，全是实测出来的，改动前务必先读对应分支的注释：

    drat-trim   退出码说话
    cake_lpr    *退出码恒为 0*，只有 stdout/stderr 文本
    carcara     退出码不区分 valid 与 holey
"""

from __future__ import annotations

import bz2
import hashlib
import os
import re
import tempfile
import time
from dataclasses import dataclass, field
from typing import Any

from opl_common import find_tool, run

# 校验器的判决行：drat-trim 写 `s X`，lrat-check 写 `c X`。
VERDICT_RE = re.compile(r"^(?:[cs] )?(VERIFIED|NOT VERIFIED)\s*$", re.M)
READ_BYTES_RE = re.compile(r"read (\d+) bytes from proof file")
LAST_LINE_RE = re.compile(r"Last line checked = (\d+)")
# 合法 LRAT 行：`<id> d <ids>* 0` 或 `<id> <lits>* 0 <hints>* 0`
LRAT_LINE = re.compile(r"^\d+ (?:d(?: -?\d+)* 0|(?:-?\d+\s+)*0\s+(?:-?\d+\s+)*0)$")

FAIL_FORMATS = ["auto", "drat", "lrat", "clrat", "lpr", "alethe"]


class CertError(Exception):
    """参数或输入错误。调用方翻成 USAGE(2)。"""


@dataclass
class CheckResult:
    backend: str = ""
    log: str = ""
    verdict: str | None = None       # VERIFIED / NOT VERIFIED / None（没拿到判决）
    parsed_ok: bool | None = None    # 证书是否被*完整*读入
    extra: dict[str, Any] = field(default_factory=dict)
    # `failure` 非空表示没拿到判决。它与 `verdict="NOT VERIFIED"` 是两件事。
    failure: str | None = None
    failure_reason: str = ""
    missing: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    duration_ms: int = 0
    fmt: str = ""
    fmt_why: str = ""


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def normalise(text: str) -> str:
    r"""把行尾统一成 `\n`。

    drat-trim 用 `\r` 覆盖进度行，于是原始字节里出现「行首 `\r`」。锚定到 `^` 的
    判决行正则会因此失配——注意用文本模式读文件**测不出**这个问题，因为 Python 的
    通用换行会替你翻译 `\r`，而 `bytes.decode()` 不会。
    """
    return text.replace("\r\n", "\n").replace("\r", "\n")


def run_checker(exe: str, argv: list[str], timeout: float) -> tuple[int | None, str, int]:
    """执行校验器，返回 (退出码, 合并输出, 毫秒)。退出码 None 表示超时。"""
    t0 = time.monotonic()
    rc, out, err = run([exe, *argv], timeout=timeout)
    merged = normalise((out or b"").decode("utf-8", "replace"))
    etext = normalise((err or b"").decode("utf-8", "replace"))
    if etext.strip():
        merged += "\n" + etext
    return rc, merged.strip(), int((time.monotonic() - t0) * 1000)


def load_cert(path: str, workdir: str) -> tuple[str, str | None]:
    """按需解压 .bz2。返回 (可读路径, 说明)。"""
    with open(path, "rb") as fh:
        if fh.read(3) != b"BZh":
            return path, None
    dst = os.path.join(workdir, "cert.unpacked")
    with bz2.open(path, "rb") as src, open(dst, "wb") as out:
        while chunk := src.read(1 << 20):
            out.write(chunk)
    return dst, f"解压 {path} -> {dst}"


def sniff(path: str) -> tuple[str, str]:
    """返回 (格式, 依据)。"""
    with open(path, "rb") as fh:
        head = fh.read(1 << 16)
    if not head:
        return "unknown", "空文件"
    if any(b > 126 or b < 9 for b in head[:4096]):
        return "drat", "前 4 KiB 含非可打印字节（二进制证明）"
    try:
        text = head.decode("utf-8")
    except UnicodeDecodeError:
        return "drat", "非 UTF-8（二进制证明）"
    data = [ln.strip() for ln in text.splitlines()
            if ln.strip() and not ln.lstrip().startswith(("c", "p"))]
    if not data:
        return "unknown", "无可判读的证明行"
    # LRAT 的添加行有两个 0（文字终结符 + 提示终结符），DRAT 只有一个。
    # 不能只看第一行：LRAT 常见的首行是 `<id> d 0`，会被误判成 DRAT。
    for ln in data:
        if LRAT_LINE.match(ln):
            return "lrat", f"存在符合 LRAT 语法的行（如 {ln[:44]!r}）"
    return "drat", f"无 LRAT 语法行（首行 {data[0][:44]!r}）"


def malformed_lrat(text: str) -> list[str]:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return [ln for ln in lines if not LRAT_LINE.match(ln)]


def last_line_checked(log: str) -> int | None:
    m = LAST_LINE_RE.search(log)
    return int(m.group(1)) if m else None


def checker_messages(log: str, max_lines: int = 20, max_chars: int = 2000) -> list[str] | None:
    """摘录检查器的诊断行，供证据记录留证。

    只取 `c ` / `s ` 开头的行——那是 SAT 竞赛系的约定，drat-trim、lrat-check、
    cake_lpr 都遵守。截断到固定行数与字符数，避免把整份日志塞进记录。
    拒绝情形尤其需要它：「哪一行、什么原因」是事后审计唯一能回答
    「为什么这份证书不算」的东西，而各检查器的措辞并不统一。
    """
    picked: list[str] = []
    total = 0
    for line in log.splitlines():
        line = line.strip()
        if not (line.startswith("c ") or line.startswith("s ")):
            continue
        picked.append(line)
        total += len(line)
        if len(picked) >= max_lines or total >= max_chars:
            break
    return picked or None


def resolve_format(cert: str, unpacked: str, fmt_arg: str) -> tuple[str, str]:
    """定出证书格式。返回 (格式, 依据)；无法识别时抛 CertError。"""
    if fmt_arg != "auto":
        return fmt_arg, "由 --format 指定"
    # 先看扩展名：`.lpr` 与 LRAT 行语法相同，Alethe 是 Lisp 括号式，两者 sniff
    # 都分辨不出来，而它们该走各自的检查器。
    if cert.endswith(".lpr"):
        return "lpr", "扩展名为 .lpr"
    if cert.endswith((".alethe", ".alethe.txt")):
        return "alethe", "扩展名为 .alethe"
    fmt, why = sniff(unpacked)
    if fmt == "unknown":
        raise CertError(f"无法识别证书格式：{why}")
    return fmt, why


# ------------------------------------------------------------------ 各后端分支


def _fail(res: CheckResult, kind: str, reason: str, **extra: Any) -> CheckResult:
    res.failure = kind
    res.failure_reason = reason
    res.extra |= extra
    return res


def check_certificate(formula: str, cert: str, fmt_arg: str, timeout: float) -> CheckResult:
    """解压、定格式、跑对应校验器，给出结构化结论。

    格式解析必须在解压*之后*做（要读内容嗅探），而解压需要工作目录——所以两者都
    收在这里，调用方只需给 --format 的原值。

    失败一律走 `failure` 字段，不折叠进 `verdict`——「没拿到判决」与「判决是无效」
    是两件事，把前者报成后者就是伪证。
    """
    res = CheckResult()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="opl-certcheck.") as workdir:
        unpacked, note = load_cert(cert, workdir)
        if note:
            res.notes.append(note)
        res.fmt, res.fmt_why = resolve_format(cert, unpacked, fmt_arg)
        fmt = res.fmt
        cert_bytes = os.path.getsize(unpacked)

        if fmt == "drat":
            exe = find_tool("drat-trim")
            if exe is None:
                return _fail(res, "missing_backend", "缺少后端：drat-trim", missing=["drat-trim"])
            res.backend = "drat-trim"
            # 选项必须在文件*之后*——drat-trim 把第一个参数当输入文件。
            rc, res.log, _ = run_checker(
                exe, [formula, unpacked, "-t", str(int(timeout))], timeout)
            if rc is None:
                return _fail(res, "timeout", "drat-trim 超时")
            m = READ_BYTES_RE.search(res.log)
            parsed = int(m.group(1)) if m else None
            res.parsed_ok = (parsed == cert_bytes) if parsed is not None else None
            res.extra |= {"parsed_bytes": parsed, "certificate_bytes": cert_bytes}

        elif fmt == "lrat":
            exe = find_tool("lrat-check")
            if exe is None:
                return _fail(res, "missing_backend", "缺少后端：lrat-check", missing=["lrat-check"])
            res.backend = "lrat-check"
            rc, res.log, _ = run_checker(exe, [formula, unpacked], timeout)
            if rc is None:
                return _fail(res, "timeout", "lrat-check 超时")
            last = last_line_checked(res.log)
            res.extra["last_line_checked"] = last
            res.parsed_ok = (last > 0) if last is not None else None

        elif fmt == "lpr":
            # cake_lpr 是 CakeML 编译出的、经形式化验证的 LPR 检查器，信任等级高于
            # drat-trim（后者是未经验证的 C 程序）。但它有个必须处理的怪癖：
            # *退出码恒为 0*。空证明、非法提示号、截断证明全都返回 0，判决只在文本里。
            # 所以这里不读退出码做判决，只取输出，判决交给下面 derive_verdict。
            exe = find_tool("cake_lpr")
            if exe is None:
                return _fail(res, "missing_backend", "缺少后端：cake_lpr", missing=["cake_lpr"])
            res.backend = "cake_lpr"
            rc, res.log, _ = run_checker(exe, [formula, unpacked], timeout)
            if rc is None:
                return _fail(res, "timeout", "cake_lpr 超时")
            if rc != 0:
                # 非 0 只可能是进程级异常（崩溃），不是「证明无效」。
                return _fail(res, "backend_crashed", f"cake_lpr 异常退出（rc={rc}）")
            res.parsed_ok = None   # cake_lpr 不提供完整性自述，故不推断

        elif fmt == "alethe":
            # Carcara 检查 SMT 的 Alethe 证明（cvc5 产出）。stdout 只有一个词：
            # valid / holey / invalid，而退出码不区分它们。
            exe = find_tool("carcara")
            if exe is None:
                return _fail(res, "missing_backend", "缺少后端：carcara", missing=["carcara"])
            res.backend = "carcara"
            rc, res.log, _ = run_checker(exe, ["check", unpacked, formula], timeout)
            if rc is None:
                return _fail(res, "timeout", "carcara 超时")
            res.parsed_ok = None

        elif fmt == "clrat":
            dec, lrat = find_tool("decompress"), find_tool("lrat-check")
            if dec is None or lrat is None:
                return _fail(res, "missing_backend", "缺少后端：decompress 或 lrat-check",
                             missing=[n for n, p in (("decompress", dec), ("lrat-check", lrat)) if p is None])
            res.backend = "decompress|lrat-check"
            rc, dout, _ = run_checker(dec, ["-m", unpacked], timeout)
            if rc is None:
                return _fail(res, "timeout", "decompress 超时")
            bad = malformed_lrat(dout)
            if bad:
                # 已知上游 bug：绝不把解压器的问题算成证书的问题。
                return _fail(
                    res, "decompress_broken",
                    f"decompress 输出不是合法 LRAT（{len(bad)} 行异常，"
                    f"首个 {bad[0][:50]!r}）。上游 decompress.c 的 read_lit 内有一句"
                    f"遗留 printf 把原始字节写入 stdout；请换用修正后的 decompress，"
                    f"或改用 --format drat。",
                    decompress_broken=True, malformed_lines=len(bad))
            plain = os.path.join(workdir, "cert.lrat")
            with open(plain, "w", encoding="utf-8") as fh:
                fh.write(dout)
            rc, res.log, _ = run_checker(lrat, [formula, plain], timeout)
            if rc is None:
                return _fail(res, "timeout", "lrat-check 超时")
            last = last_line_checked(res.log)
            res.extra["last_line_checked"] = last
            res.parsed_ok = (last > 0) if last is not None else None

        else:
            return _fail(res, "format_unknown", f"未知格式：{fmt}")

        res.duration_ms = int((time.monotonic() - started) * 1000)
        derived = derive_verdict(fmt, res.log, res.parsed_ok, res)
        if derived.failure:
            return derived
        res.verdict = derived.verdict
        res.parsed_ok = derived.parsed_ok
        return res


def derive_verdict(fmt: str, log: str, parsed_ok: bool | None,
                   res: CheckResult) -> CheckResult:
    """从校验器输出里读出判决。各后端的信道不同，见模块 docstring。"""
    if fmt == "lpr":
        # cake_lpr 的退出码没有说话能力，判决只能从文本读：
        #   有 `s VERIFIED …`       -> 通过
        #   无判决行但有 `c ` 诊断  -> 被显式拒绝（诊断里带行号与原因）
        #   两者都没有              -> 无法判定，绝不猜
        if re.search(r"^s VERIFIED\b", log, re.M):
            res.verdict = "VERIFIED"
        elif re.search(r"^c \S", log, re.M):
            res.verdict = "NOT VERIFIED"
        else:
            res.verdict = None
        return res

    if fmt == "alethe":
        tok_m = re.search(r"^(valid|holey|invalid)\b", log, re.M)
        tok = tok_m.group(1) if tok_m else None
        if tok == "holey":
            # 有洞 = 部分验证：cvc5 对某些理论引理只吐 `:rule hole`，检查器无法核。
            # 它既不构成通过，也不构成推翻，因此绝不许升格为 exact_certificate。
            return _fail(res, "holey",
                         "carcara 判定 holey：证明含未验证的步骤（洞）。"
                         "这既不通过也不推翻，UNKNOWN 是唯一诚实的结论",
                         carcara_verdict="holey")
        if tok is None:
            return _fail(res, "unparseable", "carcara 未给出可识别判决")
        res.verdict = "VERIFIED" if tok == "valid" else "NOT VERIFIED"
        res.parsed_ok = True
        return res

    m = VERDICT_RE.search(log)
    res.verdict = m.group(1) if m else None
    return res


# ------------------------------------------------------------------ 证据记录


def build_record(*, res: CheckResult, formula: str, cert: str) -> dict[str, Any]:
    """组装 `opl.evidence/1` 记录。判决与「是否完整读入」都如实写进去。"""
    parsed_ok = res.parsed_ok
    record: dict[str, Any] = {
        "schema": "opl.evidence/1",
        "backend": res.backend,
        "format": res.fmt,
        "formula": os.path.abspath(formula),
        "formula_sha256": sha256(formula),
        "certificate": os.path.abspath(cert),
        "certificate_sha256": sha256(cert),
        "certificate_bytes": os.path.getsize(cert),
        "parse_complete": parsed_ok,
        "duration_ms": res.duration_ms,
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        # 检查器的诊断摘录。拒绝情形必须留证：「哪一行、什么原因」是事后审计
        # 唯一能回答「为什么这份证书不算」的东西。
        "checker_messages": checker_messages(res.log),
        **res.extra,
    }
    if res.failure:
        record |= {"verdict": "UNKNOWN", "verification_level": "none",
                   "reason": res.failure_reason, "failure": res.failure}
        return record
    if res.verdict == "VERIFIED":
        record |= {"verdict": "VERIFIED", "verification_level": "exact_certificate"}
    elif res.verdict == "NOT VERIFIED" and parsed_ok is False:
        record |= {"verdict": "UNKNOWN", "verification_level": "none",
                   "reason": "校验器未完整读入证书，NOT VERIFIED 不可信（疑似格式误判）"}
    elif res.verdict == "NOT VERIFIED":
        record |= {"verdict": "NOT VERIFIED", "verification_level": "none"}
    else:
        record |= {"verdict": "UNKNOWN", "verification_level": "none",
                   "reason": "校验器未给出判决行"}
    return record

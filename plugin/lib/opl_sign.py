"""签名：给「这份证据/这条记录是谁写的」加一道可复查的凭据。

== 它补的是哪一层缺口 ==

台账已经能查「记录自洽」（范围、对象、档位对得上）与「输入现在的内容」（每次写入重新
加载证据、重算它引用的见证/公式/Lean 文件的哈希）。两层都查不出来的是一种最简单的
攻击：**手写一份自洽的假证据**。

实测（第四轮之后仍可通过）：手写一个 `{"kind": "witness_eval", "verdict": "VERIFIED",
"witness": …, "witness_sha256": …, "spec": …, "spec_sha256": …}`，再手写那个见证文件，
然后把记录改成与它自洽——台账全盘接受，`formal_status=refuted`、档位
`exact_certificate`、反例盖上 `independent`。**哈希全对，因为写文件的人同时写了被引用
文件**；`verdict` 只是文件里的一行字，没有任何东西验过它。哈希证明的是**自洽**，
不是**来源**。

所以这一层用签名：证据由验证器产出时签一次，记录由 `save()` 写盘时签一次。签名证明
「这份字节是被谁用什么密钥签的」，哈希证明「现在这份字节是什么」。两件事互不替代：

* 只有签名、去掉重新加载 → 换掉被引用的见证文件（证据文件本身没动、签名仍然有效）
  就混过去了；
* 只有重新加载、没有签名 → 手写一份自洽的假证据就混过去了（上面那条）。

== 信任边界（说清楚，别当它是零信任）==

密钥在**本机**（`~/.config/open-problem-lab/`），沙箱的挂载是显式列表（只挂评估器与
实验定义），所以沙箱里的候选/评估器进程看不到它——这是它能挡住的主要对象。同一个用户
下、有 shell 的进程（包括宿主 agent）**仍然能读密钥、照样签**。签名把「写个 JSON」
升级成「动一次密钥」：那是不同性质、可以被计数、可以被审计的动作，它降的是**自欺的
概率**，涨的是**事后可复查性**，不是不可伪造。

== 为什么用 ssh-keygen 而不是自己算 ==

系统自带（OpenSSH 的 `-Y sign` / `-Y verify`），不用往 `lib/` 里加第三方依赖；用
SSHSIG 格式，签名里带**命名空间**，同一个密钥的签名不会被挪到别的用途上冒充；密钥将来
要换成 agent 持有或硬件钥匙时，这一层不用重写。另一种选择是 HMAC（标准库），但它对称
——能验的人就能签，只值「防手滑」，不配当防伪。

`ssh-keygen -Y verify` 的退出码是 0/255（不是 0/1），而且**它会往 stderr 写一行人话**。
实测踩过一次「看起来 rc=0」：那是管道的状态，不是它的。这里按退出码判，并把 stderr
原文带进理由。
"""

from __future__ import annotations

import os
import shutil
import subprocess

SIG_SUFFIX = ".sig"
NAMESPACE = "open-problem-lab"
IDENTITY = "opl-local"
KEY_ENV = "OPL_SIGNING_KEY"
KEYGEN_ARGS = ("-t", "ed25519", "-N", "", "-C", "open-problem-lab ledger signer")
TIMEOUT = 30.0


class SignError(Exception):
    """签名器不可用，或这次签名/验签失败。调用方翻成 MISSING(4) 或 REJECT(1)。"""


def _default_key_dir() -> str:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = xdg if xdg else os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "open-problem-lab")


def key_path() -> str:
    """签名密钥的位置。`OPL_SIGNING_KEY` 可以覆盖（测试与多环境都用它）。"""
    return os.environ.get(KEY_ENV) or os.path.join(_default_key_dir(), "ledger_ed25519")


def allowed_signers_path() -> str:
    """验签用的可信公钥清单，与密钥同目录。

    `ssh-keygen -Y verify` 必须有一个 `allowed_signers` 文件；把「谁可信」做成一份
    清单而不是写死在代码里，是为了以后加第二把（另一台机器、另一个人）时只多一行。
    本机自用只需要里面有一条自己的公钥。
    """
    return os.path.join(os.path.dirname(os.path.abspath(key_path())), "allowed_signers")


def sig_path(path: str) -> str:
    return path + SIG_SUFFIX


def ssh_keygen() -> str | None:
    return shutil.which("ssh-keygen")


def _key_is_encrypted(path: str) -> bool:
    """带口令的私钥会让 `ssh-keygen` 在终端上等输入——非交互场景会挂住。

    只读文件头判断一次，比「跑起来看它挂不挂」稳。工具密钥刻意要求**无口令**：它是
    自动流程的一部分，口令要么被旁路、要么变成阻塞。要口令保护的密钥，应当用
    ssh-agent 持有（那是以后的事，不是这一版）。
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            head = fh.read(400)
    except OSError:
        return False
    return "ENCRYPTED" in head


def signer_state() -> tuple[str, str]:
    """("ready" | "no_tool" | "no_key" | "key_encrypted", 人话说明)。"""
    exe = ssh_keygen()
    if exe is None:
        return "no_tool", ("找不到 ssh-keygen：本插件的签名用 OpenSSH 的 "
                           "`-Y sign`/`-Y verify`，不自己实现密码学。"
                           "装好 OpenSSH 客户端即可（多数系统自带）。")
    kp = key_path()
    if not os.path.isfile(kp):
        return "no_key", (f"还没有本机签名密钥：{kp}。"
                          f"跑一次 `opl-sign init` 生成（无口令的工具密钥，留在本机）。")
    if not os.path.isfile(kp + ".pub"):
        return "no_key", f"密钥存在但缺少公钥 {kp}.pub——重跑 `opl-sign init --force`"
    if _key_is_encrypted(kp):
        return "key_encrypted", (
            f"密钥有口令：{kp}。自动流程不交互输入口令（那是会挂住的那种失败）；"
            f"请换一把无口令的工具密钥（`opl-sign init --force`）。")
    if not os.path.isfile(allowed_signers_path()):
        return "no_key", (f"缺少验签清单 {allowed_signers_path()}——`opl-sign init` 会按"
                          f"公钥写好它")
    return "ready", f"签名器就绪：{kp}（公钥 {kp}.pub，验签清单 {allowed_signers_path()}）"


def _run(argv: list[str], *, stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    # `stdin=DEVNULL`：子进程在任何情况下都不该读我们的终端。ssh-keygen 会在某些情形下
    # **交互式提问**（例如目标签名已存在时问 "Overwrite (y/n)?"），非交互场景读到 EOF
    # 就什么都不做——而且**退出码仍然是 0**。给它一个空 stdin，让这种路径立刻结束，
    # 而不是等着一个永远不来的回答。
    return subprocess.run(argv, input=stdin,
                          stdin=None if stdin is not None else subprocess.DEVNULL,
                          capture_output=True, timeout=TIMEOUT)


def init_key(*, force: bool = False) -> tuple[str, str]:
    """生成本机工具密钥并写好验签清单。返回 (密钥路径, 说明)。

    **不覆盖已有的密钥**，除非 `force`——覆盖等于把此前所有签名的可验证性一起丢掉
    （旧记录还会验得过，但如果密钥被换掉，旧签名就开始报「核不过」）。
    """
    exe = ssh_keygen()
    if exe is None:
        raise SignError(signer_state()[1])
    kp = key_path()
    if os.path.isfile(kp) and not force:
        raise SignError(f"签名密钥已存在：{kp}（要覆盖加 --force；"
                        f"覆盖会让此前的签名无法再验，请确认你知道这一点）")
    parent = os.path.dirname(os.path.abspath(kp)) or "."
    os.makedirs(parent, mode=0o700, exist_ok=True)
    for stale in (kp, kp + ".pub", sig_path(kp)):
        if os.path.exists(stale):
            os.unlink(stale)
    res = _run([exe, *_keygen_argv(kp)])
    if res.returncode != 0:
        raise SignError(f"ssh-keygen 生成密钥失败（退出码 {res.returncode}）："
                        f"{res.stderr.decode('utf-8', 'replace').strip()}")
    os.chmod(kp, 0o600)
    pub = open(kp + ".pub", encoding="utf-8").read().strip()
    # 清单里写明命名空间：这把密钥只用来签本插件的记录/证据，被挪用到别处会验不过。
    with open(allowed_signers_path(), "w", encoding="utf-8") as fh:
        fh.write(f'{IDENTITY} namespaces="{NAMESPACE}" {pub}\n')
    os.chmod(allowed_signers_path(), 0o600)
    return kp, f"已生成 {kp}（公钥 {kp}.pub），验签清单 {allowed_signers_path()}"


def _keygen_argv(kp: str) -> list[str]:
    return [*KEYGEN_ARGS, "-f", kp]


def discard(path: str) -> None:
    """删掉一份**没有签成**的产出，连同可能遗留的旧签名。

    只删产物是不够的：如果上一次运行在同一路径留下过 `<path>.sig`，那份签名会留下来，
    于是盘上出现「一份没有内容的签名」。它不足以冒充有效（签的是别的字节，验不过），
    但「有 .sig」本身就是一种误导，而清垃圾是产出方自己的事。
    """
    for p in (path, sig_path(path)):
        try:
            os.unlink(p)
        except OSError:
            pass


def sign_file(path: str) -> str:
    """给一个文件产出 detached 签名 `<path>.sig`，返回签名路径。

    签名器不可用就抛 `SignError`——**不静默产出无签名的证据**。这与「找不到 bwrap 就
    不降级到裸跑」是同一条纪律：能验的东西必须是签过的，没签的东西不许冒充成能验的。
    """
    state, why = signer_state()
    if state != "ready":
        raise SignError(why)
    exe = ssh_keygen()
    if exe is None:                      # signer_state 已查过，这里只为类型收窄
        raise SignError("找不到 ssh-keygen")
    if not os.path.isfile(path):
        raise SignError(f"要签名的文件不存在：{path}")
    # == 先删掉旧签名，再签；签完**自己验一遍** ==
    #
    # `ssh-keygen -Y sign` 在 `<path>.sig` 已存在时会**交互式提问** "Overwrite (y/n)?"。
    # 非交互场景读到 EOF 就什么都不做，而**退出码仍然是 0**——于是「签名成功」其实是
    # 一份**旧签名**：文件内容已经变了，签名还是上一版的，验签必然失败。
    # 实测踩到：台账 `save()` 第一次写签名正常，第二次改写之后记录立刻变成「签名核不过」。
    # 这是这个项目反复记下的那类错：**退出码 0 不是「事情做成了」**。
    sig = sig_path(path)
    if os.path.exists(sig):
        os.unlink(sig)
    res = _run([exe, "-Y", "sign", "-f", key_path(), "-n", NAMESPACE, path])
    if res.returncode != 0 or not os.path.isfile(sig):
        raise SignError(f"签名失败（退出码 {res.returncode}）："
                        f"{res.stderr.decode('utf-8', 'replace').strip()}")
    os.chmod(sig, 0o644)
    ok, why = verify_file(path)          # 自检：我说签好了，那就得当场验得过
    if not ok:
        os.unlink(sig)
        raise SignError(f"签名产出后自检没通过，已丢弃这份签名：{why}")
    return sig


def sign_bytes(data: bytes) -> str:
    """给一段字节签出一个 SSHSIG（armored 文本），返回签名本身而不是文件路径。

    `ssh-keygen -Y sign` 只签文件，所以借一个临时文件：写进去、签、把签名读回来、
    临时目录随 `TemporaryDirectory` 一起消失。
    """
    import tempfile

    with tempfile.TemporaryDirectory(prefix="opl-sign.") as tmp:
        f = os.path.join(tmp, "payload")
        with open(f, "wb") as fh:
            fh.write(data)
        sign_file(f)
        with open(sig_path(f), encoding="utf-8") as fh:
            return fh.read()


def verify_bytes(blob: str, data: bytes) -> tuple[bool, str]:
    """核对一段字节与一份 SSHSIG（armored 文本）。返回 (是否可信, 理由)。"""
    import tempfile

    exe = ssh_keygen()
    if exe is None:
        return False, ("找不到 ssh-keygen，无法验签：本插件的签名用 OpenSSH 的 "
                       "`-Y sign`/`-Y verify`，不自己实现密码学。"
                       "「验不了」与「验不过」是两件事——这里如实报前者。")
    if not os.path.isfile(allowed_signers_path()):
        return False, (f"缺少验签清单 {allowed_signers_path()}——`opl-sign init` 会按本机"
                       f"公钥写好它；要验别处产出的签名，用 `opl-sign trust <公钥>` 加进去")
    with tempfile.TemporaryDirectory(prefix="opl-verify.") as tmp:
        sig = os.path.join(tmp, "sig")
        with open(sig, "w", encoding="utf-8") as fh:
            fh.write(blob)
        res = _run([exe, "-Y", "verify", "-f", allowed_signers_path(), "-I", IDENTITY,
                    "-n", NAMESPACE, "-s", sig], stdin=data)
    if res.returncode != 0:
        detail = res.stderr.decode("utf-8", "replace").strip().splitlines()
        return False, (f"签名核不过（ssh-keygen 退出码 {res.returncode}）："
                       f"{detail[-1] if detail else '（没有诊断输出）'}")
    return True, "签名可信"


def verify_file(path: str) -> tuple[bool, str]:
    """核对一个文件的签名。返回 (是否可信, 理由)。

    **两种形态都认**：内嵌（JSON 顶层有 `signature.value`）与旁挂（`<path>.sig`）。
    内嵌是记录用的形态——记录与签名必须在同一个文件里才能整体切换；旁挂是证据用的
    形态——证据由验证器一次写出，不存在「更新」这种事务（见 `opl_sign` 顶部说明）。

    **没有签名也是「不可信」**，而且理由要说得能办事：这是「谁写的」没有凭据，不是
    「文件坏了」。

    == 验签**不需要私钥** ==

    早先这里先调 `signer_state()`，于是「本机没有私钥」会让验签直接失败——那是个错。
    验签只要两样东西：`ssh-keygen`，和一份可信公钥清单。只有私钥而没有清单的机器签不出
    东西，但只要清单在，它就能验。把这两件事分开，才谈得上「把公钥给别人、让别人的
    机器复核」——本机自用不需要走到那一步，但函数不该先把那条路堵死。
    """
    sig = sig_path(path)
    if not os.path.isfile(path):
        return False, f"文件不存在：{path}"
    embedded = read_embedded(path)
    if embedded is not None:
        return verify_bytes(embedded, payload_of(path))
    if not os.path.isfile(sig):
        return False, (f"没有签名：{sig} 不存在——这份文件无法证明是本插件产出的"
                       f"（手写的 JSON 与工具写出的 JSON 在这一层上必须分得开）")
    exe = ssh_keygen()
    if exe is None:
        return False, ("找不到 ssh-keygen，无法验签：本插件的签名用 OpenSSH 的 "
                       "`-Y sign`/`-Y verify`，不自己实现密码学。"
                       "「验不了」与「验不过」是两件事——这里如实报前者。")
    if not os.path.isfile(allowed_signers_path()):
        return False, (f"缺少验签清单 {allowed_signers_path()}——`opl-sign init` 会按本机"
                       f"公钥写好它；要验别处产出的签名，用 `opl-sign trust <公钥>` 加进去")
    res = _run([exe, "-Y", "verify", "-f", allowed_signers_path(), "-I", IDENTITY,
                "-n", NAMESPACE, "-s", sig],
               stdin=open(path, "rb").read())
    if res.returncode != 0:
        detail = res.stderr.decode("utf-8", "replace").strip().splitlines()
        return False, (f"签名核不过（ssh-keygen 退出码 {res.returncode}）："
                       f"{detail[-1] if detail else '（没有诊断输出）'}")
    return True, f"签名可信：{sig}"


def read_embedded(path: str) -> str | None:
    """文件里有没有内嵌签名（JSON 顶层 `signature.value`）。没有就返回 None。"""
    import json

    try:
        with open(path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return None
    if isinstance(rec, dict):
        sig = rec.get("signature")
        if isinstance(sig, dict) and sig.get("value"):
            return str(sig["value"])
    return None


def payload_of(path: str) -> bytes:
    """内嵌签名覆盖的那部分字节：去掉 `signature` 之后的规范序列化。

    与 `opl_ledger.canonical_bytes()` 必须**逐字节一致**。这里不 import 台账（台账要
    import 本模块，会成环），改成同一条配方：`ensure_ascii=False, sort_keys=True,
    indent=2` 加一个尾换行。两处若漂移，症状是「刚签好的文件立刻验不过」——N7 用例
    盯着这一点。
    """
    import json

    with open(path, encoding="utf-8") as fh:
        rec = json.load(fh)
    payload = {k: v for k, v in rec.items() if k != "signature"}
    return (json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()

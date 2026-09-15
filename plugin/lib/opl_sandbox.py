"""opl_sandbox —— 候选程序在受控进程里执行所需的命令行构造。

一个职责：把「要跑什么、限成什么样」翻译成 `bwrap` / `systemd-run` 的命令行，
别的什么都不做。执行、计时、收口、快照在 `opl_run` 里。

== 为什么要有这个模块：三条实测推翻了三个想当然 ==

以下全部在本机实测（2026-09-15，systemd 261，bwrap 0.12.0，Arch，30 GiB 内存 /
8 GB swap），不是推断：

* **`systemd-run -p IPAddressDeny=any` 不禁网，而且不报错。**
  实测同一段 payload 在 `IPAddressDeny=any` 下照样连上 `1.1.1.1:443`。
  根因：`IPAddressDeny` 靠 cgroup 的 `bpf` 控制器，而本机根 cgroup 的
  `cgroup.controllers` 里**没有 `bpf`**（只有 `cpuset cpu io memory hugetlb pids
  rdma misc dmem`），用户 slice 委派的更少（`cpu memory pids`）。
  systemd 接受了这个属性、什么都不做——这是本项目第四次撞上「工具的返回值不携带
  我们要的那个区别」，所以**禁网一律走 `bwrap --unshare-net`**，并把它当成必须
  实测而非假定的能力。
* **`MemoryMax` 单独设拦不住内存。** 同一段逐页写 300 MB 的 payload：
  `MemoryMax=64M` → 退出 0、写成功（8 GB swap 把匿名页吸收了，cgroup 的
  `memory.swap.max` 默认是 `max`）；`MemoryMax=64M` **加上** `MemorySwapMax=0`
  → 被杀，退出码 `-9`，0.02 秒。所以内存限额必须两个属性一起下，少一个是装饰。
* **进程组 kill 收不住 `setsid` 逃逸，但 cgroup 与 PID namespace 收得住。**
  payload 里 `subprocess.Popen(['setsid', ...])` 起的孙子：只 `os.killpg` →
  孙子**活下来**；`systemctl --user kill --kill-whom=all` → 清干净；
  在 `bwrap --unshare-pid` 里只杀 bwrap 自己 → 也清干净（内核在 PID namespace 的
  init 终止时连坐杀掉其余进程）。结论：收口要么靠 cgroup，要么靠 `--unshare-pid`，
  **不能只靠进程组**。

还有两条操作性的坑，也来自实测：

* **不要用管道接 payload 的 stdout。** 孙子会继承管道写端，父进程被杀了管道也不关，
  `subprocess.communicate()` 于是**永远等下去**（实测卡满 90 秒）。快照本来就要留存
  流，所以直接落到文件。
* **`--scope` 的单位名必须以 `.scope` 结尾**，写成 `.service` 会得到
  `Failed to start transient scope unit: Cannot set property PIDs, or unknown property`。
  另外 service 模式下 payload 的输出进 journal 而不回到调用方——对要留存 stdout 的
  工具是致命的，所以一律用 `--scope`。
* **bwrap 里跑外部脚本要 bind 工作目录并 chdir**，光给绝对路径会得到
  `can't open file '//payload.py'`。`/bin` 是 `usr/bin` 的软链，不显式
  `--symlink usr/bin /bin` 会 `execvp: No such file or directory`。
"""

from __future__ import annotations

import os
import shutil
from typing import Any

# 只读绑定的系统路径。这份清单是**实测过能跑通 python3** 的最小集合，不要凭直觉加：
# 加一条就要重跑一次回归，理由和减一条一样。
_RO_SYSTEM = [("/usr", "/usr"), ("/etc", "/etc"), ("/lib64", "/lib64")]

BWRAP = shutil.which("bwrap") or "/usr/bin/bwrap"
SYSTEMD_RUN = shutil.which("systemd-run") or "/usr/bin/systemd-run"
SYSTEMCTL = shutil.which("systemctl") or "/usr/bin/systemctl"

# 「能不能连出去」的最小 payload，**用退出码说话**：0 = 连出去了，1 = 连不出去。
# 不用 stdout 解析，就少一层会被脏输出干扰的地方。
NET_PROBE = (
    "import socket, sys\n"
    "try:\n"
    "    socket.create_connection(('1.1.1.1', 443), timeout=2)\n"
    "    sys.exit(0)\n"
    "except OSError:\n"
    "    sys.exit(1)\n"
)

# 「内存限额真的会开火吗」的 payload：逐页写，逼内核真的分配（`bytearray(n)` 单独
# 用不行——它走 mmap，页不被触碰，`memory.current` 只有几 MB，测不出限制）。
def mem_probe_mb(mb: int) -> str:
    return (
        f"buf = bytearray({mb} * 1024 * 1024)\n"
        "for i in range(0, len(buf), 4096):\n"
        "    buf[i] = 1\n"
        "print('WROTE', flush=True)\n"
    )


def bwrap_argv(inner: list[str], *, workdir: str, net_off: bool = True,
               unshare_pid: bool = True, ro_binds: list[tuple[str, str]] | None = None,
               rw_binds: list[tuple[str, str]] | None = None) -> list[str]:
    """构造 bwrap 命令行：`inner` 是**沙箱内**要跑的命令行。

    `workdir` 会以**读写**方式绑到 `/work` 并 chdir 过去——候选程序要能写自己的
    产物目录，而快照只认这个目录里的东西。`inner` 里引用它请用 `/work/...`。

    `unshare_pid` 默认开：它同时提供「收口」（见模块 docstring）与「候选看不见宿主
    进程」。别为了省一个参数关掉它，那会把收口能力一起关掉。
    """
    argv = [BWRAP]
    for src, dst in _RO_SYSTEM:
        if os.path.exists(src):
            argv += ["--ro-bind", src, dst]
    # /bin 与 /lib 在 Arch 上是 usr 下的软链，不显式重建就会 execvp 失败。
    argv += ["--symlink", "usr/bin", "/bin"]
    if os.path.islink("/lib"):
        argv += ["--symlink", "usr/lib", "/lib"]
    for src, dst in (ro_binds or []):
        argv += ["--ro-bind", src, dst]
    for src, dst in (rw_binds or []):
        argv += ["--bind", src, dst]
    argv += ["--proc", "/proc", "--dev", "/dev"]
    if net_off:
        argv += ["--unshare-net"]
    if unshare_pid:
        argv += ["--unshare-pid"]
    # 父进程（我们的 runner）死掉时不要让沙箱活在世上。
    argv += ["--die-with-parent"]
    argv += ["--bind", workdir, "/work", "--chdir", "/work", "--tmpfs", "/tmp"]
    return argv + inner


def bwrap_python_argv(python: str, code: str, **kw: Any) -> list[str]:
    """跑一段 `-c` 代码的便捷包装（探测与一次性任务用）。"""
    return bwrap_argv([python, "-c", code], **kw)


def scope_argv(argv: list[str], *, unit: str, mem_max_mb: int | None = None,
               swap_max_mb: int = 0, cpu_quota_percent: int | None = None,
               pids_max: int | None = None) -> list[str]:
    """把一条命令包进 transient `.scope`，从而拿到一个**我们拥有的 cgroup**。

    `swap_max_mb` 默认 0 而不是不设：见模块 docstring——只设 `MemoryMax` 时
    8 GB swap 会把匿名页吃下去，限额变成装饰。要放开得显式传参，不能靠省略。

    `unit` 必须以 `.scope` 结尾。写成 `.service` 会被拒绝，而且 service 模式下
    payload 的输出进 journal，拿不回来。
    """
    if not unit.endswith(".scope"):
        raise ValueError(f"unit 必须以 .scope 结尾：{unit!r}")
    out = [SYSTEMD_RUN, "--user", "--scope", "--quiet", f"--unit={unit}"]
    if mem_max_mb is not None:
        out += ["-p", f"MemoryMax={mem_max_mb}M", "-p", f"MemorySwapMax={swap_max_mb}M"]
    if cpu_quota_percent is not None:
        out += ["-p", f"CPUQuota={cpu_quota_percent}%"]
    if pids_max is not None:
        out += ["-p", f"TasksMax={pids_max}"]
    return out + argv


def kill_unit_argv(unit: str, *, signal_name: str = "SIGKILL") -> list[str]:
    """收口用的命令行：杀**整个 cgroup**，而不是一个进程。

    这是实测出来的必要性，不是保险：payload 里 `setsid` 出来的孙子在另一个会话里，
    `os.killpg` 打不到它；cgroup 打得到。
    """
    if not unit.endswith(".scope"):
        raise ValueError(f"unit 必须以 .scope 结尾：{unit!r}")
    return [SYSTEMCTL, "--user", "kill", "--kill-whom=all",
            f"--signal={signal_name}", unit]


def stop_unit_argv(unit: str) -> list[str]:
    return [SYSTEMCTL, "--user", "stop", unit]

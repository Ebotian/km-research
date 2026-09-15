"""opl_run —— 把「跑一个候选任务」变成一份可复核的运行快照。

一个职责：在受控的进程里执行一条命令，并如实记下四份快照
（`cmd` / `env` / `capabilities` / `metrics`）。不评估结果好坏，那是 `opl_evolve` 的事。

== 沙箱形态：为什么不用 systemd-run，而自己建 cgroup ==

上一片（`opl_sandbox`）测出 `systemd-run -p IPAddressDeny=any` 不禁网、也不报错，
禁网因此交给 `bwrap --unshare-net`。这一片又测出两件事，把执行形态改了：

* **transient scope 的 cgroup 在进程死后拿不到。** `systemctl --user show <unit>
  -p ControlGroup` 事后返回空——单元已被回收。于是「这个进程是被 OOM 杀的」这件事
  只能靠推断，没有硬证据。
* **自己建的子 cgroup 死后照样能读。** 在
  `<user>@<uid>.service/app.slice/` 下 `mkdir`（用户 slice 已把 `memory` / `pids`
  委派下来），写 `memory.max` + `memory.swap.max`，把 payload 的 pid 写进
  `cgroup.procs`，进程死后：

      memory.events  oom 1 / oom_kill 1      ← 内核直说「我因内存杀了它」
      memory.peak    67108864                ← 确实顶到 64M 上限

  这是**决定性证据**而不是推断，所以判据 3 的归属靠它。
  另外 `cgroup.kill`（写 1）实测能连 `setsid` 逃逸一起收掉——收口也不必再依赖 systemd。

所以执行形态是：**自己的 per-run cgroup（限额 + 收口 + 归因）套住 `bwrap`（内核隔离）**。

== 一条没做、如实记下的事：CPU 配额 ==

`app.slice` 的 `cgroup.subtree_control` 只有 `memory pids`，所以我们的子 cgroup 里
**没有 `cpu.max`**。实测**可以**自己写 `+cpu` 把它加上（写进 `cgroup.subtree_control`
成功了，之后新建的子 cgroup 就有 `cpu.max`）——但那是**改动整个用户会话的 cgroup 树**
这种共享状态，不是我们该顺手做的事（我实测后已还原）。所以本模块**不设 CPU 配额**，
并在快照里记 `cpu_quota: {"enforced": false, "reason": ...}` 而不是假装设了。
`systemd-run -p CPUQuota=` 能限 CPU，但它把进程挪进 systemd 自己的树，我们就同时失去
`memory.events` 这条硬信道——两者不可兼得，选了硬证据。

== 给候选程序的一条约定：工作目录在沙箱里是 `/work` ==

`bwrap` 把 `--workdir` 绑到 `/work` 并 chdir 过去，所以候选程序**必须用相对路径或
`/work/...`**。写宿主绝对路径（比如 `/tmp/xxx/out.txt`）会在沙箱里找不到那个目录而
失败——这一条我实测踩过：payload 用宿主绝对路径写文件，运行报 `payload_failed`，
看起来像「候选写错了」，其实是路径约定没对上。

== 停滞风险最大的两处，都有实测依据 ==

* **不要用管道接 payload 的 stdout。** 孙子继承写端后管道不关，`communicate()`
  会永远等下去（实测卡满 90 秒）。所以流一律落文件——快照本来要留存它们。
* **超出 deadline 后必须连坐收口。** `os.killpg` 收不住 `setsid` 逃逸（实测孙子活
  下来），要写 `cgroup.kill`。
"""

from __future__ import annotations

import json
import os
import platform
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any

import opl_probe
import opl_sandbox as sandbox

# 运行的结局。分成这些值而不是「成功/失败」，是因为它们的**证据强度不同**：
# `oom` 有内核给的 oom_kill 计数，`oom_inferred` 只有「死在 deadline 之前且是
# SIGKILL」。把两者混成一个标签，等于让推断冒充证据。
OK = "ok"
PAYLOAD_FAILED = "payload_failed"
TIMEOUT = "timeout"
OOM = "oom"
OOM_INFERRED = "oom_inferred"
SIGNAL = "signal"
SANDBOX_ERROR = "sandbox_error"
BACKEND_MISSING = "backend_missing"

# 这些结局都表示「没有判决」——不要把它读成「任务失败」。
NO_VERDICT = frozenset({TIMEOUT, OOM, OOM_INFERRED, SIGNAL, SANDBOX_ERROR})

CGROUP_ROOT = "/sys/fs/cgroup"
# systemd 把用户会话的可写委派点放在这里。子目录建在这儿才拿得到 memory/pids。
_DELEGATE_TAIL = "app.slice"


def user_delegate_dir() -> str:
    """本用户可写的最小 cgroup 委派点。找不到返回空串。"""
    uid = os.getuid()
    for cand in (
        f"{CGROUP_ROOT}/user.slice/user-{uid}.slice/user@{uid}.service/{_DELEGATE_TAIL}",
        f"{CGROUP_ROOT}/user.slice/user-{uid}.slice/{_DELEGATE_TAIL}",
    ):
        if os.path.isdir(cand):
            return cand
    return ""


class CgroupError(Exception):
    pass


@dataclass
class Cgroup:
    """本次运行独占的 cgroup。拿不到就 `available=False`，绝不假装限额生效。"""

    name: str
    path: str = ""
    available: bool = False
    reason: str = ""
    controllers: dict[str, str | None] = field(default_factory=dict)

    @classmethod
    def create(cls, name: str, *, mem_max_mb: int | None, swap_max_mb: int,
               pids_max: int | None) -> "Cgroup":
        base = user_delegate_dir()
        cg = cls(name=name)
        if not base:
            cg.reason = ("找不到可写的 cgroup 委派点（cgroup v2 + systemd 用户会话？）；"
                         "内存与进程数限额**未生效**")
            return cg
        path = os.path.join(base, name)
        try:
            os.makedirs(path, exist_ok=True)
        except OSError as exc:
            cg.reason = f"建 cgroup 失败：{exc.strerror or exc}"
            return cg
        cg.path = path
        try:
            if mem_max_mb is not None:
                _write(path, "memory.max", f"{mem_max_mb * 1024 * 1024}")
                # swap 一起限下去：只设 memory.max 时 8 GB swap 会把匿名页吸收掉，
                # 限额变成装饰（见 opl_sandbox 的实测）。
                _write(path, "memory.swap.max", f"{swap_max_mb * 1024 * 1024}")
                cg.controllers["memory.max"] = _read(path, "memory.max")
                cg.controllers["memory.swap.max"] = _read(path, "memory.swap.max")
            if pids_max is not None:
                _write(path, "pids.max", str(pids_max))
            cg.available = True
        except OSError as exc:
            cg.reason = f"写限额失败：{exc.strerror or exc}"
        return cg

    def attach(self, pid: int) -> None:
        """把进程挪进来。子进程会继承，所以放 bwrap 一个就够。"""
        if self.available:
            _write(self.path, "cgroup.procs", str(pid))

    def read(self, leaf: str) -> str | None:
        if not self.available:
            return None
        return _read(self.path, leaf)

    def oom_kills(self) -> int | None:
        """内核记账的 OOM 击杀次数。这是判据 3 的硬证据。"""
        txt = self.read("memory.events")
        if not txt:
            return None
        for line in txt.splitlines():
            if line.startswith("oom_kill"):
                try:
                    return int(line.split()[1])
                except (IndexError, ValueError):
                    return None
        return None

    def kill_all(self) -> str:
        """收口：写 `cgroup.kill`。比 `os.killpg` 硬——实测前者收得住 `setsid` 逃逸。

        返回实际用了哪一招，供快照如实记录。
        """
        if self.available:
            try:
                _write(self.path, "cgroup.kill", "1")
                return "cgroup.kill"
            except OSError:
                pass
        return "process_group"

    def cleanup(self) -> None:
        if self.available and self.path:
            try:
                os.rmdir(self.path)
            except OSError:
                # 还有进程在里面时会 EBUSY——那是事实，不该吞掉。
                pass


def _write(path: str, leaf: str, value: str) -> None:
    with open(os.path.join(path, leaf), "w", encoding="utf-8") as fh:
        fh.write(value)


def _read(path: str, leaf: str) -> str | None:
    try:
        with open(os.path.join(path, leaf), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return None


# 启动器：**先把自己移进 cgroup，再 exec 目标**。
#
# 为什么不能在 Popen 之后由父进程写 `cgroup.procs`：那有竞态。实测 bwrap 会在我们
# 写之前就把 payload fork 出去，于是只有 bwrap 自己进了 cgroup，payload 留在原来的
# cgroup 里——表现是 `memory.peak` 只有 256 KB、192 MB 的分配照样成功、
# `memory.events` 全 0，而「限额已设」看起来一切正常。这是本项目第五次撞上
# 「工具的返回值不携带我们要的那个区别」：写 `cgroup.procs` 成功 ≠ 目标进程被限住。
#
# 在 exec 之前移动则没有竞态：cgroup 成员资格按进程记、由 fork 继承，所以 exec 之后
# 的 bwrap 与它 fork 出来的整棵树都在我们的 cgroup 里。
_LAUNCHER = (
    "import os, sys\n"
    "try:\n"
    "    open(sys.argv[1], 'w').write(str(os.getpid()))\n"
    "except OSError:\n"
    "    pass\n"
    "os.execv(sys.argv[2], sys.argv[2:])\n"
)


@dataclass
class RunSpec:
    argv: list[str]
    workdir: str
    run_id: str = "run"
    runner_dir: str = ""          # 快照落这里（runs/<id>/）
    timeout: float = 60.0
    mem_max_mb: int | None = None
    swap_max_mb: int = 0
    pids_max: int | None = 256
    net_off: bool = True
    sandboxed: bool = True        # False 只在诊断/自检时用，快照里会明确记下来
    # 只读挂进沙箱的额外文件：`(宿主路径, 沙箱内路径)`。用途是把**可信的东西**
    # （评估器、冻结的实验定义）递进去而不把整个实验目录暴露给候选。
    ro_binds: list[tuple[str, str]] = field(default_factory=list)


@dataclass
class RunResult:
    kind: str
    elapsed_ms: int = 0
    payload_exit: int | None = None
    payload_signal: int | None = None
    stdout_path: str = ""
    stderr_path: str = ""
    containment: str = ""
    cgroup: dict[str, Any] = field(default_factory=dict)
    sandbox: dict[str, Any] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)


# ------------------------------------------------------------------ 状态文件
#
# 长任务不用句柄轮询，用文件——这是 `doc/plan/02-architecture.typ` 定的形态，也是
# Unix 的既有做法。好处不只是省事：**「超时重发」天然变成续跑而非重跑**，因为状态
# 落在盘上而不是某个进程的内存里。判据 6 要验的正是这一点（幂等，不重跑）。

STATUS_SCHEMA = "opl.run.status/1"
RUNNING = "running"
DONE = "done"


def status_path(runner_dir: str) -> str:
    return os.path.join(runner_dir, "status.json")


def write_status(runner_dir: str, **fields: Any) -> str:
    """原子写状态。

    为什么必须原子：`--wait` 是另一个进程在轮询这个文件，半截 JSON 会被读成
    「文件坏了」。先写同目录临时文件再 `os.replace`（同一文件系统内是原子的），
    读方要么看到旧内容、要么看到新内容，不会看到中间态。
    """
    os.makedirs(runner_dir, exist_ok=True)
    path = status_path(runner_dir)
    rec = {"schema": STATUS_SCHEMA, "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    rec |= fields
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


def read_status(runner_dir: str) -> dict[str, Any] | None:
    """读状态。文件还没出现或读坏都返回 None——**不**把读不到当成某个结局。"""
    try:
        with open(status_path(runner_dir), encoding="utf-8") as fh:
            obj = json.load(fh)
    except (OSError, ValueError):
        return None
    return obj if isinstance(obj, dict) else None


def wait_status(runner_dir: str, *, timeout: float = 3600.0,
                poll: float = 0.2) -> dict[str, Any] | None:
    """轮询到终态。**只读，不重跑**——这是幂等的全部含义。

    超时返回 None（「还不知道」，不是「失败」），由调用方翻成 UNKNOWN(3)。
    """
    deadline = time.monotonic() + max(timeout, 0.0)
    while True:
        st = read_status(runner_dir)
        if st is not None and st.get("state") == DONE:
            return st
        if time.monotonic() >= deadline:
            return st          # 可能 None，也可能是 running——都表示「还没结论」
        time.sleep(poll)


def dispatch(spec: RunSpec, *, confirm_timeout: float = 5.0) -> dict[str, Any]:
    """后台跑同一个 run：起一个脱离会话的子进程，等它确认「已开始」再返回。

    为什么要等确认而不是直接返回：盲派发无法区分「已经在跑」与「子进程根本没起来」。
    确认的凭据是子进程自己写的 `status.json`（`state=running`）——它比父进程的猜测硬。
    """
    argv = [sys.executable, os.path.join(plugin_bin_dir(), "opl-run"),
            "--runs-dir", os.path.dirname((spec.runner_dir or spec.workdir).rstrip("/")),
            "--id", spec.run_id, "--workdir", spec.workdir,
            "--timeout", str(spec.timeout)]
    if spec.mem_max_mb is not None:
        argv += ["--mem-mb", str(spec.mem_max_mb)]
    if spec.pids_max is not None:
        argv += ["--pids-max", str(spec.pids_max)]
    if not spec.net_off:
        argv += ["--allow-net"]
    if not spec.sandboxed:
        argv += ["--no-sandbox"]
    argv += ["--", *spec.argv]

    started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    write_status(spec.runner_dir, run_id=spec.run_id, state="dispatched",
                 started_at=started, argv=spec.argv)
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    deadline = time.monotonic() + confirm_timeout
    while time.monotonic() < deadline:
        st = read_status(spec.runner_dir)
        if st is not None and st.get("state") == RUNNING:
            return {"confirmed": True, "pid": proc.pid, "status": st}
        if proc.poll() is not None:
            # 子进程已经退了却还没写 running：它多半是当场失败了，如实报。
            return {"confirmed": False, "pid": proc.pid, "returncode": proc.returncode,
                    "status": read_status(spec.runner_dir)}
        time.sleep(0.05)
    return {"confirmed": False, "pid": proc.pid, "status": read_status(spec.runner_dir),
            "note": f"{confirm_timeout}s 内没等到子进程写下 running"}


def plugin_bin_dir() -> str:
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin")


# ------------------------------------------------------------------ 执行


def execute(spec: RunSpec) -> RunResult:
    """跑一次，返回结局。**判决取证据，不取感觉**（见模块 docstring）。"""
    res = RunResult(kind=SANDBOX_ERROR)
    res.sandbox = {"sandboxed": spec.sandboxed, "net_off": spec.net_off,
                   "mem_max_mb": spec.mem_max_mb, "swap_max_mb": spec.swap_max_mb,
                   "pids_max": spec.pids_max, "timeout_s": spec.timeout,
                   "ro_binds": [list(b) for b in spec.ro_binds]}

    if not os.path.isdir(spec.workdir):
        res.notes.append(f"工作目录不存在：{spec.workdir}")
        return res
    os.makedirs(spec.runner_dir or spec.workdir, exist_ok=True)
    res.stdout_path = os.path.join(spec.runner_dir or spec.workdir, "stdout.txt")
    res.stderr_path = os.path.join(spec.runner_dir or spec.workdir, "stderr.txt")

    argv = list(spec.argv)
    if spec.sandboxed:
        if not os.path.exists(sandbox.BWRAP):
            res.kind = BACKEND_MISSING
            res.notes.append(
                f"找不到 bwrap（{sandbox.BWRAP}）：无法提供禁网与进程隔离。"
                f"不降级到「裸跑」——那会静默丢掉隔离这一整块保证。")
            return res
        argv = sandbox.bwrap_argv(argv, workdir=spec.workdir, net_off=spec.net_off,
                                  ro_binds=spec.ro_binds)

    cg = Cgroup.create(f"opl-run-{spec.run_id}", mem_max_mb=spec.mem_max_mb,
                       swap_max_mb=spec.swap_max_mb, pids_max=spec.pids_max)
    res.cgroup = {"available": cg.available, "path": cg.path, "reason": cg.reason,
                  "limits": cg.controllers}
    if spec.mem_max_mb is not None and not cg.available:
        res.notes.append("内存限额未生效：" + (cg.reason or "未知原因"))

    try:
        rc, elapsed, containment, oom = _spawn_and_wait(argv, spec, cg)
        res.elapsed_ms = elapsed
        res.containment = containment
        res.payload_exit = rc if rc is not None and rc >= 0 else None
        res.payload_signal = -rc if rc is not None and rc < 0 else None
        res.kind = _classify(rc, elapsed, spec, oom, res)
        if oom is not None:
            res.cgroup["oom_kill"] = oom
        # 进程已经死了，但 cgroup 还在我们手里——峰值与记账只能在这时读，且必须在
        # cleanup 之前。这就是「自己建 cgroup」比「transient scope」值钱的地方。
        res.cgroup["peak"] = cg.read("memory.peak")
        res.cgroup["memory_events"] = cg.read("memory.events")
    finally:
        cg.cleanup()
    return res


def run_with_status(spec: RunSpec, *,
                    deep_capabilities: bool = False) -> tuple[RunResult, dict[str, str]]:
    """前台跑一次，并把 `running` → `done` 两态写进 `status.json`。

    状态由**执行者自己**写，不由派发者代笔：代笔的话，`--detach` 的父进程退出时会
    留下一个永远停在 `running` 的记录，而真正的跑者早已不在。

    返回 (结局, 快照路径)。快照路径**直接返回**而不是让调用方回读 `status.json`
    ——壳里少一处可能写错名字的地方（这里刚踩过：壳引用了未导入的 `read_status`，
    类型检查器看不见 `bin/`，只有回归把它照出来了）。
    """
    started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    write_status(spec.runner_dir, run_id=spec.run_id, state=RUNNING,
                 pid=os.getpid(), started_at=started, argv=spec.argv,
                 workdir=spec.workdir, timeout_s=spec.timeout,
                 mem_max_mb=spec.mem_max_mb, net_off=spec.net_off,
                 sandboxed=spec.sandboxed)
    res = execute(spec)
    files = write_snapshots(spec, res, deep_capabilities=deep_capabilities)
    write_status(spec.runner_dir, run_id=spec.run_id, state=DONE, kind=res.kind,
                 pid=os.getpid(), started_at=started, argv=spec.argv,
                 workdir=spec.workdir, timeout_s=spec.timeout,
                 mem_max_mb=spec.mem_max_mb, net_off=spec.net_off,
                 sandboxed=spec.sandboxed,
                 elapsed_ms=res.elapsed_ms, payload_exit_code=res.payload_exit,
                 payload_signal=res.payload_signal, cgroup=res.cgroup,
                 notes=res.notes, snapshots=files)
    return res, files


def _spawn_and_wait(argv: list[str], spec: RunSpec,
                    cg: Cgroup) -> tuple[int | None, int, str, int | None]:
    """起进程、等它、必要时收口。返回 (rc, 毫秒, 收口方式, oom_kill)。"""
    t0 = time.monotonic()
    containment = ""
    # 进 cgroup 的动作交给启动器在 exec 之前做，父进程事后写 cgroup.procs 有竞态
    # （见 _LAUNCHER 的注释）。cgroup 不可用时就不套启动器，保持命令行干净。
    launch = argv
    if cg.available:
        launch = [sys.executable, "-c", _LAUNCHER,
                  os.path.join(cg.path, "cgroup.procs"), *argv]
    with open(res_path(spec, "stdout.txt"), "wb") as out, \
            open(res_path(spec, "stderr.txt"), "wb") as err:
        # 落文件而不是管道的理由见模块 docstring（孙子占住管道会让等待永不返回）。
        # start_new_session 给一个自己的进程组，作为拿不到 cgroup 时的兜底手段。
        proc = subprocess.Popen(launch, stdout=out, stderr=err, stdin=subprocess.DEVNULL,
                                start_new_session=True)
        try:
            proc.wait(timeout=spec.timeout)
            rc: int | None = proc.returncode
        except subprocess.TimeoutExpired:
            containment = cg.kill_all()
            if containment == "process_group":
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            rc = None                      # None = 我们杀的，不是它自己的结局
    elapsed = int((time.monotonic() - t0) * 1000)
    return rc, elapsed, containment, cg.oom_kills()


def res_path(spec: RunSpec, leaf: str) -> str:
    return os.path.join(spec.runner_dir or spec.workdir, leaf)


def _classify(rc: int | None, elapsed_ms: int, spec: RunSpec, oom: int | None,
              res: RunResult) -> str:
    """结局判定。

    顺序不是随便排的：**内核的 OOM 记账优先于退出码**。实测 bwrap 会把被杀子进程的
    结局翻成一个正退出码（137），于是「沙箱按内存杀了它」看起来就像「它自己失败了」。
    先看 rc 会把沙箱的决定记成 payload 的判决——两个完全不同的结论。
    """
    if oom is not None and oom > 0:
        res.notes.append(f"memory.events.oom_kill={oom}（内核记账，硬证据）")
        res.notes.append(f"被杀的进程经 bwrap 传出退出码 {rc}；那是 bwrap 的转写，"
                         f"不是 payload 自己的退出码，故不计入 payload_exit_code")
        res.payload_exit = None
        res.payload_signal = None
        return OOM
    if rc is None:
        # 我们按 deadline 杀的。**不许**把它记成 payload 自己的失败。
        return TIMEOUT
    if rc == 0:
        return OK
    if rc > 0:
        res.payload_exit = rc
        return PAYLOAD_FAILED
    # rc < 0：被信号杀的。谁杀的？
    sig = -rc
    if sig == signal.SIGKILL and elapsed_ms < spec.timeout * 1000:
        # 死在 deadline 之前又是 SIGKILL：不是我们杀的，但**没有内核记账**，
        # 所以标成推断而非事实。
        res.notes.append("死因是推断：SIGKILL 且早于 deadline，但没有 cgroup 记账")
        return OOM_INFERRED
    res.payload_signal = sig
    return SIGNAL


# ------------------------------------------------------------------ 快照


def cmd_snapshot(spec: RunSpec, res: RunResult) -> dict[str, Any]:
    return {
        "schema": "opl.run.cmd/1",
        "run_id": spec.run_id,
        "argv": spec.argv,
        "cwd": spec.workdir,
        "timeout_s": spec.timeout,
        "sandbox": res.sandbox,
        "cgroup": res.cgroup,
        "containment_used": res.containment,
        "host": {
            "nproc": os.cpu_count(),
            "mem_total_mb": _mem_total_mb(),
            "uid": os.getuid(),
        },
    }


def env_snapshot(spec: RunSpec) -> dict[str, Any]:
    """只留**判定相关**的环境变量，不整包拷 `os.environ`。

    凭什么：环境里可能有凭据，而快照是要进版本控制、要被人读的。留下影响执行的那几项
    就够了。这不是洁癖——把 `os.environ` 整个写进 `runs/<id>/env.json` 就是把
    `*_TOKEN` 之类的东西抄进了仓库。
    """
    keep = ("PATH", "HOME", "LANG", "LC_ALL", "TZ", "SHELL", "USER")
    return {
        "schema": "opl.run.env/1",
        "python": {"executable": sys.executable,
                   "version": platform.python_version()},
        "vars": {k: os.environ[k] for k in keep if k in os.environ},
        "sandbox_backends": {"bwrap": sandbox.BWRAP, "systemd_run": sandbox.SYSTEMD_RUN,
                            "systemctl": sandbox.SYSTEMCTL},
        "note": "只留判定相关的变量；完整环境可能含凭据，不进快照",
    }


def capabilities_snapshot(*, deep: bool = False) -> dict[str, Any]:
    """运行环境的能力快照（判据 1 的第三份）。

    默认**不跑**功能性沙箱探测：那要起进程（约 0.5 秒），而每次跑一个候选都付这个钱
    不值得。默认只记「有没有、什么版本」与 cgroup 委托情况，并如实标注功能性探测没跑
    ——需要功能结论就单独跑 `opl-capabilities --layer sandbox`。
    """
    tools: dict[str, Any] = {}
    for name in ("bwrap", "systemd-run", "systemctl", "docker"):
        tools[name] = opl_probe.probe_executable(name, "--version", 5.0)
    base = "" if deep else "（未跑功能性探测；用 opl-capabilities --layer sandbox 取）"
    snap: dict[str, Any] = {
        "schema": "opl.run.capabilities/1",
        "tools": tools,
        "cgroup": {"delegate_dir": user_delegate_dir() or None},
        "functional_probe": ("见 sandbox_probe" if deep else base),
    }
    if deep:
        snap["sandbox_probe"] = opl_probe.probe_sandbox()
    return snap


def metrics_snapshot(spec: RunSpec, res: RunResult) -> dict[str, Any]:
    """`metrics` 里的每个值都带**来源**——这是「能追到具体产物文件」的可检查形式。"""
    out_p = os.path.join(spec.runner_dir or spec.workdir, "stdout.txt")
    err_p = os.path.join(spec.runner_dir or spec.workdir, "stderr.txt")
    return {
        "schema": "opl.run.metrics/1",
        "verdict": res.kind,
        "wall_ms": res.elapsed_ms,
        "payload_exit_code": res.payload_exit,
        "payload_signal": res.payload_signal,
        "stdout_bytes": _size(out_p),
        "stderr_bytes": _size(err_p),
        "peak_mem_bytes": _int_or_none(res.cgroup.get("peak")),
        "oom_kill": res.cgroup.get("oom_kill"),
        "sources": {
            "wall_ms": "runner 墙钟（time.monotonic）",
            "stdout_bytes": out_p,
            "stderr_bytes": err_p,
            "peak_mem_bytes": (res.cgroup.get("evidence") or {}).get("memory.peak")
                              or "（无 cgroup 证词）",
            "oom_kill": (res.cgroup.get("evidence") or {}).get("memory.events")
                        or "（无 cgroup 证词）",
            "payload_exit_code": "子进程退出码；被信号杀时为 null",
        },
        "artifacts": {
            "stdout": out_p, "stderr": err_p,
            "workdir": spec.workdir,
            "runner_dir": spec.runner_dir or spec.workdir,
        },
    }


def _int_or_none(v: Any) -> int | None:
    try:
        return int(v)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def _size(p: str) -> int | None:
    try:
        return os.path.getsize(p)
    except OSError:
        return None


def _mem_total_mb() -> int | None:
    try:
        for line in open("/proc/meminfo", encoding="utf-8"):
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) // 1024
    except OSError:
        pass
    return None


def _write_cgroup_evidence(d: str, res: RunResult) -> dict[str, str]:
    """把 cgroup 的证词抄进运行目录。

    为什么必须抄：cgroup 是**用完就删**的，而 `metrics` 要能追到具体文件、审计要能
    事后复核。实测只把 `/sys/fs/cgroup/.../memory.events` 的路径写进快照是不够的——
    那一行在清理之后指向一个不存在的文件（这正是「四份快照齐全、来源可追」那条回归
    抓出来的：它不接受指向空气的来源）。
    """
    ev: dict[str, str] = {}
    src = res.cgroup.get("path") or ""
    if not src or not os.path.isdir(src):
        return ev
    cgdir = os.path.join(d, "cgroup")
    os.makedirs(cgdir, exist_ok=True)
    for leaf in ("memory.events", "memory.peak", "memory.max", "memory.swap.max",
                 "pids.max", "cpu.stat"):
        txt = _read(src, leaf)
        if txt is None:
            continue
        path = os.path.join(cgdir, leaf)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(txt + "\n")
        ev[leaf] = path
    return ev


def write_snapshots(spec: RunSpec, res: RunResult, *,
                    deep_capabilities: bool = False) -> dict[str, str]:
    """四份快照落盘，返回 {名字: 路径}。

    cgroup 的证词先抄进运行目录（见 `_write_cgroup_evidence`），这样 `metrics.sources`
    指向的路径在清理之后依然存在——审计记录必须活过被审计的对象。
    """
    d = spec.runner_dir or spec.workdir
    os.makedirs(d, exist_ok=True)
    res.cgroup["evidence"] = _write_cgroup_evidence(d, res)
    payload = {
        "cmd": cmd_snapshot(spec, res),
        "env": env_snapshot(spec),
        "capabilities": capabilities_snapshot(deep=deep_capabilities),
        "metrics": metrics_snapshot(spec, res),
    }
    written: dict[str, str] = {}
    for name, obj in payload.items():
        path = os.path.join(d, f"{name}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        written[name] = path
    return written

== 本地工具链供给、沙箱与资源控制

本节的所有硬数据来自 2026-09-14 在本机执行的*只读*探测：`nproc`、`lscpu`、`free -h`、`df -h`、`ulimit -a`、`docker info`、`pacman -Si`、`pacman -Sp`、`bwrap` 试运行、`systemd-run --user --scope` 试运行，以及 `pypi.org/pypi/<pkg>/json`。
凡标「推断」的条目均为本节作者的推理，不是实测值；无法核实者标 `UNVERIFIED`。

=== 实测基线（一手）

#table(columns: 2,
  [探测项], [实测结果],
  [`/etc/os-release`], [Arch Linux，rolling，`ID=arch`；包管理器 `pacman` + `yay`（AUR）。*没有* `apt`/`dpkg`/`dnf`/`nix`],
  [内核], [`Linux 7.1.8-arch1-3`，cgroup v2 统一层级],
  [CPU], [AMD Ryzen 5 9600X，6 核 12 线程，`nproc` = 12],
  [内存], [30 GiB RAM + 8 GiB swap；`free` 显示 available 21 GiB],
  [磁盘], [`/` 为 ext4，286 G，已用 127 G，可用 145 G。`/tmp` 是 *tmpfs*，上限 16 G（写入 `/tmp` 等于占用 RAM）],
  [cgroup 控制器], [可用：`cpuset cpu io memory hugetlb pids rdma misc dmem`；用户 slice 的 `memory.max` 当前为 `max`（无上限）],
  [`ulimit -a`], [`cpu time`/`file size`/`data seg`/`virtual memory`/`max memory` 全部 `unlimited`；`open files` 524288；`stack` 8192 KiB],
  [Docker], [`29.7.2`，daemon 在运行，storage driver `overlayfs`，cgroup v2，默认 `seccomp=builtin`；当前 uid 1000 属于 `docker` 组],
  [bubblewrap], [`/usr/bin/bwrap` 0.11.2（包 `extra/bubblewrap` 已装）；`bwrap --ro-bind / / --unshare-net --die-with-parent` 试运行成功],
  [用户命名空间], [`unprivileged_userns_clone=1`，`user.max_user_namespaces=124077`],
  [systemd], [`261.2`，用户实例 `running`；`systemd-run --user --scope -p MemoryMax=64M -p CPUQuota=50%` 试运行成功],
  [Python], [`3.14.6`（`/usr/bin/python3`）。*`pip` 不存在*：`python3 -m pip --version` 报 `No module named pip`。存在 `/usr/lib/python3.14/EXTERNALLY-MANAGED`（PEP 668）。`uv 0.12.3` 已安装],
  [Python 已装科学栈], [仅 `numpy 2.5.2`、`matplotlib 3.11.1`。`scipy`/`sympy`/`mpmath`/`z3`/`networkx`/`pandas`/`numba`/`sympy` 全部缺失],
  [Julia], [`1.12.6`，depot `~/.julia` 628 MB，装有 `JuMP`、`HiGHS`；*没有* `Z3.jl`/`Nemo`/`Hecke`],
  [Lean], [elan 两个 toolchain：`v4.32.2`、`v4.33.0-rc1`，各约 2.8 GB],
  [其它], [`typst 0.15.1`、`node v26.7.0`、`gcc`/`make`/`cmake` 存在；`clang`、`cargo`/`rustc`、`nix`、GNU `parallel` 缺失],
)

要强调的一点：本机 `ulimit` 的 CPU 时间与虚拟内存都是 `unlimited`，而 `/tmp` 是 16 GiB 的 tmpfs。
这两条合起来意味着——一个跑飞了的 LLM 生成循环*不会被任何现成机制拦住*，而且只要往 `/tmp` 写大中间结果，就会直接吃掉 30 GiB 里的 16 GiB。
这是本插件必须自建资源控制、而不能指望系统默认值的原因。

=== 缺失工具的最小安装路径与体积代价

本机缺失的求解器/代数系统，其官方源与 wheel 实测体积如下。体积均为*实测下载量*（`pacman -Si` 的 `Download Size` 或 PyPI wheel 字节数），安装后占用更大。

#table(columns: 4,
  [工具], [路径 A：Arch 官方源 `pacman -S`], [路径 B：Python wheel（`uv pip install`）], [备注],
  [`z3`], [`extra/z3 4.16.0-1`，下载 9.58 MiB，安装 37.90 MiB], [`z3-solver 5.1.0.0`，`py3-none-manylinux_2_27_x86_64` 31.6 MiB], [两条路径版本不一致（4.16 vs 5.1），且官方源只给 CLI/C++，Python 绑定走 PyPI],
  [`cvc5`], [*不在官方源*（`pacman -Ss '^cvc5$'` 无结果）], [`cvc5 1.3.4` 有 `cp314` manylinux wheel，13.1 MiB], [wheel 已内置 `libcvc5`，不需要系统库；为一手实测],
  [`sage`], [`extra/sagemath 10.9-6`：`pacman -Sp` 解析出 *112 个包、460.2 MiB* 下载量], [conda-forge 包名为 `sagelib 10.9`，linux-64 py314 版本 `.conda` 文件 68.2 MB，传递依赖未计], [官方源 112 包含 `gap` 229.0 MiB、`sagemath` 56.4、`maxima` 23.6、`python-scipy` 22.4、`python-pandas` 15.5、`python-sympy` 13.9、`singular` 11.4、`pari` 8.8],
  [`gap`], [`extra/gap 4.16.1-1`，下载 229.0 MiB，安装 385.0 MiB], [无 wheel], [单独装也是 229 MiB 量级],
  [`pari/gp`], [`extra/pari 2.17.4-1`，下载 8.79 MiB，安装 28.69 MiB], [无 wheel], [`gp` 可执行文件随该包提供（具体文件清单 `UNVERIFIED`）],
  [`flint`], [`extra/flint 3.6.0-1`，下载 6.86 MiB，安装 19.81 MiB], [`python-flint 0.9.0`，`cp310-abi3` manylinux wheel 9.7 MiB], [abi3 wheel 向前兼容，`requires_python >=3.10`，本机 3.14 可用],
  [`sympy`], [`extra/python-sympy 1.14.0-6`，下载 13.90 MiB，安装 101.50 MiB], [`sympy 1.14.0`，`py3-none-any` wheel 6.0 MiB], [纯 Python，wheel 路线体积小得多],
  [`scipy`], [`extra/python-scipy 1.18.1-1`，下载 22.38 MiB，安装 118.60 MiB], [`scipy 1.18.1`，`cp314` manylinux wheel 33.7 MiB], [有 cp314 wheel，本机版本匹配],
  [`mpmath`], [`extra/python-mpmath 1.4.1-1`，下载 1.12 MiB，安装 7.26 MiB], [纯 Python，`UNVERIFIED` wheel 体积], [任意精度浮点，sympy 依赖它],
)

Nix 路线（`nix` 本机未安装）：Nix 需先通过官方安装脚本引入多用户 store，这本身是一次需要 root 的系统级改动。
对本插件而言，把 Nix 作为*可选*后端而非默认路径更稳妥；`UNVERIFIED`：Nix 上 sage 闭包的具体体积未实测。

*关于「`pip install z3-solver`」这条最常见的建议*：在本机它*会直接失败*，因为 `pip` 根本没装（`No module named pip`），而且 `EXTERNALLY-MANAGED` 标记会阻止系统级安装。
插件的提示语必须换成两条真实可行的命令之一：`pacman -S <pkg>`（走包管理器，需用户授权 root）或 `uv venv && uv pip install <pkg>`（用户空间，无需 root）。
uv 的文档明确说明 uv 默认*要求*虚拟环境，`uv pip install` 不会污染系统 Python。#link("https://docs.astral.sh/uv/pip/environments/")[来源：uv 文档 Using environments]

=== 能力探测-降级-提示（capability probe 模式）

核心原则：`/home/ebt/.kimi-code/plugins/managed/` 下的已有插件与 SKILL.md 都是*声明式*的，运行时环境千差万别。
本插件不应在 SKILL.md 里写死「需要 z3」，而应在每次运行开始时产出一份能力快照，再据此选择算法分支。

三个层次的探测，成本递增，只在必要时做：

- *可执行文件*：`shutil.which(name)`，返回路径或 `None`。这是最便宜的一层。#link("https://docs.python.org/3/library/shutil.html#shutil.which")[来源：Python 文档 shutil.which]
- *可导入模块*：`importlib.util.find_spec(name)` 判存在，`importlib.metadata.version(name)` 取版本。注意 `find_spec` 会执行父包 `__init__`，对重型包（sage 相关）要加超时。
- *版本号*：跑 `<tool> --version`，*必须带超时*。本机 `lean --version` 实测会先尝试联网更新 elan 并下载新 toolchain——无超时的版本探测在网络受限时会把插件卡死。

探测结果必须缓存，缓存的键是 `(path, size, mtime)` 三元组而不是工具名；工具升级后 mtime 变化自然使缓存失效。缓存落在插件状态目录，不写系统目录。

降级阶梯（每个能力都要有，且降级必须是*可见*的）：

#table(columns: 3,
  [能力], [存在时], [缺失时的降级与提示],
  [SMT 求解], [调 `z3`/`cvc5` 二进制或 Python 绑定], [退回纯 Python 的穷举/DPLL 搜索，并在结果 JSON 里写 `"solver": "bruteforce"`，在摘要里显式声明「未使用 SMT，搜索空间受限」],
  [精确线性代数/数论], [`python-flint` 或 `sympy`], [退回 `int` + `fractions.Fraction` 的朴素实现；提示 `uv pip install python-flint`（仅 9.7 MiB）],
  [计算机代数系统], [已装 `sagemath`/`gap`/`pari`], [不自动安装（460 MiB 量级）；直接把该问题类型标为「本机不可解」，并给出 `pacman -S sagemath` 的体积警告],
  [形式化证明], [`lean` + 对应 toolchain + 已获取的 mathlib 缓存], [`lake exe cache get` 需要联网拉数 GB 的 olean；离线时仅能做不依赖 mathlib 的纯 Lean 内核验证],
)

探测代码骨架（本节作者的实现建议，非引用）：

```python
import importlib.util, importlib.metadata, shutil, subprocess

def probe_exe(name, args=("--version",), timeout=5):
    path = shutil.which(name)
    if not path:
        return {"present": False}
    try:
        r = subprocess.run([path, *args], capture_output=True,
                           text=True, timeout=timeout, env={"PATH": "/usr/bin:/bin"})
        ver = (r.stdout or r.stderr).strip().splitlines()[0][:120]
    except Exception as exc:
        ver = f"probe-failed:{type(exc).__name__}"
    return {"present": True, "path": path, "version": ver}

def probe_module(name):
    if importlib.util.find_spec(name) is None:
        return {"present": False}
    try:
        ver = importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        ver = None
    return {"present": True, "version": ver}
```

*推断*：上面对 `probe_exe` 用最小 `env` 是被动防护——避免 `--version` 触发工具自身的联网自更新逻辑（本机 `lean --version` 就发生过），也让探测结果不受用户 shell 配置影响。

提示文案要「可执行」而不是「可读」：每条缺失能力应同时给出*确切的安装命令*、*下载体积*、*是否需要 root*，并明确告知用户插件不会自动执行它。

=== 隔离执行 LLM 生成代码

按「零依赖 → 现成内核机制 → 容器」分三层，逐层可用性都已在本题机器上核实。

*Tier 0：`subprocess` + `resource.setrlimit`（零依赖，始终可用）。*
`resource` 模块在本机 Python 3.14.6 上可用，`RLIMIT_AS`/`RLIMIT_CPU` 常量存在，`setrlimit` 可调用。#link("https://docs.python.org/3/library/resource.html")[来源：Python 文档 resource]

```python
import os, resource, subprocess

def limits(cpu_s, as_mb, fsize_mb, nproc_cap):
    def _apply():
        resource.setrlimit(resource.RLIMIT_CPU, (cpu_s, cpu_s + 5))
        resource.setrlimit(resource.RLIMIT_AS, (as_mb << 20, as_mb << 20))
        resource.setrlimit(resource.RLIMIT_FSIZE, (fsize_mb << 20, fsize_mb << 20))
        resource.setrlimit(resource.RLIMIT_NPROC, (nproc_cap, nproc_cap))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.setsid()          # 让整个进程组可被一次性杀掉
    return _apply
```

要点与陷阱：

- `RLIMIT_CPU` 超限发 `SIGXCPU`（默认可杀死进程），这是*CPU 时间*而非墙钟时间。#link("https://docs.python.org/3/library/resource.html")[来源：Python 文档]
- `RLIMIT_AS` 限制的是*地址空间*，不是 RSS。NumPy/BLAS 会预留大块虚拟地址，设得太小会让正常任务假性 OOM。
- `RLIMIT_NPROC` 是*按 UID* 计数的，不是按进程树。Docker 文档专门警告了这一点：多个容器共用一个 UID 时，`nproc` 配额会被彼此耗尽，出现 `resource temporarily unavailable`。#link("https://docs.docker.com/reference/cli/docker/container/run/")[来源：Docker run 参考]
- `preexec_fn` 在多线程父进程里不安全（CPython 文档已标注）。若插件自身是多线程的，改用 `systemd-run` 或 `prlimit` 包装，而不要用 `preexec_fn`。

*Tier 1：bubblewrap（本机已装，零额外安装成本）。*
实测可用：`bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --die-with-parent /bin/echo`。
`--die-with-parent` 保证父进程死亡时沙箱一起死，正好补上 rlimit 管不到的生命周期问题。
`UNVERIFIED`：bubblewrap 0.11.2 对 CPU/内存配额的支持（`--rlimit-*` 系列在较新版本才有），本条未实测，不要写进插件前提。

*Tier 2：Docker（本机可用，但需注意三处限制）。*
本机 `seccomp=builtin`、cgroup v2，`docker run --network=none --memory=64m --cpus=0.5 --pids-limit=32` 实测可跑通。推荐基线：

```bash
docker run --rm --network=none \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --memory=2g --memory-swap=2g --cpus=2 --pids-limit=256 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --user 65534:65534 -v "$RUN_DIR:/work:rw" -w /work \
  <image>@sha256:<digest> python3 /work/main.py
```

- `--memory` 的最小值是 6m，`--memory-swap` 与 `--memory` 相等时容器完全禁用 swap——这才是确定性的内存上限。#link("https://docs.docker.com/engine/containers/resource_constraints/")[来源：Docker 资源约束]
- `--security-opt=no-new-privileges` 会让 seccomp 过滤器在降权*之后*应用，等价于更严格的过滤集。Docker 默认 seccomp profile 已经屏蔽了 `ptrace`、`mount`、`clone`、`io_uring_*`、`unshare`、`keyctl` 等。#link("https://docs.docker.com/engine/security/seccomp/")[来源：Docker seccomp profiles]
- *不要*用 `--storage-opt size=` 限制容器可写层：Docker 文档说明该选项只对 btrfs/overlay2/windowsfilter/zfs 有效，且 overlay2 要求*后端文件系统是 xfs 且以 `pquota` 挂载*。本机是 ext4 + overlayfs，因此该选项不可用（实测 `findmnt` 显示 `/` 为 ext4）。#link("https://docs.docker.com/reference/cli/docker/container/run/")[来源：Docker run 参考]
- 安全提醒（*推断*）：本机 uid 1000 在 `docker` 组内，等价于无口令 root。把「运行 LLM 代码」的沙箱建立在 Docker 上，意味着沙箱逃逸的影响面是整机。这是应该向用户明示的风险，不是实现细节。

*Tier 3：nsjail / firejail（本机均未安装）。*
两者都在 Arch 官方源：`extra/nsjail 3.6-7`（下载 191.93 KiB，安装 765.58 KiB）、`extra/firejail 0.9.80-1`（下载 609.21 KiB，安装 2545.67 KiB）。
nsjail 一次调用即可同时给出命名空间隔离、rlimit、seccomp（Kafel 策略）与 cgroup 配额，包括 `--time_limit`、`--rlimit_as`、`--cgroup_mem_max`、`--cgroup_pids_max`，
其 README 明确列出「namespaces、cgroups、rlimits、seccomp-bpf」四类机制。#link("https://github.com/google/nsjail")[来源：nsjail README]
firejail 是 *SUID root* 程序，README 自述为「SUID sandbox program」，攻击面更大。#link("https://github.com/netblue30/firejail")[来源：firejail README]
*推断*：若本插件只允许建议安装一个工具，nsjail 的体积小一个数量级且不引入 SUID，优先级高于 firejail；但两者都不应成为*硬依赖*，因为它们在本机当前都不存在。

=== 超时、内存、CPU 限制与结果可复现

必须区分三种「超时」，它们的可复现性完全不同：

- *墙钟超时*：`timeout(1)`、`subprocess.run(timeout=...)`、systemd 的 `RuntimeMaxSec=`。受机器负载、CPU 配额、缓存状态影响，*不可复现*，只应作为防跑飞的兜底。
- *CPU 时间超时*：`RLIMIT_CPU`；systemd 侧看 `CPUQuota=`（相对单核的百分比，可用大于 100% 的值跨核）。这是与负载弱相关的量，适合做算法层预算。
- *阶段预算*：把总预算拆到「编码 / 求解 / 验证」各阶段，任一阶段超限即整体判失败并落盘证据。

systemd 用户实例可用（实测 `--scope` 成功），因此无需 root 就能拿到 cgroup 级限制：

```bash
systemd-run --user --scope --collect --unit="job-$ID" \
  -p MemoryHigh=1G -p MemoryMax=2G -p MemorySwapMax=0 \
  -p CPUQuota=200% -p TasksMax=64 -p IOWeight=50 \
  --wait -- /usr/bin/python3 task.py
```

- systemd 文档明确建议：把 `MemoryHigh=` 作为主要控制手段，`MemoryMax=` 只作最后防线；`MemoryMax=` 触发的是单元内部的 OOM killer。内存值支持 `K/M/G/T` 后缀，也支持相对物理内存的百分比；对应的 cgroup 属性是 `memory.max`。#link("https://man.archlinux.org/man/systemd.resource-control.5.en")[来源：systemd.resource-control(5)]
- `RuntimeMaxSec=` 定义服务的最大运行时长（墙钟），与 `TimeoutStartSec=` 是两回事。#link("https://man.archlinux.org/man/systemd.service.5.en")[来源：systemd.service(5)]
- `--unit="job-$ID"` 的价值在于*可寻址*：任务卡死时可用 `systemctl --user kill "job-$ID"` 一次性终结整棵树，而不是靠 `ps` 猜 PID。
- *推断*：`MemorySwapMax=0` 对本机尤其重要——本机有 8 GiB swap，若不禁用，内存超限的任务会先被换出、把墙钟时间拖长数倍，让基准数据完全失真。

结果可复现的最低要求（每条都对应一个真实的不可复现来源）：

- *固定 RNG*：NumPy 的 NEP 19 明确说明，`Generator` 的分布方法*不保证*跨版本位级一致，只有 `RandomState` 被承诺严格流兼容，并且官方立场是「需要位级复现就应当固定整个软件栈的版本」。#link("https://numpy.org/neps/nep-0019-rng-policy.html")[来源：NEP 19]
  因此：显式创建带种子的生成器对象并传递，不要用 `numpy.random.*` 全局函数；同时把 numpy 版本写进产物。
- *固定工具链版本*：Lean 侧用 `lean-toolchain` 文件 pin；本机 elan 同时存在 `v4.32.2` 与 `v4.33.0-rc1`，不 pin 就不确定用的是哪个。Docker 侧用 `@sha256:` 摘要而非 `:latest`。
- *固定线程数*：BLAS/OpenMP 线程数会改变浮点求和顺序。基准测试时把 `OMP_NUM_THREADS`、`OPENBLAS_NUM_THREADS`、`JULIA_NUM_THREADS` 显式设为 1，并记录 `nproc`。
- *固定时间戳约定*：产物里的时间戳统一用 `SOURCE_DATE_EPOCH` 约定（仓库末尾提交时间 `git log -1 --pretty=%ct`），使两次相同输入的产物可比对。#link("https://reproducible-builds.org/docs/source-date-epoch/")[来源：reproducible-builds.org]
- *记录环境快照*：把 `capabilities.json`、`env.json`（含 Python/numpy/求解器版本、`nproc`、CPU 型号、`CPUQuota`）、完整命令行一起落盘。没有这份快照，任何「反例」都无法复核。

=== 并发与队列

本机 12 个逻辑 CPU、30 GiB RAM、8 GiB swap，且 `ulimit` 默认无限制。
并发度的上限应由两条约束同时决定，取小值：
`N = min(nproc - 2, floor(可用内存 / 单任务峰值 RSS))`，并额外预留 ~2 GiB 给系统和编辑器。

可用的现成原语（实测存在）：`xargs -P`、`flock`、`nice`、`ionice`、`taskset`、`numactl`、`timeout`、`make -j`。
GNU `parallel` *未安装*，不要写进任何脚本前提。

- *队列*：用 `flock` 保护的目录作为任务队列（取「待跑」文件、原子改名到「运行中」），无需额外依赖，崩溃后可恢复。
- *并发执行*：每个任务一个 `systemd-run --user --scope --unit=` 单元，天然获得 *按任务* 的 killswitch、内存/CPU 配额与日志归属。
- *不做的事*：不要在一个 Python 进程里用线程跑 CPU 密集型求解器——GIL 会让它退化成串行，而内存限制又无法按线程隔离。
- *孤儿回收*：`--units` 模式下若插件进程被杀，`systemd-run` 的单元仍在。启动时先 `systemctl --user list-units 'job-*'` 清理上一轮残留。
- *长任务的分层预算*：给每类任务设 `wall_s` 与其 3~5 倍的 `cpu_s`（同机压测时墙钟会因争抢而膨胀），并让队列在*累计*预算耗尽时停止取新任务，而不是让每个任务各自撞墙。

=== 日志、产物目录与磁盘配额

*本机无法使用文件系统级配额*：`repquota`/`xfs_quota` 未安装，`tune2fs -l /dev/nvme0n1p3` 以普通用户运行返回 `Permission denied`（实测）。
Docker 的 `--storage-opt size=` 也不可用（overlay2 落在 ext4 上，见上）。
结论：*磁盘配额只能由插件自己在应用层做*——预检剩余空间、按目录累计字节数、超预算时拒绝启动新任务。

建议的产物布局（每个 run 一个不可变目录，`run_id` 取输入内容哈希）：

```text
.kimi-runs/<run_id>/
  cmd.json          # argv、cwd、环境变量增量子集
  capabilities.json # 探测快照（工具、路径、版本、present/absent）
  env.json          # python/numpy/solver 版本、nproc、CPU 型号、CPUQuota
  stdout.log  stderr.log
  metrics.json      # 墙钟、CPU 时间（getrusage）、峰值 RSS、退出码/信号
  artifacts/        # 生成的代码、反例、证明脚本
```

- *指标来源*：`resource.getrusage` 的 `ru_utime`/`ru_stime`/`ru_maxrss` 是 CPython 直接提供的，零依赖；`RUSAGE_CHILDREN` 可拿到子进程消耗。#link("https://docs.python.org/3/library/resource.html")[来源：Python 文档 resource]
- *日志上限*：给每个任务设 `RLIMIT_FSIZE`（本建议 64 MiB）并把 stdout 截断处写入显式标记（如 `<<TRUNCATED at 64MiB>>`），否则一个 `print` 死循环会写满 145 GiB 可用空间。
- *日志归属*：走 `systemd-run` 的任务日志自动进用户 journal，可直接 `journalctl --user -u "job-$ID" -o json` 取结构化记录，不必自建日志框架。
- *轮转*：run 目录按时间做容量预算（例如保留最近 20 GiB），超出时先压缩再删除最旧的 `stdout.log`，绝不删除 `cmd.json`/`capabilities.json`/`metrics.json`——这三个是复现的最小充分集。
- *`/tmp` 陷阱*：本机 `/tmp` 是 16 GiB tmpfs。中间结果一律写到 `$RUN_DIR`（ext4 上），并在传给沙箱的参数里把临时目录显式指过去；不要依赖 `TMPDIR` 的默认值（*推断*：Docker 容器内 `TMPDIR` 与宿主不一致，容易误判）。

=== 评估

- *该抄*：把「探测-降级-提示」做成运行时产物 `capabilities.json`，并且把探测的版本号命令强制加超时——本机 `lean --version` 会触发 elan 联网自更新，不加超时就会卡死插件。
- *该抄*：默认执行路径用 `systemd-run --user --scope`（本机实测可用、无需 root）而不是裸 `subprocess`，因为它一次给到 `MemoryHigh=`/`MemoryMax=`/`MemorySwapMax=0`/`CPUQuota=`/`TasksMax=` 与可寻址的 killswitch；`RLIMIT_AS` 只作补充，因为内存压不住时它既不精确又会误伤 BLAS 的地址预留。
- *该避免*：任何形如 `pip install <x>` 的提示。本机没有 `pip`（`No module named pip`）且有 `EXTERNALLY-MANAGED`，提示必须二选一：`pacman -S <pkg>` 或 `uv venv && uv pip install <pkg>`（uv 0.12.3 已装，默认要求 venv）。
- *该避免*：把 `sage`/`gap` 当成可随手补上的依赖。实测 `pacman -Sp sagemath` 要拉 112 个包共 460.2 MiB（其中 `gap` 单项 229.0 MiB），且 `sagemath` 自身安装后 371 MiB。应把整类 CAS 能力标为「可选重依赖」，仅在探测到已安装时启用，否则明确宣告不可解。
- *该避免*：依赖 Docker 的 `--storage-opt size=` 或宿主 ext4 的 `quota` 做磁盘限额——本机两条路都走不通（overlay2 需 xfs+pquota；`tune2fs` 普通用户无权限）。磁盘预算必须在应用层按目录累计字节数自行实现，并对每个任务设 `RLIMIT_FSIZE` 兜底。
- *该抄*：让每次运行落一份不可变快照（`cmd.json` + `capabilities.json` + `env.json` + `metrics.json`），因为 NumPy 的 NEP 19 已明确放弃跨版本位级流兼容——不固定版本，反例搜索结果就无法复核。

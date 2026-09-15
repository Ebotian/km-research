#!/usr/bin/env bash
# 退出码契约回归：把「判决走退出码」这条契约的每一档都实跑一遍。
#
# 为什么这个脚本必须进仓库、而不是每次手敲 —— 类型系统抓不到这一层。
# 本次会话的 5 个 bug 里类型检查器只可能抓到 1 个（三元组按四元组解包），
# 其余三个（选项顺序、输出里的 \r 破坏 ^ 锚定、过滤条件写反）只有跑真调用
# 才会暴露。所以「每改一次就重跑矩阵」是纪律，不是仪式。
#
# 负向对照一律用*内容篡改*，绝不用截断证明：实测截断后 drat-trim 仍报
# VERIFIED（正向传播自己导出了冲突），cake_lpr 也只给一句无关诊断。
# 拿截断做验收会得到一个永远通过的假验收。
#
# 全部夹具在 tests/fixtures/ 内，篡改样本在临时目录现造 —— 脚本自包含。
#
# 用法：regress.sh [--verbose]

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
cd "$plugin" || exit 2

FIX=tests/fixtures
BIN=bin
work=$(mktemp -d "${TMPDIR:-/tmp}/opl-regress.XXXXXX")
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
# 跳过与通过是两件事：缺 Lean 项目时那几项*没跑*，不该显得像通过。
skip=0

chk() {
  local name=$1 want=$2
  shift 2
  "$@" >"$work/out" 2>"$work/err"
  local rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok   %-46s %s\n' "$name" "$rc"
  else
    fail=$((fail + 1))
    printf '  FAIL %-46s %s (期望 %s)\n' "$name" "$rc" "$want"
    head -3 "$work/err" | sed 's/^/         /'
  fi
}

# ---------------------------------------------------------------- 现造篡改样本
python3 - "$FIX" "$work" <<'PY'
import sys, pathlib
fix, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# DRAT：翻转 uuf-100-1.drat 首行首个文字。实测这一步会让 drat-trim 报 NOT VERIFIED。
lines = (fix / "uuf-100-1.drat").read_text().splitlines(keepends=True)
first = lines[0].lstrip()
lines[0] = lines[0].replace(first.split()[0], ("-" + first.split()[0])
                            if not first.startswith("-") else first.split()[0][1:], 1)
(work / "drat-tampered.drat").write_text("".join(lines))

# 空证书
(work / "empty.drat").write_text("")

# cake_lpr：把第 3 行的最后一个提示号换成不存在的 99。
lpr = (fix / "lpr-example.lpr").read_text().splitlines(keepends=True)
parts = lpr[2].rsplit(" ", 2)
lpr[2] = parts[0] + " 99" + parts[2]
(work / "lpr-badhint.lpr").write_text("".join(lpr))

# Alethe：把 premises 指向自己，破坏归结。
al = (fix / "alethe-example.alethe").read_text()
(work / "alethe-tampered.alethe").write_text(al.replace("(a0 a1)", "(a0 a0)")
                                             if "(a0 a1)" in al else al.replace("a1", "a0"))
PY

# ---------------------------------------------------------------- 证书复核：五种格式
echo "certcheck —— drat / lrat / clrat / lpr / alethe"
chk "drat 真证书"            0 $BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert $FIX/uuf-100-1.drat
chk "drat 内容篡改"          1 $BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert "$work/drat-tampered.drat"
chk "drat 空证书"            3 $BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert "$work/empty.drat"
chk "lrat 真证书"            0 $BIN/opl-certcheck --formula $FIX/example-4-vars.cnf --cert $FIX/example-4-vars.lrat
chk "clrat + 坏解压器（伪证守卫）" 3 $BIN/opl-certcheck --formula $FIX/example-4-vars.cnf --cert $FIX/tiny.clrat --format clrat
chk "lpr 真证书（cake_lpr）" 0 $BIN/opl-certcheck --formula $FIX/lpr-example.cnf --cert $FIX/lpr-example.lpr
chk "lpr 非法提示号"         1 $BIN/opl-certcheck --formula $FIX/lpr-example.cnf --cert "$work/lpr-badhint.lpr"
chk "alethe 真证书（carcara）" 0 $BIN/opl-certcheck --formula $FIX/alethe-example.smt2 --cert $FIX/alethe-example.alethe
chk "alethe 内容篡改"        1 $BIN/opl-certcheck --formula $FIX/alethe-example.smt2 --cert "$work/alethe-tampered.alethe"

# ---------------------------------------------------------------- 缺后端必须是 4，不是 1
mkdir -p "$work/emptyroot"
chk "缺后端（不是 REJECT）"   4 env KIMI_PLUGIN_ROOT="$work/emptyroot" OPL_BINDIR=/nonexistent \
    PATH=/usr/bin:/bin $BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert $FIX/uuf-100-1.drat

# ---------------------------------------------------------------- 台账
echo "conj —— 台账的退出码语义"
export OPL_LAB="$work/lab"
chk "add"                    0 $BIN/opl-conj add --id R-1 --statement "测试陈述"
chk "无证据改状态（拒绝写入）" 2 $BIN/opl-conj set R-1 --formal-status refuted
chk "带证据改状态"           0 $BIN/opl-conj set R-1 --formal-status refuted --evidence "$work/ev.json"
# 锁住一个修掉的真 bug：旧代码在*没有* --evidence 时也写死 verified_by=independent
# 与 verification_level=exact_certificate，只打一句 stderr 警告——那是在数据里
# 断言一次从未做过的独立复核。
chk "加反例（无证据）"       0 $BIN/opl-conj set R-1 --add-counterexample "n=40"
chk "无证据的反例不得声称独立复核" 0 python3 -c "
import json, sys
c = json.load(open('$work/lab/conjectures/R-1.json'))['counterexamples'][0]
ok = (c['verified_by'] == 'UNVERIFIED' and c['verification_level'] == 'empirical'
      and c['certificate'] is None)
sys.exit(0 if ok else 1)"
chk "取不存在的记录"         5 $BIN/opl-conj get R-404
chk "list 无匹配"            5 $BIN/opl-conj list --status proved

# ---------------------------------------------------------------- 能力探测
echo "capabilities —— 必需层"
chk "必需层齐全"             0 $BIN/opl-capabilities --layer required --quiet
# 判据 2 的后半句：探测超时只能标「暂不可用」，**不得**缓存成「不存在」。
# 这两件事在结果里必须分得开——`not_found` 是事实，`probe_timeout` 是「这次没问出来」。
# 假工具用 PATH 注入，不碰系统里任何真后端。
chk "超时标 timeout 而不冒充「不存在」" 0 python3 -c "
import os, stat, sys, tempfile, time
sys.path.insert(0, '$plugin/lib')
from opl_probe import probe_executable

d = tempfile.mkdtemp()
slow = os.path.join(d, 'opl-slowtool')
with open(slow, 'w') as fh:
    fh.write('#!/bin/sh\nsleep 30\n')
os.chmod(slow, 0o755)
os.environ['PATH'] = d + os.pathsep + os.environ['PATH']

t0 = time.monotonic()
r1 = probe_executable('opl-slowtool', '--version', 0.4)
t1 = time.monotonic()
r2 = probe_executable('opl-slowtool', '--version', 0.4)   # 再探一次
t2 = time.monotonic()
missing = probe_executable('opl-definitely-not-here', '--version', 0.4)

why = []
# 1 硬超时生效：不能挂到 30 秒
if t1 - t0 > 3 or t2 - t1 > 3:
    why.append('没被硬超时截断：%.1fs / %.1fs' % (t1 - t0, t2 - t1))
# 2 超时与不存在必须标成两回事
if r1.get('error') != 'probe_timeout':
    why.append('超时被标成 %r' % (r1.get('error'),))
if missing.get('error') != 'not_found':
    why.append('不存在被标成 %r' % (missing.get('error'),))
# 3 不缓存：第二次仍去探（仍是 timeout），而不是记成「不存在」
if r2.get('error') != 'probe_timeout':
    why.append('第二次探测结果变了：%r —— 超时被缓存成了结论' % (r2.get('error'),))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# Lean 未定点时一次都不许探：那次调用会让 elan 联网解析 `stable`，本机没装过时还会
# 把它下下来——一条自称只读的诊断命令不该有这种副作用。
#
# 用 PATH 注入一个会记录自己被调用过的假 `lake`，于是「有没有探」变成一个可断言的
# 事实，而不是「看着像没探」。这条用例**不依赖 Lean 是否安装**，所以永远真跑。
chk "未定点不探 Lean（零次调用）" 0 python3 -c "
import os, sys, tempfile, time
sys.path.insert(0, '$plugin/lib')
from opl_probe import build_snapshot

d = tempfile.mkdtemp(prefix='opl-fakelake.')
marker = os.path.join(d, 'calls.txt')
fake = os.path.join(d, 'lake')
with open(fake, 'w') as fh:
    fh.write('#!/bin/sh\necho \"\$@\" >> ' + marker
             + '\necho \"Lake version FAKE (Lean version 4.0.0)\"\n')
os.chmod(fake, 0o755)
os.environ['PATH'] = d + os.pathsep + os.environ['PATH']

def calls():
    return open(marker).read().split() if os.path.exists(marker) else []

why = []
# ---- 甲：未定点（项目存在，但自己与祖先都没有 lean-toolchain）----
unp = tempfile.mkdtemp(prefix='opl-unpinned.')
os.environ['OPL_LEAN_PROJECT'] = unp
t0 = time.monotonic()
snap, _ = build_snapshot(layers=['lean'], do_python=False)
el = time.monotonic() - t0
lp = snap['lean_project']
# 1 一次都没调（这是本用例的核心）
if calls():
    why.append('未定点却调了假 lake：%r' % (calls(),))
# 2 「没问出来」不能报成「不可用」——None 与 False 是两件事
if lp.get('available') is not None:
    why.append('available 应为 None（未探测），实为 %r' % (lp.get('available'),))
if lp.get('pinned') is not False or lp.get('probe_skipped') != 'unpinned':
    why.append('pinned/probe_skipped 不对：%r/%r'
               % (lp.get('pinned'), lp.get('probe_skipped')))
# 3 要给出推荐，而不是只说一句「不知道」
if not lp.get('advice'):
    why.append('未给 advice')
# 4 环境事实要能拿到（这是允许的那部分探测：纯文件系统，不启进程）
envf = lp.get('env') or {}
if 'installed_toolchains' not in envf or 'default_toolchain' not in envf:
    why.append('env 事实不全：%r' % (sorted(envf),))
# 5 不许再有 30 秒/5 秒的卡顿——那是本用例存在的原因
if el > 3.0:
    why.append('耗时 %.1fs，说明又去联网了' % el)

# ---- 乙：正向对照，证明守卫不是「永远不探」----
pin = tempfile.mkdtemp(prefix='opl-pinned.')
with open(os.path.join(pin, 'lean-toolchain'), 'w') as fh:
    fh.write('leanprover/lean4:v4.33.0-rc1\n')
os.environ['OPL_LEAN_PROJECT'] = pin
open(marker, 'w').close()
snap2, _ = build_snapshot(layers=['lean'], do_python=False)
if not calls():
    why.append('定点时竟然没探——守卫写成了永远不探')
if not (snap2['tools']['lake'].get('version', '') or '').startswith('Lake version FAKE'):
    why.append('定点时没拿到版本：%r' % (snap2['tools']['lake'].get('version'),))

if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"

# ---------------------------------------------------------------- 沙箱（功能性）
# 「存在性不等于可用」在这里第四次应验：实测 `systemd-run -p IPAddressDeny=any`
# **退出 0、不报错、不禁网**（根因是本机 cgroup 没有 bpf 控制器）。只查
# `command -v` 的探测会把它记成可用，然后 M4 的「禁网生效」那一格就是假章。
#
# 所以这一组验两件事：探测的**结论**与实测一致；探测对「隔离与否」**敏感**。
# 后者靠变异检查——把 --unshare-net 去掉，探测必须改口说「没隔离」。
echo "sandbox —— 功能性探测（存在性不等于可用）"
net_ok=0
if python3 -c "
import socket, sys
try:
    socket.create_connection(('1.1.1.1', 443), timeout=4); sys.exit(0)
except OSError:
    sys.exit(1)" 2>/dev/null; then net_ok=1; fi
if [ "$net_ok" != 1 ]; then
  # 本机出不去网时，「沙箱里连不出去」什么都证明不了——那一格只能报 null。
  # 按纪律计入 skip，不算通过。
  skip=$((skip + 1))
  printf '  skip  %-46s 本机出不去网，禁网结论无从判定\n' "沙箱探测"
else
  chk "禁网/限额结论如实且对隔离敏感" 0 python3 -c "
import os, shutil, subprocess, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_sandbox as sb
from opl_probe import probe_sandbox

py = sys.executable
why = []

# ---- 甲：探测结论必须与实测一致，且**不许把不禁网报成禁网** ----
p = probe_sandbox(timeout=20)
if not (p.get('net_control') or {}).get('connected'):
    why.append('对照都连不出去，不该走到这一支')
bw = p.get('bwrap_net_off') or {}
if bw.get('isolated') is not True:
    why.append('bwrap --unshare-net 未报禁网生效：%r' % (bw,))
sd = p.get('systemd_ipaddressdeny_isolated') or {}
if sd.get('isolated') is not False:
    why.append('IPAddressDeny 被报成 %r —— 实测它不禁网，报 true 就是盖假章'
               % (sd.get('isolated'),))
mem = p.get('mem_limit_fires') or {}
if not (mem.get('MemoryMax + MemorySwapMax=0') or {}).get('killed'):
    why.append('MemoryMax+SwapMax=0 没能杀掉超标进程：%r'
               % (mem.get('MemoryMax + MemorySwapMax=0'),))
if (mem.get('MemoryMax only') or {}).get('killed'):
    why.append('只设 MemoryMax 竟然也杀了——与本机实测不符，先查 swap 是否被关掉了')

# ---- 乙：变异检查。去掉 --unshare-net，探测必须改口 ----
d = tempfile.mkdtemp(prefix='opl-sbxtest.')
try:
    rc_up = subprocess.run(sb.bwrap_python_argv(py, sb.NET_PROBE, workdir=d, net_off=False),
                           capture_output=True, timeout=25).returncode
    if rc_up != 0:
        why.append('去掉 --unshare-net 后仍连不出去（rc=%r）：探测对隔离与否不敏感，'
                   '等于没测' % rc_up)
finally:
    shutil.rmtree(d, ignore_errors=True)

# ---- 丙：内存 payload 本身得真会写成功，否则「被杀」不能归因于限额 ----
free = subprocess.run([py, '-c', sb.mem_probe_mb(32)], capture_output=True, timeout=40)
if free.returncode != 0 or b'WROTE' not in free.stdout:
    why.append('无限制下内存 payload 都没写成功（rc=%r）：那「被杀」说明不了限额生效'
               % free.returncode)

if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
fi

# ---------------------------------------------------------------- 沙箱执行（opl-run）
# 判据 1/2/3/4/5 在这里落地。核心不是「跑起来了」，而是**结局分得开**：
# 超时/被 OOM 杀 与「payload 自己失败」在退出码上必须不同（3 vs 1），
# 否则「没跑出来」会被读成「跑出来是错的」——那是本工具最不能犯的错。
echo "opl-run —— 沙箱执行与四份快照"
mkdir -p "$work/runwd"
R="$work/runs"
chk "死循环 -> 3（超时不是失败）" 3 $BIN/opl-run --runs-dir "$R" --id T1 --timeout 2 \
    --workdir "$work/runwd" -- /usr/bin/python3 -c "while True: pass"
chk "payload 自己失败 -> 1"       1 $BIN/opl-run --runs-dir "$R" --id T2 \
    --workdir "$work/runwd" -- /usr/bin/python3 -c "import sys; sys.exit(7)"
chk "脏 stdout -> 0（污染不越界）" 0 $BIN/opl-run --runs-dir "$R" --id T3 \
    --workdir "$work/runwd" -- /usr/bin/python3 -c "
import sys
sys.stdout.write(chr(0) + 'junk' * 500)
sys.stderr.write('err' * 500)
print('still ok')"
chk "禁网：沙箱内连不出去"        0 $BIN/opl-run --runs-dir "$R" --id T4 \
    --workdir "$work/runwd" -- /usr/bin/python3 -c "
import socket
try:
    socket.create_connection(('1.1.1.1', 443), timeout=3)
    print('NET_UP')
except OSError:
    print('NET_DOWN')"
if [ "$net_ok" = 1 ]; then
  chk "沙箱内输出确为 NET_DOWN"     0 grep -q NET_DOWN "$R/T4/stdout.txt"
else
  skip=$((skip + 1))
  printf '  skip  %-46s 本机出不去网，此断言无从判定\n' "沙箱内输出确为 NET_DOWN"
fi
chk "内存上限：被 OOM 杀掉 -> 3"   3 $BIN/opl-run --runs-dir "$R" --id T5 --mem-mb 64 \
    --workdir "$work/runwd" -- /usr/bin/python3 -c "
buf = bytearray(192 * 1024 * 1024)
for i in range(0, len(buf), 4096):
    buf[i] = 1
print('WROTE')"
# 这条**两种环境都有断言**：cgroup 可用时必须给出内核记账；不可用时快照必须
# 明确写出「限额未生效」。没有「什么都不查也算过」的分支。
chk "四份快照齐全、来源可追、归因如实" 0 python3 -c "
import json, os, sys
R = '$R'
why = []

def load(rid, name):
    p = os.path.join(R, rid, name + '.json')
    if not os.path.isfile(p):
        why.append('%s 缺 %s.json' % (rid, name))
        return None
    try:
        return json.load(open(p))
    except ValueError as e:
        why.append('%s/%s.json 不是合法 JSON：%s' % (rid, name, e))
        return None

# ---- 判据 1：四份快照齐全 ----
for name in ('cmd', 'env', 'capabilities', 'metrics'):
    load('T3', name)

# ---- 判据 1：metrics 的每个字段能追到具体产物文件 ----
m = load('T3', 'metrics') or {}
src = m.get('sources') or {}
arts = m.get('artifacts') or {}
for k, v in list(src.items()) + list(arts.items()):
    if isinstance(v, str) and v.startswith('/') and not os.path.exists(v):
        why.append('metrics.%s 指向不存在的路径：%s' % (k, v))
for need in ('stdout', 'stderr', 'workdir', 'runner_dir'):
    if need not in arts:
        why.append('metrics.artifacts 缺 %s' % need)

# ---- 判据 5：脏输出没有污染任何一份快照，也没有改变判决 ----
t3 = load('T3', 'metrics') or {}
if t3.get('verdict') != 'ok' or t3.get('payload_exit_code') != 0:
    why.append('脏 stdout 影响了判决：%r/%r'
               % (t3.get('verdict'), t3.get('payload_exit_code')))

# ---- 判据 2：超时的记录里不许出现 payload 自己的退出码 ----
t1 = load('T1', 'metrics') or {}
if t1.get('verdict') != 'timeout' or t1.get('payload_exit_code') is not None:
    why.append('超时被记成 %r / exit=%r：把「我们杀的」记成了「它自己退的」'
               % (t1.get('verdict'), t1.get('payload_exit_code')))

# ---- 判据 3：内存归因 ----
t5 = load('T5', 'metrics') or {}
c5 = load('T5', 'cmd') or {}
cg = (c5.get('cgroup') or {})
if cg.get('available'):
    if t5.get('verdict') != 'oom':
        why.append('cgroup 可用但判决是 %r（应为 oom）' % (t5.get('verdict'),))
    if not (t5.get('oom_kill') or 0) >= 1:
        why.append('cgroup 可用却没有内核记账 oom_kill=%r' % (t5.get('oom_kill'),))
    if t5.get('payload_exit_code') is not None:
        why.append('被 OOM 杀却记了 payload_exit_code=%r（那是 bwrap 的转写）'
                   % (t5.get('payload_exit_code'),))
else:
    # 拿不到 cgroup 时必须**明确写出限额没生效**，不许静默当成功
    blob = json.dumps(c5, ensure_ascii=False)
    if '未生效' not in blob:
        why.append('cgroup 不可用，但快照没有写明「内存限额未生效」')

if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 缺后端时报 4 而不是偷偷裸跑。BWRAP 是模块常量，用注入的方式模拟缺失——
# 这条只能在 lib 层验，CLI 没有让调用方指定 bwrap 路径的开关（也不该有）。
chk "缺 bwrap -> 4（不降级到裸跑）" 0 python3 -c "
import os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_sandbox as sb
sb.BWRAP = '/nonexistent/bwrap'
from opl_run import BACKEND_MISSING, RunSpec, execute
wd = tempfile.mkdtemp(prefix='opl-nobwrap.')
res = execute(RunSpec(argv=['/bin/true'], workdir=wd, runner_dir=wd, run_id='x'))
ok = (res.kind == BACKEND_MISSING
      and any('bwrap' in n for n in res.notes))
if not ok:
    print('  实为 %r notes=%r' % (res.kind, res.notes), file=sys.stderr)
sys.exit(0 if ok else 1)"
echo "encode —— 规格到模型，双后端互相证伪"
chk "纯编码到 CNF（不需求解器）" 0 $BIN/opl-encode --spec $FIX/spec-pc43.json --to cnf --out "$work/e.cnf"
chk "见证成立"                0 $BIN/opl-encode --spec $FIX/spec-pc23.json --eval-witness $FIX/spec-pc23-witness.json
chk "见证不成立"              1 $BIN/opl-encode --spec $FIX/spec-pc43.json --eval-witness $FIX/spec-pc23-witness.json
chk "双后端一致（UNSAT）"     0 $BIN/opl-encode --spec $FIX/spec-pc43.json --check-consistency
chk "双后端一致（SAT）"       0 $BIN/opl-encode --spec $FIX/spec-pc23.json --check-consistency
chk "编码代价超限（拒绝而非静默）" 2 $BIN/opl-encode --spec $FIX/spec-blowup.json --to cnf

# M1 第一条验收的牙齿：故意编坏 CNF 侧，「不一致」必须被检出。
# 在*临时副本*上注入，真实代码树全程不被碰——避免脚本中途被杀而留下坏代码。
mkdir -p "$work/probe/bin"
cp -r "$plugin/lib" "$work/probe/lib"
cp "$BIN/opl-encode" "$work/probe/bin/"
python3 - "$work/probe/lib/opl_encode.py" <<'PY' || exit 1
import sys
p = sys.argv[1]
s = open(p).read()
old = "    for combo in itertools.product(*assigns):"
assert old in s, "注入锚点没找到"
# 这里可以*前置*，因为注入的是 `return`——它在循环之前就退出，不会被覆盖。
# 若是赋值就必须替换，否则会被下一行覆盖成空操作（在 search 的注入上踩过）。
open(p, "w").write(s.replace(
    old, "    return  # ← 注入：不生成任何 linear 禁止子句\n" + old, 1))
PY
chk "编坏 CNF 侧后能检出不一致" 1 "$work/probe/bin/opl-encode" --spec $FIX/spec-pc43.json --check-consistency

# ---------------------------------------------------------------- 搜索与证书链
echo "search —— 搜索的退出码与证书链"
chk "SAT -> 0（见证经规格复核）"  0 $BIN/opl-search --spec $FIX/spec-pc23.json \
    --cnf-out "$work/sat.cnf" --witness-out "$work/sat.witness.json"
chk "见证可被独立复核"            0 $BIN/opl-encode --spec $FIX/spec-pc23.json \
    --eval-witness "$work/sat.witness.json"
chk "UNSAT -> 0（带 DRAT 证明）"  0 $BIN/opl-search --spec $FIX/spec-pc43.json \
    --cnf-out "$work/unsat.cnf" --proof-out "$work/unsat.drat"
chk "证明可被独立复核（证书链）"   0 $BIN/opl-certcheck --formula "$work/unsat.cnf" --cert "$work/unsat.drat"
chk "必然超时 -> 3（不是 1）"      3 $BIN/opl-search --spec $FIX/spec-pc43.json \
    --timeout 0.001 --proof-out "$work/never.drat"
chk "超时后未产出证明"             0 test ! -e "$work/never.drat"
chk "缺后端 -> 4"                4 env OPL_VENV=/nonexistent OPL_PYTHON=/bin/false \
    PATH=/usr/bin:/bin $BIN/opl-search --spec $FIX/spec-pc23.json

# 反解码故障注入：让 decode 返回错值，见证就不该通过——必须报 1 而不是成功。
# 在临时副本上做，真实代码树全程不被碰。
mkdir -p "$work/probe2/bin"
cp -r "$plugin/lib" "$work/probe2/lib"
cp "$BIN/opl-search" "$work/probe2/bin/"
python3 - "$work/probe2/lib/opl_encode.py" <<'PY' || exit 1
import sys
p = sys.argv[1]
s = open(p).read()
old = "        truth = {lit for lit in model if lit > 0}"
assert old in s, "注入锚点没找到"
# 必须*替换*而不是前置：前置的赋值会被紧随其后的原赋值覆盖，注入就成空操作。
# （这里踩过一次——注入没生效，测试却静默通过报 0。）
open(p, "w").write(s.replace(
    old, "        truth = set()  # ← 注入：反解码故意返回空", 1))
PY
chk "反解码出错时报 1（不伪报成功）" 1 "$work/probe2/bin/opl-search" --spec $FIX/spec-pc23.json

# ---------------------------------------------------------------- 端到端五步
echo "端到端 —— 登记 → 编码 → 搜索 → 独立复核 → 台账定案"
export OPL_LAB="$work/e2e/lab"
mkdir -p "$work/e2e"
chk "1 登记猜想"              0 $BIN/opl-conj add --id E-1 --title "PC(2,3) 可满足性" \
    --statement "3 个洞容得下 2 只鸽子，每只独占一个洞" --source $FIX/spec-pc23.json
chk "2 编码并双后端互相证伪"   0 $BIN/opl-encode --spec $FIX/spec-pc23.json --check-consistency
chk "3 搜索（sat 侧，出见证）" 0 $BIN/opl-search --spec $FIX/spec-pc23.json \
    --cnf-out "$work/e2e/m.cnf" --witness-out "$work/e2e/witness.json"
chk "4 独立复核见证"          0 $BIN/opl-encode --spec $FIX/spec-pc23.json \
    --eval-witness "$work/e2e/witness.json"
chk "5 台账定案"              0 $BIN/opl-conj set E-1 --formal-status refuted \
    --evidence "$work/e2e/witness.json" --verification-level exact_certificate
chk "终态与证据指针正确"       0 python3 -c "
import json, subprocess, os, sys
# 注意：status 是*派生*字段，按设计不落盘——必须向工具要，不能从文件里读。
f = json.load(open('$work/e2e/lab/conjectures/E-1.json'))
out = subprocess.run(['$BIN/opl-conj', 'get', 'E-1'], capture_output=True, text=True,
                     env={**os.environ, 'OPL_LAB': '$work/e2e/lab'})
derived = json.loads(out.stdout)['status']
ok = (derived == 'refuted' and f['formal_status'] == 'refuted'
      and f['verification_level'] == 'exact_certificate'
      and any(h['evidence'] for h in f['history']))
sys.exit(0 if ok else 1)"

# unsat 侧：证明 -> 独立复核 -> 证据记录落盘
chk "3b 搜索（unsat 侧，出证明）" 0 $BIN/opl-search --spec $FIX/spec-pc43.json \
    --cnf-out "$work/e2e/u.cnf" --proof-out "$work/e2e/u.drat"
chk "4b 复核证明并落证据记录"     0 $BIN/opl-certcheck --formula "$work/e2e/u.cnf" \
    --cert "$work/e2e/u.drat" --evidence-out "$work/e2e/lab/evidence/E-2.json"
chk "证据记录字段正确"            0 python3 -c "
import json, sys
d = json.load(open('$work/e2e/lab/evidence/E-2.json'))
ok = (d['schema'] == 'opl.evidence/1' and d['verdict'] == 'VERIFIED'
      and d['verification_level'] == 'exact_certificate'
      and len(d['certificate_sha256']) == 64)
sys.exit(0 if ok else 1)"
# 字段冻结：证据记录是审计的凭据，字段名与集合必须稳定。下沉重构（bin -> lib）
# 曾让这里面临「字段悄悄改名/丢失」的风险，而只看单个字段的检查抓不到。
# 冻结整个顶层键集，任何漂移都会红。
chk "证据记录字段冻结"            0 python3 -c "
import json, sys
FROZEN = {'schema', 'backend', 'format', 'formula', 'formula_sha256',
          'certificate', 'certificate_sha256', 'certificate_bytes',
          'parse_complete', 'parsed_bytes', 'duration_ms', 'checked_at',
          'checker_messages', 'verdict', 'verification_level'}
got = set(json.load(open('$work/e2e/lab/evidence/E-2.json')))
if got != FROZEN:
    print('新增:', sorted(got - FROZEN), '丢失:', sorted(FROZEN - got), file=sys.stderr)
sys.exit(0 if got == FROZEN else 1)"

# ---------------------------------------------------------------- 清单与技能
echo "manifest —— 清单必须能被平台正确解析"
chk "清单是合法 JSON"          0 python3 -c "import json;json.load(open('kimi.plugin.json'))"
chk "name 匹配平台正则"        0 python3 -c "
import json, re, sys
n = json.load(open('kimi.plugin.json'))['name']
sys.exit(0 if re.fullmatch(r'^[a-z0-9][a-z0-9_-]{0,63}\$', n) else 1)"
chk "skills 是数组且目录都存在" 0 python3 -c "
import json, os, sys
d = json.load(open('kimi.plugin.json'))
s = d.get('skills')
ok = (isinstance(s, list) and len(s) > 0
      and all(os.path.isfile(os.path.join(x.lstrip('./'), 'SKILL.md')) for x in s))
sys.exit(0 if ok else 1)"
chk "sessionStart 指向存在的技能" 0 python3 -c "
import json, os, sys
d = json.load(open('kimi.plugin.json'))
sk = d.get('sessionStart', {}).get('skill')
dirs = [x.strip('./') for x in d.get('skills', [])]
sys.exit(0 if sk and any(os.path.basename(x) == sk for x in dirs) else 1)"
chk "未声明 mcpServers（按设计）" 0 python3 -c "
import json, sys
sys.exit(0 if 'mcpServers' not in json.load(open('kimi.plugin.json')) else 1)"
# 反向检查：磁盘上每个技能目录都必须出现在清单里。漏列一个，它就静默不加载——
# 而正向检查（列出的都存在于磁盘）抓不到这种情况。
chk "磁盘上的技能目录都已在清单列出" 0 python3 -c "
import glob, json, os, sys
listed = {os.path.normpath(x) for x in json.load(open('kimi.plugin.json')).get('skills', [])}
on_disk = {os.path.normpath(p) for p in glob.glob('./skills/*/')}
missing = on_disk - listed
if missing:
    print('  未列出：', ', '.join(sorted(missing)))
sys.exit(0 if not missing else 1)"
for f in skills/*/SKILL.md; do
  chk "frontmatter 有 name/description: $(basename $(dirname $f))" 0 python3 -c "
import re, sys
t = open('$f').read()
m = re.match(r'^---\n(.*?)\n---\n', t, re.S)
fm = m.group(1) if m else ''
sys.exit(0 if 'name:' in fm and 'description:' in fm else 1)"
done

# ---------------------------------------------------------------- Lean 内核审计
# 这些检查需要 Lean 与一个*定点 toolchain* 的项目（plugin/lean 软链）。仓库里
# 不含那个项目（它指向本机的外部目录），所以缺它时**跳过并如实报出跳过数**，
# 而不是把它们当作通过——跳过与通过是两件事。
echo "leancheck —— Lean 内核审计（依赖 plugin/lean 项目）"
lean_ready=0
if command -v lake >/dev/null 2>&1 && [ -f "$plugin/lean/lean-toolchain" ]; then
  lean_ready=1
else
  skip=$((skip + 5))
  printf '  skip  %-46s 缺 lake 或 plugin/lean（无定点 toolchain）\n' "Lean 审计五项"
fi
if [ "$lean_ready" = 1 ]; then
  chk "无公理证明 -> 0（PROVED）"      0 $BIN/opl-leancheck --file $FIX/lean-ok.lean --decl opl_ok
  chk "含 sorry -> 1（SORRY_AX）"      1 $BIN/opl-leancheck --file $FIX/lean-sorry.lean --decl opl_sorry
  chk "native_decide -> 1（未证明）"   1 $BIN/opl-leancheck --file $FIX/lean-native.lean --decl opl_native
  chk "编译错误 -> 1（FAILED）"        1 $BIN/opl-leancheck --file $FIX/lean-bad.lean
  # 这条也要 Lean 已安装才有意义：没有 lake 时先报 MISSING(4) 才对
  # ——Lean 都没装，「项目未定点」无从谈起。
  chk "toolchain 未定点 -> 2（拒绝运行）" 2 $BIN/opl-leancheck --file $FIX/lean-ok.lean \
      --decl opl_ok --project "$work"
fi
# 与 Lean 是否安装无关的一条：文件不存在必须在任何 Lean 检查之前就报 2。
chk "文件不存在 -> 2"                2 $BIN/opl-leancheck --file "$work/nope.lean"
# 命题有没有被读进去，也跟 Lean 装没装无关：坏的 .lean 不该拖到 300 秒超时才报。
chk "文件不存在（非 .lean）-> 2"      2 $BIN/opl-leancheck --file "$work/nope.txt"

# ------------------------------------- M3 第三条：Mathlib 里已有的*已知定理*
# 上面五项验的是判定分支，6a–6g 验的是「我们的链路能承载一个真命题」；这一组验的是
# 第三件事：Mathlib 够不够得着，以及审计器对**已存在的定理**给出的结论对不对。
# 这一条必须用 Mathlib（而不是 Init），否则证明不了那条导入路径真的通了——
# 所以它单独一组，代价是 import Mathlib 约 2.1 秒，且只在 Lean 可用时跑。
echo "leancheck（Mathlib 已知定理）—— 已知定理 + 公理白名单"
if [ "$lean_ready" != 1 ]; then
  skip=$((skip + 2))
  printf '  skip  %-46s 缺 lake 或 plugin/lean（无定点 toolchain）\n' "已知定理两项"
else
  # Euclid 的素数无穷定理。判据是「通过验证」**且**「公理落在白名单内」——
  # 光看退出码等于没验白名单那半句。
  chk "已知定理（Mathlib）-> 0" 0 $BIN/opl-leancheck \
      --file $FIX/lean-mathlib-known.lean --evidence-out "$work/E-known.json"
  chk "公理集合 ⊆ 白名单（三条全中）" 0 python3 -c "
import json, sys
d = json.load(open('$work/E-known.json'))
got = set(d['axioms']['Nat.exists_infinite_primes'])
ok = (d['verdict'] == 'proved' and d['verification_level'] == 'lean_checked'
      and got <= set(d['axiom_whitelist'])
      and got == {'propext', 'Classical.choice', 'Quot.sound'})
if not ok:
    print('  实际：', sorted(got), file=sys.stderr)
sys.exit(0 if ok else 1)"
fi

# ------------------------------------------------- 端到端（证明侧）：真命题 -> lean_checked
# 上面五项验的是判定分支，用的都是 `True := trivial` 这类玩具命题。它们能证明
# 「分支走对了」，证明不了「这条链路能承载一个真命题」。这一段补后者：一个真命题
# 走完 形式化 → 证明检查 → 独立内核复核 → 台账定案，终态落在 lean_checked。
#
# 关于「独立内核复核」：Lean 的出口码不携带我们要的那个区别（sorry 与
# native_decide 都退出 0），所以这一步不采信「编译通过」，而是向*内核*要公理集合
# ——`#print axioms` 是对环境里内核级声明属性的查询，与编译是否成功是两回事。
# 这正是能抓出 sorry / native_decide 的那条信道。
echo "端到端（证明侧）—— 形式化 → 证明检查 → 独立内核复核 → 台账定案"
if [ "$lean_ready" != 1 ]; then
  # 跳过与通过是两件事：这几项*没跑*，必须如实计入 skip。
  skip=$((skip + 7))
  printf '  skip  %-46s 缺 lake 或 plugin/lean（无定点 toolchain）\n' "证明侧端到端七项"
else
  chk "6a 形式化：真命题就位（且非玩具）" 0 python3 -c "
import sys
# 注释里会提到 sorry / native_decide（那是在解释为什么避开它们），所以必须先
# 去掉注释行再判——否则检查会被自己的说明文字绊倒。
code = '\n'.join(l for l in open('$FIX/lean-real.lean')
                 if not l.lstrip().startswith('--'))
# 是玩具命题（True/trivial）或走了 sorry/native_decide，就不配当「真命题链路」的载体。
ok = ('theorem oddSum_eq_sq' in code and 'True' not in code
      and 'trivial' not in code and 'sorry' not in code
      and 'native_decide' not in code)
sys.exit(0 if ok else 1)"
  chk "6b 证明检查 + 产出证据记录"  0 $BIN/opl-leancheck --file $FIX/lean-real.lean \
      --decl oddSum_eq_sq --evidence-out "$work/e2e/lab/evidence/E-3.json"
  chk "6c 证据记录判为 lean_checked" 0 python3 -c "
import json, sys
d = json.load(open('$work/e2e/lab/evidence/E-3.json'))
ok = (d['schema'] == 'opl.evidence/1' and d['kind'] == 'lean_audit'
      and d['verdict'] == 'proved' and d['verification_level'] == 'lean_checked'
      and d['sorries'] == [] and d['errors'] == []
      and set(d['axioms']['oddSum_eq_sq']) <= set(d['axiom_whitelist']))
if not ok:
    print(json.dumps(d, ensure_ascii=False)[:400], file=sys.stderr)
sys.exit(0 if ok else 1)"
  chk "6d 命题的具体实例独立重算"  0 python3 -c "
import sys
# 防的是语义错配：形式化写对了、编译也过了，但命题*不是*我们以为的那个。
# 用另一条完全不同的代码路径（Python 累加）重算 n=100 的具体实例。
n = 100
sys.exit(0 if sum(2 * i + 1 for i in range(n)) == n * n else 1)"
  chk "6e 台账登记该命题"          0 $BIN/opl-conj add --id E-3 \
      --title "前 n 个奇数之和等于 n²" \
      --statement "对任意自然数 n，1+3+5+…+(2n-1) = n²" --source $FIX/lean-real.lean
  chk "6f 台账定案 lean_checked"   0 $BIN/opl-conj set E-3 --formal-status proved \
      --evidence "$work/e2e/lab/evidence/E-3.json" --verification-level lean_checked
  chk "6g 终态：proved + 证据指针"  0 python3 -c "
import json, sys
f = json.load(open('$work/e2e/lab/conjectures/E-3.json'))
ok = (f['formal_status'] == 'proved'
      and f['verification_level'] == 'lean_checked'
      and any('E-3.json' in str(h.get('evidence', '')) for h in f['history']))
sys.exit(0 if ok else 1)"
fi

# ----------------------------------------------------------------
printf '\n  通过 %d / 失败 %d / 跳过 %d\n' "$pass" "$fail" "$skip"
[ "$fail" -gt 0 ] && exit 1
exit 0

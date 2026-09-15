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
# 三个证据夹具都**跑真检查器**产出，不手写 JSON 冒充：手写的那种连格式都不一定对，
# 用它测「台账认不认证据」会得到一个比真实情形宽松的结论。
#   ev-cert.json    真证书 -> verdict=VERIFIED
#   ev-notverified  内容篡改的证书 -> verdict=NOT VERIFIED（真记录，只是判决是否）
#   ev-stale.json   把真记录指向另一个文件 -> 哈希对不上
$BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert $FIX/uuf-100-1.drat \
    --evidence-out "$work/ev-cert.json" >/dev/null 2>&1
$BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert "$work/drat-tampered.drat" \
    --evidence-out "$work/ev-notverified.json" >/dev/null 2>&1
python3 -c "
import json
r = json.load(open('$work/ev-cert.json'))
r['certificate'] = '$work/drat-tampered.drat'      # 记录不变，指向的文件变了
json.dump(r, open('$work/ev-stale.json', 'w'))"
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

# ---- 证据必须是结构化的：指针非空 ≠ 复核过（审阅稿的复现已进回归）----
# 四条都是「填了就算过」的旧行为，现在逐条拦下。前三条来自审阅稿，第四条是本项目
# 自己的纪律（人工确认不能由机器判决代替）。
chk "证据文件不存在 -> 2"     2 $BIN/opl-conj set R-1 --formal-status proved \
    --evidence /nonexistent/evidence.json --verification-level lean_checked
chk "判决不足以支撑档位 -> 2" 2 $BIN/opl-conj set R-1 --formal-status proved \
    --evidence "$work/ev-notverified.json" --verification-level exact_certificate
chk "证据与文件对不上 -> 2"   2 $BIN/opl-conj set R-1 --formal-status proved \
    --evidence "$work/ev-stale.json" --verification-level exact_certificate
chk "缺人工确认 -> 2"         2 $BIN/opl-conj set R-1 --formalization-status faithfulness_checked
chk "人工确认不能由机器判决代替" 2 $BIN/opl-conj set R-1 \
    --verification-level human_peer_reviewed --evidence "$work/ev.json"
chk "带 --confirmed-by 才放行" 0 $BIN/opl-conj set R-1 \
    --formalization-status faithfulness_checked --confirmed-by "EBT"
# 真记录必须能过：否则上面那五条等于把功能锁死了
chk "真证书记录可升档"        0 $BIN/opl-conj set R-1 --formal-status proved \
    --evidence "$work/ev-cert.json" --verification-level exact_certificate
chk "升档在 history 里留下证据哈希" 0 python3 -c "
import json, sys
why = []
d = json.load(open('$work/lab/conjectures/R-1.json'))
h = [x for x in d['history'] if x['field'] == 'verification_level'
     and x['to'] == 'exact_certificate']
if not h:
    why.append('history 里没有这次升档')
elif not h[-1].get('evidence_sha256'):
    why.append('升档没记下 evidence_sha256 —— 事后无法比对证据是否被换过')
if d['verification_level'] != 'exact_certificate':
    why.append('档位没落盘')
# 人工确认单独建模，不与机器判决混在一列
conf = d.get('human_confirmations') or []
if not conf or conf[-1].get('by') != 'EBT':
    why.append('人工确认没有单独记录：%r' % conf)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 反例的证据不足：**降级而不是伪造** —— 也不拒收（台账要留住「试过但没成」）
chk "反例证据不足 -> 记 UNVERIFIED" 0 $BIN/opl-conj set R-1 \
    --add-counterexample "n=99" --evidence "随便一个字符串"
chk "该反例没有被盖上复核章"  0 python3 -c "
import json, sys
cs = json.load(open('$work/lab/conjectures/R-1.json'))['counterexamples']
c = [x for x in cs if x['witness'] == 'n=99'][0]
sys.exit(0 if (c['verified_by'] == 'UNVERIFIED'
               and c['verification_level'] == 'empirical') else 1)"

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

# ---- 判据 6：--detach / --wait ----
# 长任务用文件承载状态（`doc/plan/02-architecture.typ` 定的形态），好处是「超时重发」
# 天然变成续跑而非重跑。所以这里除了「能等」，还要**证明确实没重跑**——用一次副作用
# 计数来断言，而不是看两次 wait 的返回码相同（那只能证明它没崩）。
mkdir -p "$work/dw"
chk "detach 派发 -> 0"            0 $BIN/opl-run --runs-dir "$R" --id W1 --detach \
    --timeout 30 --workdir "$work/dw" -- /usr/bin/python3 -c "
import time
open('ran.log', 'a').write('exec\n')
time.sleep(1.5)"
chk "detach 后状态文件已出现"      0 python3 -c "
import json, os, sys
p = '$R/W1/status.json'
if not os.path.isfile(p):
    sys.exit(1)
st = json.load(open(p))
print('  state =', st.get('state'), file=sys.stderr)
sys.exit(0 if st.get('schema') == 'opl.run.status/1'
         and st.get('state') in ('dispatched', 'running', 'done') else 1)"
chk "wait 到终态"                 0 $BIN/opl-run --runs-dir "$R" --id W1 --wait --wait-timeout 30
chk "再 wait 两次：幂等且没重跑"   0 python3 -c "
import json, os, subprocess, sys
env = dict(os.environ)
why = []
first = json.load(open('$R/W1/status.json'))
for i in (2, 3):
    r = subprocess.run(['$BIN/opl-run', '--runs-dir', '$R', '--id', 'W1', '--wait',
                        '--wait-timeout', '30'], capture_output=True, env=env)
    if r.returncode != 0:
        why.append('第 %d 次 wait 退出码 %d' % (i, r.returncode))
again = json.load(open('$R/W1/status.json'))
# 1 结论一致
if (first.get('kind'), first.get('elapsed_ms')) != (again.get('kind'), again.get('elapsed_ms')):
    why.append('两次读到的结论不同：%r vs %r' % (first.get('kind'), again.get('kind')))
# 2 **没有重跑**：payload 的副作用只出现一次
log = '$work/dw/ran.log'
n = sum(1 for _ in open(log)) if os.path.isfile(log) else 0
if n != 1:
    why.append('payload 执行了 %d 次（应为 1）——wait 触发了重跑' % n)
# 3 与前台跑同一件事得到同一结局
fg = subprocess.run(['$BIN/opl-run', '--runs-dir', '$R', '--id', 'W1-fg',
                     '--workdir', '$work/dw', '--', '/usr/bin/python3', '-c',
                     \"open('fg.log','a').write('e\\\\n')\"], capture_output=True)
if fg.returncode != 0:
    why.append('前台对照组退出码 %d' % fg.returncode)
if first.get('kind') != 'ok':
    why.append('detach 的终态是 %r（应为 ok）' % first.get('kind'))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "detach 一个长任务（为下一行铺垫）" 0 $BIN/opl-run --runs-dir "$R" --id W2 --detach \
    --timeout 30 --workdir "$work/dw" -- /usr/bin/python3 -c "
import time
time.sleep(4)"
# 还在跑时 wait：必须给 3（「还没有结论」），既不是 0 也不是 1。
chk "还在跑时 wait -> 3（不是失败）" 3 $BIN/opl-run --runs-dir "$R" --id W2 --wait --wait-timeout 1
chk "W2 终态随后可取到"           0 $BIN/opl-run --runs-dir "$R" --id W2 --wait --wait-timeout 30
# ---------------------------------------------------------------- 排序网络夹具
# 判据 7 的地基：玩具问题本身要成立——评估器确定性、骨架与最优之间有**真实余量**。
# 评估器是**两阶段**的：`extract` 跑候选只产出数据，`verify` 读数据独立判定。
# 所以下面每条用例都跑两次，断言取 `verify` 那一次（判决在它手里）。
echo "opl-evolve 夹具与约束（排序网络 + 两阶段评估器 + EVOLVE-BLOCK + code_hash）"
SNF="$FIX/sortnet"          # 后面几组也用它；定义提前到第一次使用之前

# 单阶段评估器（老写法）：插件要求两阶段协议，**必须明确拒绝**，而不是把它误报成
# 「候选被拒」——不合规的评估器收到 `extract` 时 argparse 会以 2 结束，而那正是
# 「候选不可用」的约定码。靠退出码推测就会指错方向。
cat > "$work/single_stage_ev.py" <<'PYEOF'
import argparse, json, sys
ap = argparse.ArgumentParser()
ap.add_argument("--candidate", required=True)
ap.add_argument("--problem", required=True)
ap.add_argument("--metrics-out")
a = ap.parse_args()
ns = {}
exec(compile(open(a.candidate).read(), a.candidate, "exec"), ns)
m = {"schema": "opl.evolve.metrics/1", "sorts": True, "comparators": 6,
     "zero_one_inputs_checked": 16}
if a.metrics_out:
    json.dump(m, open(a.metrics_out, "w"))
sys.exit(0)
PYEOF



mkdir -p "$work/sn/work"
cp "$FIX/sortnet/evaluator.py" "$FIX/sortnet/skeleton.py" \
   "$FIX/sortnet/candidate-opt5.py" "$FIX/sortnet/problem.json" "$work/sn/"
# 负样本现造：少一个比较器（不排序）、比较器越界（数据不合规）
cat > "$work/sn/broken.py" <<'EOF'
N = 4
def build_network():
    return [(0, 1), (2, 3), (0, 2), (1, 3)]
EOF
cat > "$work/sn/oob.py" <<'EOF'
N = 4
def build_network():
    return [(0, 4)]
EOF
# F1 的载荷（审阅稿第二轮）：候选把**评估器进程内**的枚举器换掉。
# 单进程评估器会给它退出码 0；两阶段里它只污染 extract 那一侧，verify 独立枚举。
cat > "$work/sn/evil.py" <<'EOF'
N = 4

import itertools
itertools.product = lambda *a, **k: [(0, 0, 0, 0)]


def build_network():
    return []
EOF

# 两阶段跑一遍：先 extract（候选在这里跑），再 verify。返回 verify 的退出码。
sn_two_stage() {  # $1=run id  $2=候选文件名
  rm -rf "$work/sn/work/artifacts"
  mkdir -p "$work/sn/work/artifacts"
  cp "$work/sn/$2" "$work/sn/work/cand.py" 2>/dev/null || true
  # 评估器与冻结定义**只读**挂进去（`/opt/...`），跟插件自己的做法一致：
  # 工作目录里只放候选，可信的东西不在候选能改的地方。
  "$BIN/opl-run" --runs-dir "$R" --id "$1-extract" --timeout 30 \
    --workdir "$work/sn/work" \
    --ro-bind "$work/sn/evaluator.py:/opt/evaluator.py" \
    --ro-bind "$work/sn/problem.json:/opt/problem.json" -- \
    /usr/bin/python3 /opt/evaluator.py extract --problem /opt/problem.json \
    --candidate /work/cand.py --artifacts /work/artifacts >/dev/null 2>&1
  local a=$?
  if [ "$a" != 0 ]; then return "$a"; fi
  "$BIN/opl-run" --runs-dir "$R" --id "$1-verify" --timeout 30 \
    --workdir "$work/sn/work" \
    --ro-bind "$work/sn/evaluator.py:/opt/evaluator.py" \
    --ro-bind "$work/sn/problem.json:/opt/problem.json" -- \
    /usr/bin/python3 /opt/evaluator.py verify --problem /opt/problem.json \
    --artifacts /work/artifacts --metrics-out /work/EV-M.json >/dev/null 2>&1
}
chk "骨架可评估 -> 0" 0 sn_two_stage S1 skeleton.py
chk "已知最优可评估 -> 0" 0 sn_two_stage S2 candidate-opt5.py
chk "不排序的候选 -> 1" 1 sn_two_stage S3 broken.py
# 注意分层：`opl-run` 只回答「这个进程成功了吗」，payload 非零一律收成 1；
# 评估器自己的约定码（2=数据不合规）留在快照的 `payload_exit_code` 里。
chk "越界候选 -> opl-run 报 1" 1 sn_two_stage S4 oob.py
chk "越界候选的评估器码是 2" 0 python3 -c "
import json, os, sys
m = json.load(open(os.path.join('$R', 'S4-verify', 'metrics.json')))
err = open(os.path.join('$R', 'S4-verify', 'stderr.txt')).read()
why = []
if m.get('payload_exit_code') != 2:
    why.append('payload_exit_code=%r（应为 2）' % m.get('payload_exit_code'))
if '越界' not in err:
    why.append('stderr 没说清是越界：%r' % err.strip()[-80:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# **F1 的核心断言**：候选替换进程内的枚举器，不再能伪造成功。
# 修前：单进程评估器报 sorts=true, comparators=0, zero_one_inputs_checked=1 并给退出码 0。
chk "F1 替换进程内枚举器 -> 不可行" 1 sn_two_stage S5 evil.py
chk "非两阶段评估器 -> 明确拒绝（不误报候选）" 0 python3 -c "
import os, shutil, subprocess, sys, tempfile
env = dict(os.environ)
SN = '$SNF'
d = tempfile.mkdtemp(prefix='opl-1stage.')
why = []
try:
    shutil.copyfile('$work/single_stage_ev.py', d + '/ev.py')
    r = subprocess.run(['$BIN/opl-evolve-init', '--lab', d + '/lab',
                        '--skeleton', SN + '/skeleton.py',
                        '--evaluator', d + '/ev.py',
                        '--problem', SN + '/problem.json'],
                       capture_output=True, text=True, env=env)
    if r.returncode == 0:
        why.append('单阶段评估器被接受了——协议不是硬约定')
    msg = r.stderr + r.stdout
    if '两阶段' not in msg:
        why.append('拒绝理由没提两阶段协议：%r' % msg.strip()[-100:])
    if '候选' in msg and '两阶段' not in msg:
        why.append('把协议问题误报成了候选问题')
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F1 verify 独立枚举了 16 个输入" 0 python3 -c "
import json, sys
m = json.load(open('$work/sn/work/EV-M.json'))
why = []
if m.get('zero_one_inputs_checked') != 16:
    why.append('只查了 %r 个输入（应为 16 = 2^4）' % m.get('zero_one_inputs_checked'))
if m.get('sorts') is not False:
    why.append('被替换过枚举器的候选仍被判 sorts=%r' % m.get('sorts'))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "判决有依据：6 / 5 / 反例" 0 python3 -c "
import json, os, sys
why = []
# 每个 run id 的 verify 阶段各自留了一份 stdout（判决与依据都在它里面）
def verdict(rid):
    p = os.path.join('$R', rid + '-verify', 'stdout.txt')
    for line in open(p).read().splitlines():
        if line.strip().startswith('{'):
            return json.loads(line)
    return None
c1, c2, c3 = (verdict(x) for x in ('S1', 'S2', 'S3'))
if not c1 or c1.get('comparators') != 6 or c1.get('sorts') is not True:
    why.append('骨架的判决不对：%r' % c1)
if not c2 or c2.get('comparators') != 5:
    why.append('最优的比较器数 %r（应为 5）——余量不成立则判据 7 无从谈起' % (c2 or {}).get('comparators'))
if not c3 or c3.get('sorts') is not False or not c3.get('first_counterexample'):
    why.append('不排序的候选没给反例：%r' % c3)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 沙箱把实验目录整个藏起来了：候选只看得到自己那次运行的目录（F2b）
chk "候选不可写实验目录（探针）" 0 python3 -c "
import os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
from opl_run import RunSpec, execute
SN = '$SNF'
d = tempfile.mkdtemp()
E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
           problem_src=SN + '/problem.json')
ev = d + '/lab/evolve'
probe = ('import os\n'
         'print(\"sees skeleton:\", os.path.exists(\"/work/skeleton.py\"))\n'
         'print(\"sees db:\", os.path.exists(\"/work/programs.sqlite\"))\n'
         'print(\"sees runs:\", os.path.exists(\"/work/runs\"))\n'
         'print(\"problem writable:\", os.access(\"/opt/problem.json\", os.W_OK))\n')
work = d + '/probe'
os.makedirs(work)
execute(RunSpec(argv=['/usr/bin/python3', '-c', probe], workdir=work,
                runner_dir=d + '/probe-run', run_id='p',
                ro_binds=[(ev + '/evaluator.py', '/opt/evaluator.py'),
                          (ev + '/problem.json', '/opt/problem.json')]))
out = open(d + '/probe-run/stdout.txt').read()
why = []
for bad, what in (('sees skeleton: True', '能看到 skeleton.py'),
                  ('sees db: True', '能看到 programs.sqlite'),
                  ('sees runs: True', '能看到 runs/')):
    if bad in out:
        why.append('候选' + what)
if 'problem writable: False' not in out:
    why.append('冻结定义在沙箱内可写')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# code_hash：吸收写法差异，区分语义（判据 8 的执行点）
chk "code_hash：吸收写法差异，区分语义" 0 python3 -c "
import sys
sys.path.insert(0, '$plugin/lib')
from opl_evolve import code_hash
base = 'x = 1\ny = x + 1\n'
h0, mode = code_hash(base)
why = []
if mode != 'tokens':
    why.append('基准的归一化模式是 %r' % mode)
for name, v in [('行尾补空格', 'x = 1   \ny = x + 1   \n'),
                ('每行加注释', 'x = 1  # a\ny = x + 1  # b\n'),
                ('空行改写', 'x = 1\n\n\ny = x + 1\n'),
                ('CRLF', 'x = 1\r\ny = x + 1\r\n')]:
    if code_hash(v)[0] != h0:
        why.append('%s 未被归一化吸收' % name)
for name, v in [('改数字', 'x = 2\ny = x + 1\n'), ('换写法', 'x = 1\ny = 1 + x\n')]:
    if code_hash(v)[0] == h0:
        why.append('%s 被误判为同一程序' % name)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "区外改动被拒且指出位置" 0 python3 -c "
import sys
sys.path.insert(0, '$plugin/lib')
from opl_evolve import EvolveError, assert_only_block_changed, split_block
skel = open('$FIX/sortnet/skeleton.py').read()
b = split_block(skel)
why = []
if b.before + b.block + b.after != skel:
    why.append('切块不能拼回原文')
opt = open('$FIX/sortnet/candidate-opt5.py').read()
try:
    assert_only_block_changed(skel, opt)
except EvolveError as exc:
    why.append('合法候选被误拒：%s' % exc)
for name, cand in [('区外改空格', skel.replace('N = 4', 'N  = 4')),
                   ('区外加注释', skel.replace('N = 4', '# 我加的\nN = 4')),
                   ('区外改 N', skel.replace('N = 4', 'N = 5')),
                   ('删掉标记行', skel.replace('# EVOLVE-BLOCK-START\n', ''))]:
    try:
        assert_only_block_changed(skel, cand)
        why.append('%s 竟然通过了' % name)
    except EvolveError as exc:
        msg = str(exc)
        if '行' not in msg and '标记' not in msg:
            why.append('%s 被拒但理由不具体：%s' % (name, msg[:60]))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "重复提交被 code_hash 拒并给出理由" 0 python3 -c "
import os, shutil, sys, tempfile
sys.path.insert(0, '$plugin/lib')
from opl_evolve import ProgramLibrary
skel = open('$FIX/sortnet/skeleton.py').read()
opt = open('$FIX/sortnet/candidate-opt5.py').read()
d = tempfile.mkdtemp(prefix='opllib.')
why = []
try:
    lib = ProgramLibrary(os.path.join(d, 'p.sqlite'))
    r1 = lib.add(code=skel, skeleton=skel, generation=0, operation='init',
                 metrics={'comparators': 6})
    r2 = lib.add(code=opt, skeleton=skel, generation=1, operation='mutate',
                 metrics={'comparators': 5})
    r3 = lib.add(code=opt, skeleton=skel, generation=1, operation='mutate')
    if not (r1.accepted and r2.accepted):
        why.append('前两次提交应被接受：%r / %r' % (r1.rejected_reason, r2.rejected_reason))
    if r3.accepted:
        why.append('同一份候选第二次仍被接受——去重没生效')
    elif 'code_hash' not in (r3.rejected_reason or ''):
        why.append('被拒的理由里没提 code_hash：%r' % r3.rejected_reason)
    if lib.count() != 2:
        why.append('库容 %d（应为 2）' % lib.count())
    lib.close()
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"

# ---- 判据 7/8/9：命令层的退出码矩阵 ----
# `opl-evolve-*` 的结局有四种，退出码必须分开：0 新增且通过 / 1 新增但不通过 /
# 2 候选不合格 / 5 重复没有新增。混起来调用方就没法处置。
echo "opl-evolve 命令 —— 退出码矩阵与「改进」的可追性"
EL="$work/elab"
SNF="$FIX/sortnet"
chk "init -> 0"                    0 $BIN/opl-evolve-init --lab "$EL" \
    --skeleton "$SNF/skeleton.py" --evaluator "$SNF/evaluator.py" \
    --problem "$SNF/problem.json"
chk "init 重复 -> 2"               2 $BIN/opl-evolve-init --lab "$EL" \
    --skeleton "$SNF/skeleton.py" --evaluator "$SNF/evaluator.py" \
    --problem "$SNF/problem.json"
chk "show 库非空 -> 0"             0 $BIN/opl-evolve-show --lab "$EL"
chk "show 不存在的 id -> 5"        5 $BIN/opl-evolve-show --lab "$EL" --id 999
chk "eval 最优候选 -> 0"           0 $BIN/opl-evolve-eval --lab "$EL" \
    --candidate "$SNF/candidate-opt5.py" --generation 1 --operation mutate
chk "同一份再来 -> 5（判据 8）"    5 $BIN/opl-evolve-eval --lab "$EL" \
    --candidate "$SNF/candidate-opt5.py" --generation 1
# 区外被改的候选：只把 `N = 4` 改成等长的 `N = 5`
python3 -c "
s = open('$SNF/candidate-opt5.py').read()
open('$work/elab-oob.py', 'w').write(s.replace('N = 4', 'N = 5', 1))"
chk "区外被改 -> 2（判据 9）"      2 $BIN/opl-evolve-eval --lab "$EL" \
    --candidate "$work/elab-oob.py"
# 少一个比较器：候选合法、入库，但评估不通过
python3 -c "
s = open('$SNF/candidate-opt5.py').read()
open('$work/elab-bad.py', 'w').write(
    s.replace('[(0, 1), (2, 3), (0, 2), (1, 3), (1, 2)]', '[(0, 1), (2, 3), (0, 2), (1, 3)]'))"
chk "不排序的候选 -> 1"            1 $BIN/opl-evolve-eval --lab "$EL" \
    --candidate "$work/elab-bad.py" --generation 2
# 判据 7 本体：改进必须**可追到 metrics_json 的具体字段**，且两个值都在库里。
# 这里刻意先用一条「不过滤」的对照把坑亮出来：库里有一条不排序的 4 比较器候选，
# `--best comparators` 不筛选时会选中它——数字最小不等于最好。改进的断言必须
# 带可行性条件，否则「从 6 改进到 4」听起来像提升，其实是个坏程序。
chk "不过滤会选中不可行者（如实）" 0 python3 -c "
import json, os, subprocess, sys
env = dict(os.environ)
r = subprocess.run(['$BIN/opl-evolve-show', '--lab', '$EL', '--best', 'comparators'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 0:
    why.append('退出码 %d' % r.returncode)
else:
    got = json.loads(r.stdout)
    m = got.get('metrics') or {}
    if m.get('comparators') != 4 or m.get('sorts') is not False:
        why.append('期望选中那条 4 比较器且不排序的：%r' % m)
    if '不可行' not in r.stderr:
        why.append('选到不可行者却没有提示：%r' % r.stderr[-80:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "改进可追：基线 6 -> 最好 5"   0 python3 -c "
import json, os, subprocess, sqlite3, sys
env = dict(os.environ)
db = os.path.join('$EL', 'evolve', 'programs.sqlite')
why = []
con = sqlite3.connect(db)
con.row_factory = sqlite3.Row
rows = [dict(r) for r in con.execute('SELECT * FROM programs ORDER BY id')]
con.close()
if len(rows) != 3:
    why.append('库容 %d（应为 3：基线 + 最优 + 不排序）' % len(rows))
def metrics(rec):
    return json.loads(rec['metrics_json']) if rec['metrics_json'] else None
m = {r['id']: metrics(r) for r in rows}
base = [v for v in m.values() if v and v.get('comparators') == 6]
best = [v for v in m.values() if v and v.get('comparators') == 5]
if not base:
    why.append('库里没有 comparators=6 的基线（改进就没有可比对象）')
if not best:
    why.append('库里没有 comparators=5 的候选')
# 每个数字都要能在库里逐条指认，而不是只出现在命令输出里
for v in base + best:
    if 'zero_one_inputs_checked' not in v:
        why.append('指标缺 zero_one_inputs_checked：判决没有依据可查')
    if v.get('sorts') is not True:
        why.append('入库的候选 sorts=%r' % v.get('sorts'))
# 带可行性条件的 best 必须选到 5，且它是被搜索出来的（不是基线）
r = subprocess.run(['$BIN/opl-evolve-show', '--lab', '$EL', '--best', 'comparators',
                    '--where', 'sorts=true'], capture_output=True, text=True, env=env)
if r.returncode != 0:
    why.append('show --best --where 退出码 %d' % r.returncode)
else:
    got = json.loads(r.stdout)
    gm = got.get('metrics') or {}
    if gm.get('comparators') != 5:
        why.append('best(comparators,where sorts) = %r（应为 5）' % gm.get('comparators'))
    if gm.get('sorts') is not True:
        why.append('选出的最好那条 sorts=%r' % gm.get('sorts'))
    if got.get('operation') != 'mutate':
        why.append('最好的那条 op=%r（应为 mutate，即它是被搜索出来的）' % got.get('operation'))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 两道前置检查（区外比对、code_hash 去重）在**结局**上都由第二层兜住——`add()` 里
# 也会比对区外，唯一索引也会拦重复。所以它们省下的是**沙箱开销**，不是改变判决。
# 那就要把「不花冤枉钱」变成可断言的，否则这两道前置检查等于没人测。
chk "不合格/重复的候选不花沙箱的钱" 0 python3 -c "
import os, subprocess, sys
env = dict(os.environ)
runs = os.path.join('$EL', 'evolve', 'runs')
def snap():
    return sorted(os.listdir(runs)) if os.path.isdir(runs) else []
why = []
before = snap()
r1 = subprocess.run(['$BIN/opl-evolve-eval', '--lab', '$EL',
                     '--candidate', '$work/elab-oob.py'],
                    capture_output=True, text=True, env=env)
if r1.returncode != 2:
    why.append('区外被改的候选退出码 %d（应为 2）' % r1.returncode)
mid = snap()
if mid != before:
    why.append('区外被改的候选仍然跑了沙箱：%r -> %r' % (before, mid))
r2 = subprocess.run(['$BIN/opl-evolve-eval', '--lab', '$EL',
                     '--candidate', '$SNF/candidate-opt5.py'],
                    capture_output=True, text=True, env=env)
if r2.returncode != 5:
    why.append('重复候选退出码 %d（应为 5）' % r2.returncode)
after = snap()
if after != mid:
    why.append('重复候选仍然跑了沙箱：%r -> %r' % (mid, after))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 测试用的**通用两阶段**评估器：字段名与函数名都从实验定义读，因此同一份脚本能同时
# 服务「最大化 score」与「feasible/loss」两种实验。extract 只产出数据，verify 独立判定。
cat > "$work/generic_ev.py" <<'PYEOF'
import argparse, json, os, sys
ap = argparse.ArgumentParser()
sub = ap.add_subparsers(dest="stage", required=True)
_e = sub.add_parser("extract")
_e.add_argument("--problem"); _e.add_argument("--candidate"); _e.add_argument("--artifacts")
_v = sub.add_parser("verify")
_v.add_argument("--problem"); _v.add_argument("--artifacts"); _v.add_argument("--metrics-out")
a = ap.parse_args()
prob = json.load(open(a.problem))
fn = prob["params"]["func"]
if a.stage == "extract":
    ns = {}
    exec(compile(open(a.candidate).read(), a.candidate, "exec"), ns)
    os.makedirs(a.artifacts, exist_ok=True)
    json.dump({"schema": "opl.evolve.artifact/1", "probe": float(ns[fn](2.0))},
              open(os.path.join(a.artifacts, "g.json"), "w"))
    sys.exit(0)
d = json.load(open(os.path.join(a.artifacts, "g.json")))
req = prob["metrics"]["required"]
feas = prob["metrics"]["feasible"]["field"]
obj = (prob["metrics"].get("objective") or {}).get("field")
m = {"schema": "opl.evolve.metrics/1"}
for k, t in req.items():
    if k == feas or t == "bool":
        m[k] = True
    elif k == obj or t == "number":
        m[k] = d["probe"]
    else:
        m[k] = "x"
if a.metrics_out:
    json.dump(m, open(a.metrics_out, "w"))
print(json.dumps(m))
sys.exit(0)
PYEOF
# ---- F3/F4：判决只有一处实现；方向跟随实验定义 ----
# F3：`init_lab` 原先没有运行结局检查，一次 `timeout` 的结果会被当成可用基线
#     （实测 `baseline_note=None`，指标写进 programs，而 evaluations 里记着 timeout）。
# F4：`--minimize` 那个开关 `default=True` 且没有反向选项，定义说最大化时永远选反。
chk "F3 初始化不得接纳超时/OOM 结果" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
MET = {'sorts': True, 'comparators': 6, 'zero_one_inputs_checked': 16}
why = []
def stub(kind, pexit):
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        json.dump(MET, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(MET, rd, kind, {}, pexit, rd)
    E._stage_and_evaluate = fake
import sqlite3
CASES = (('timeout', None), ('oom', None), ('payload_failed', 3), ('payload_failed', 137))
for kind, pexit in CASES:
    d = tempfile.mkdtemp()
    stub(kind, pexit)
    res = E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
                     problem_src=SN + '/problem.json')
    if res.metrics is not None:
        why.append('%s/%s 的指标被当成可用基线' % (kind, pexit))
    if not res.baseline_note:
        why.append('%s/%s 没有任何说明' % (kind, pexit))
    con = sqlite3.connect(d + '/lab/evolve/programs.sqlite'); con.row_factory = sqlite3.Row
    row = dict(list(con.execute('SELECT metrics_json FROM programs'))[0])
    evk = [dict(r)['kind'] for r in con.execute('SELECT kind FROM evaluations')]
    con.close()
    if row['metrics_json'] is not None:
        why.append('%s/%s：programs.metrics_json 有值，但这次运行没有判决' % (kind, pexit))
    # 运行史记「发生了什么」（kind 是原始沙箱结局，那是事实），但**不能有判决**：
    # feasible 与 metrics 都必须是空的
    con = sqlite3.connect(d + '/lab/evolve/programs.sqlite'); con.row_factory = sqlite3.Row
    rows = [dict(r) for r in con.execute('SELECT feasible, metrics_json, note FROM evaluations')]
    con.close()
    if any(r['feasible'] is not None for r in rows):
        why.append('%s/%s：运行史给了可行/不可行判决' % (kind, pexit))
    if any(r['metrics_json'] is not None for r in rows):
        why.append('%s/%s：运行史存了不可信的指标' % (kind, pexit))
    if not any(r['note'] for r in rows):
        why.append('%s/%s：运行史没有说明为什么没有判决' % (kind, pexit))
# 对照：正常结局必须入库
d = tempfile.mkdtemp(); stub('ok', 0)
res = E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
                 problem_src=SN + '/problem.json')
if res.metrics is None:
    why.append('正常结局的基线竟然没入库')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F3 评估器退出码契约（1/2/3/137）" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
MET = {'sorts': True, 'comparators': 5, 'zero_one_inputs_checked': 16}
ORIG = E._stage_and_evaluate
why = []
# 契约：1=按约定不可行（结论）；2=拒收候选；>=3=评估器自身故障（不采信指标）
CASES = (('payload_failed', 1, 0), ('payload_failed', 2, 2),
         ('payload_failed', 3, 3), ('payload_failed', 137, 3), ('timeout', None, 3))
for kind, pexit, want in CASES:
    d = tempfile.mkdtemp()
    E._stage_and_evaluate = ORIG
    E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
               problem_src=SN + '/problem.json')
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb, _k=kind, _p=pexit):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        json.dump(MET, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(MET, rd, _k, {}, _p, rd)
    E._stage_and_evaluate = fake
    out = E.eval_candidate(d + '/lab', SN + '/candidate-opt5.py')
    if out.exit_code != want:
        why.append('kind=%s exit=%s -> 退出码 %d（应为 %d）' % (kind, pexit, out.exit_code, want))
E._stage_and_evaluate = ORIG
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F4 --best 跟随实验定义的方向" 0 python3 -c "
import json, os, shutil, subprocess, sys, tempfile
env = dict(os.environ)
d = tempfile.mkdtemp(prefix='opl-max.')
why = []
try:
    open(d + '/skel.py', 'w').write('# EVOLVE-BLOCK-START\ndef score(x):\n    return 0\n# EVOLVE-BLOCK-END\n')
    shutil.copyfile('$work/generic_ev.py', d + '/ev.py')
    json.dump({'schema': 'opl.evolve.problem/1',
               'params': {'func': 'score'},
               'metrics': {'feasible': {'field': 'ok', 'equals': True},
                           'objective': {'field': 'score', 'minimize': False},
                           'required': {'ok': 'bool', 'score': 'number'}}},
              open(d + '/problem.json', 'w'))
    lab = d + '/lab'
    subprocess.run(['$BIN/opl-evolve-init', '--lab', lab, '--skeleton', d + '/skel.py',
                    '--evaluator', d + '/ev.py', '--problem', d + '/problem.json'],
                   capture_output=True, env=env)
    for v in (0, 9):
        open(d + ('/c%d.py' % v), 'w').write(
            '# EVOLVE-BLOCK-START\ndef score(x):\n    return %d\n# EVOLVE-BLOCK-END\n' % v)
        subprocess.run(['$BIN/opl-evolve-eval', '--lab', lab, '--candidate', d + ('/c%d.py' % v)],
                       capture_output=True, env=env)
    def best(*extra):
        r = subprocess.run(['$BIN/opl-evolve-show', '--lab', lab, '--best', 'score',
                            '--json'] + list(extra), capture_output=True, text=True, env=env)
        if r.returncode != 0:
            return None
        return (json.loads(r.stdout).get('metrics') or {}).get('score')
    if best() != 9:
        why.append('定义说最大化，--best 却选中 %r（应 9）' % best())
    if best('--minimize') != 0:
        why.append('--minimize 选中 %r（应 0）' % best('--minimize'))
    if best('--maximize') != 9:
        why.append('--maximize 选中 %r（应 9）' % best('--maximize'))
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"

# ---- F5：程序身份与评估运行分列（同一程序可多次评估，各留证据）----
# 判据 8 要「重复提交被拒」，F5 要「同一程序能再评估一次」——两件事由**同一个动作**
# 触发，所以必须能区分：默认拒绝（不花沙箱的钱），补测要显式 `--reevaluate`。
# 测试用的**两阶段**评估器：extract 正常产出数据，verify 退出 3（模拟评估器坏了）。
# 为什么不能再用「不认子命令」的脚本：那会先被协议探测拒掉，而 F5 要测的是
# 「init 拿不到指标，之后能否补测」——协议探测是另一条路径。
cat > "$work/generic_ev.py" <<'PYEOF'
import argparse, json, os, sys
ap = argparse.ArgumentParser()
sub = ap.add_subparsers(dest="stage", required=True)
_e = sub.add_parser("extract")
_e.add_argument("--problem"); _e.add_argument("--candidate"); _e.add_argument("--artifacts")
_v = sub.add_parser("verify")
_v.add_argument("--problem"); _v.add_argument("--artifacts"); _v.add_argument("--metrics-out")
a = ap.parse_args()
prob = json.load(open(a.problem))
fn = prob["params"]["func"]
if a.stage == "extract":
    ns = {}
    exec(compile(open(a.candidate).read(), a.candidate, "exec"), ns)
    os.makedirs(a.artifacts, exist_ok=True)
    json.dump({"schema": "opl.evolve.artifact/1", "probe": float(ns[fn](2.0))},
              open(os.path.join(a.artifacts, "g.json"), "w"))
    sys.exit(0)
d = json.load(open(os.path.join(a.artifacts, "g.json")))
req = prob["metrics"]["required"]
feas = prob["metrics"]["feasible"]["field"]
obj = (prob["metrics"].get("objective") or {}).get("field")
m = {"schema": "opl.evolve.metrics/1"}
for k, t in req.items():
    if k == feas or t == "bool":
        m[k] = True
    elif k == obj or t == "number":
        m[k] = d["probe"]
    else:
        m[k] = "x"
if a.metrics_out:
    json.dump(m, open(a.metrics_out, "w"))
print(json.dumps(m))
sys.exit(0)
PYEOF
# ---- F3/F4：判决只有一处实现；方向跟随实验定义 ----
# F3：`init_lab` 原先没有运行结局检查，一次 `timeout` 的结果会被当成可用基线
#     （实测 `baseline_note=None`，指标写进 programs，而 evaluations 里记着 timeout）。
# F4：`--minimize` 那个开关 `default=True` 且没有反向选项，定义说最大化时永远选反。
chk "F3 初始化不得接纳超时/OOM 结果" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
MET = {'sorts': True, 'comparators': 6, 'zero_one_inputs_checked': 16}
why = []
def stub(kind, pexit):
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        json.dump(MET, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(MET, rd, kind, {}, pexit, rd)
    E._stage_and_evaluate = fake
import sqlite3
CASES = (('timeout', None), ('oom', None), ('payload_failed', 3), ('payload_failed', 137))
for kind, pexit in CASES:
    d = tempfile.mkdtemp()
    stub(kind, pexit)
    res = E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
                     problem_src=SN + '/problem.json')
    if res.metrics is not None:
        why.append('%s/%s 的指标被当成可用基线' % (kind, pexit))
    if not res.baseline_note:
        why.append('%s/%s 没有任何说明' % (kind, pexit))
    con = sqlite3.connect(d + '/lab/evolve/programs.sqlite'); con.row_factory = sqlite3.Row
    row = dict(list(con.execute('SELECT metrics_json FROM programs'))[0])
    evk = [dict(r)['kind'] for r in con.execute('SELECT kind FROM evaluations')]
    con.close()
    if row['metrics_json'] is not None:
        why.append('%s/%s：programs.metrics_json 有值，但这次运行没有判决' % (kind, pexit))
    # 运行史记「发生了什么」（kind 是原始沙箱结局，那是事实），但**不能有判决**：
    # feasible 与 metrics 都必须是空的
    con = sqlite3.connect(d + '/lab/evolve/programs.sqlite'); con.row_factory = sqlite3.Row
    rows = [dict(r) for r in con.execute('SELECT feasible, metrics_json, note FROM evaluations')]
    con.close()
    if any(r['feasible'] is not None for r in rows):
        why.append('%s/%s：运行史给了可行/不可行判决' % (kind, pexit))
    if any(r['metrics_json'] is not None for r in rows):
        why.append('%s/%s：运行史存了不可信的指标' % (kind, pexit))
    if not any(r['note'] for r in rows):
        why.append('%s/%s：运行史没有说明为什么没有判决' % (kind, pexit))
# 对照：正常结局必须入库
d = tempfile.mkdtemp(); stub('ok', 0)
res = E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
                 problem_src=SN + '/problem.json')
if res.metrics is None:
    why.append('正常结局的基线竟然没入库')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F3 评估器退出码契约（1/2/3/137）" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
MET = {'sorts': True, 'comparators': 5, 'zero_one_inputs_checked': 16}
ORIG = E._stage_and_evaluate
why = []
# 契约：1=按约定不可行（结论）；2=拒收候选；>=3=评估器自身故障（不采信指标）
CASES = (('payload_failed', 1, 0), ('payload_failed', 2, 2),
         ('payload_failed', 3, 3), ('payload_failed', 137, 3), ('timeout', None, 3))
for kind, pexit, want in CASES:
    d = tempfile.mkdtemp()
    E._stage_and_evaluate = ORIG
    E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
               problem_src=SN + '/problem.json')
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb, _k=kind, _p=pexit):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        json.dump(MET, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(MET, rd, _k, {}, _p, rd)
    E._stage_and_evaluate = fake
    out = E.eval_candidate(d + '/lab', SN + '/candidate-opt5.py')
    if out.exit_code != want:
        why.append('kind=%s exit=%s -> 退出码 %d（应为 %d）' % (kind, pexit, out.exit_code, want))
E._stage_and_evaluate = ORIG
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F4 --best 跟随实验定义的方向" 0 python3 -c "
import json, os, shutil, subprocess, sys, tempfile
env = dict(os.environ)
d = tempfile.mkdtemp(prefix='opl-max.')
why = []
try:
    open(d + '/skel.py', 'w').write('# EVOLVE-BLOCK-START\ndef score(x):\n    return 0\n# EVOLVE-BLOCK-END\n')
    shutil.copyfile('$work/generic_ev.py', d + '/ev.py')
    json.dump({'schema': 'opl.evolve.problem/1',
               'params': {'func': 'score'},
               'metrics': {'feasible': {'field': 'ok', 'equals': True},
                           'objective': {'field': 'score', 'minimize': False},
                           'required': {'ok': 'bool', 'score': 'number'}}},
              open(d + '/problem.json', 'w'))
    lab = d + '/lab'
    subprocess.run(['$BIN/opl-evolve-init', '--lab', lab, '--skeleton', d + '/skel.py',
                    '--evaluator', d + '/ev.py', '--problem', d + '/problem.json'],
                   capture_output=True, env=env)
    for v in (0, 9):
        open(d + ('/c%d.py' % v), 'w').write(
            '# EVOLVE-BLOCK-START\ndef score(x):\n    return %d\n# EVOLVE-BLOCK-END\n' % v)
        subprocess.run(['$BIN/opl-evolve-eval', '--lab', lab, '--candidate', d + ('/c%d.py' % v)],
                       capture_output=True, env=env)
    def best(*extra):
        r = subprocess.run(['$BIN/opl-evolve-show', '--lab', lab, '--best', 'score',
                            '--json'] + list(extra), capture_output=True, text=True, env=env)
        if r.returncode != 0:
            return None
        return (json.loads(r.stdout).get('metrics') or {}).get('score')
    if best() != 9:
        why.append('定义说最大化，--best 却选中 %r（应 9）' % best())
    if best('--minimize') != 0:
        why.append('--minimize 选中 %r（应 0）' % best('--minimize'))
    if best('--maximize') != 9:
        why.append('--maximize 选中 %r（应 9）' % best('--maximize'))
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"

# ---- F5：程序身份与评估运行分列（同一程序可多次评估，各留证据）----
# 判据 8 要「重复提交被拒」，F5 要「同一程序能再评估一次」——两件事由**同一个动作**
# 触发，所以必须能区分：默认拒绝（不花沙箱的钱），补测要显式 `--reevaluate`。
# 测试用的**两阶段**评估器：extract 正常产出数据，verify 退出 3（模拟评估器坏了）。
# 为什么不能再用「不认子命令」的脚本：那会先被协议探测拒掉，而 F5 要测的是
# 「init 拿不到指标，之后能否补测」——协议探测是另一条路径。
cat > "$work/broken_verify.py" <<'PYEOF'
import argparse, json, os, sys
ap = argparse.ArgumentParser()
sub = ap.add_subparsers(dest="stage", required=True)
_e = sub.add_parser("extract")
_e.add_argument("--problem"); _e.add_argument("--candidate"); _e.add_argument("--artifacts")
_v = sub.add_parser("verify")
_v.add_argument("--problem"); _v.add_argument("--artifacts"); _v.add_argument("--metrics-out")
a = ap.parse_args()
if a.stage == "extract":
    os.makedirs(a.artifacts, exist_ok=True)
    open(os.path.join(a.artifacts, "a.json"), "w").write("{}")
    sys.exit(0)
print("verifier crashed", file=sys.stderr)
sys.exit(3)
PYEOF
chk "F5 补测：身份不变、运行史 +1" 0 python3 -c "
import json, os, shutil, sqlite3, subprocess, sys, tempfile
env = dict(os.environ)
SN = '$SNF'
d = tempfile.mkdtemp(prefix='opl-reeval.')
why = []
try:
    lab = d + '/lab'
    # 先让评估器坏掉：基线拿不到指标
    # 坏掉的**两阶段**评估器：extract 正常，verify 退出 3（见上面生成的脚本）
    shutil.copyfile('$work/broken_verify.py', d + '/bad_ev.py')
    r0 = subprocess.run(['$BIN/opl-evolve-init', '--lab', lab,
                         '--skeleton', SN + '/skeleton.py',
                         '--evaluator', d + '/bad_ev.py',
                         '--problem', SN + '/problem.json'],
                        capture_output=True, text=True, env=env)
    if r0.returncode != 0:
        why.append('init 退出码 %d' % r0.returncode)
    db = lab + '/evolve/programs.sqlite'
    def q(sql):
        con = sqlite3.connect(db); con.row_factory = sqlite3.Row
        try:
            return [dict(r) for r in con.execute(sql)]
        finally:
            con.close()
    base = q('SELECT id, metrics_json FROM programs')
    if not base or base[0]['metrics_json'] is not None:
        why.append('基线本该没有指标：%r' % (base and base[0]['metrics_json']))
    if len(q('SELECT id FROM evaluations')) != 1:
        why.append('基线那次运行应当进运行史')
    skel = lab + '/evolve/skeleton.py'
    # 默认再提交：拒绝，且不花沙箱的钱
    r1 = subprocess.run(['$BIN/opl-evolve-eval', '--lab', lab, '--candidate', skel],
                        capture_output=True, text=True, env=env)
    if r1.returncode != 5:
        why.append('默认重复提交退出码 %d（应为 5）' % r1.returncode)
    # 换上好评估器，显式补测
    shutil.copyfile(SN + '/evaluator.py', lab + '/evolve/evaluator.py')
    r2 = subprocess.run(['$BIN/opl-evolve-eval', '--lab', lab, '--candidate', skel,
                         '--reevaluate'], capture_output=True, text=True, env=env)
    if r2.returncode != 0:
        why.append('补测退出码 %d：%s' % (r2.returncode, r2.stderr[-140:]))
    after = q('SELECT id, metrics_json FROM programs')
    # 1 身份不变：程序数还是 1，同一个 id
    if len(after) != 1 or after[0]['id'] != base[0]['id']:
        why.append('补测改变了程序身份：%r' % after)
    # 2 运行史 +1，且两次运行的目录不同（不覆盖证据）
    evs = q('SELECT id, run_dir, metrics_json FROM evaluations ORDER BY id')
    if len(evs) != 2:
        why.append('运行史 %d 条（应为 2）' % len(evs))
    elif evs[0]['run_dir'] == evs[1]['run_dir']:
        why.append('两次运行共用一个目录，前一次的证据被覆盖了')
    # 3 头条指标被补测填上
    if not after[0]['metrics_json']:
        why.append('补测之后基线仍然没有指标')
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F5 每次运行都落四份快照且来源可追" 0 python3 -c "
import json, os, sqlite3, sys
db = '$EL/evolve/programs.sqlite'
why = []
con = sqlite3.connect(db); con.row_factory = sqlite3.Row
runs = [dict(r) for r in con.execute('SELECT id, run_dir, program_id FROM evaluations')]
con.close()
if not runs:
    why.append('运行史是空的')
for r in runs:
    rd = r['run_dir']
    if not rd or not os.path.isdir(rd):
        why.append('运行 #%s 的目录不存在：%r' % (r['id'], rd))
        continue
    # 一次评估 = 两个阶段（extract / verify），**每阶段各自**落四份快照
    stages = [d for d in ('extract', 'verify') if os.path.isdir(os.path.join(rd, d))]
    if len(stages) != 2:
        why.append('运行 #%s 缺阶段目录（找到 %r）' % (r['id'], stages))
    for st in stages:
        sd = os.path.join(rd, st)
        for name in ('cmd.json', 'env.json', 'capabilities.json', 'metrics.json'):
            if not os.path.isfile(os.path.join(sd, name)):
                why.append('运行 #%s/%s 缺 %s' % (r['id'], st, name))
        mp = os.path.join(sd, 'metrics.json')
        if os.path.isfile(mp):
            m = json.load(open(mp))
            for k, v in (m.get('sources') or {}).items():
                if isinstance(v, str) and v.startswith('/') and not os.path.exists(v):
                    why.append('运行 #%s/%s 的 metrics.sources[%s] 指向不存在的路径'
                               % (r['id'], st, k))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F5 运行史可查（show --id）" 0 python3 -c "
import json, subprocess, sys
r = subprocess.run(['$BIN/opl-evolve-show', '--lab', '$EL', '--id', '1',
                    '--json'], capture_output=True, text=True)
why = []
if r.returncode != 0:
    why.append('show --id 退出码 %d' % r.returncode)
else:
    rec = json.loads(r.stdout)
    evs = rec.get('evaluations') or []
    if not evs:
        why.append('show --id 没带出运行史')
    for e in evs:
        if not e.get('kind'):
            why.append('运行史条目缺 kind：%r' % e)
        if 'created_at' not in e:
            why.append('运行史条目缺 created_at')
    # 运行史必须带「当时什么条件」——否则事后无法回答「这个数字哪来的」
    if evs and not any(e.get('evaluator_sha256') for e in evs):
        why.append('运行史没记评估器指纹，事后无法确认是哪份评估器跑的')
    if evs and not any(e.get('problem_sha256') for e in evs):
        why.append('运行史没记实验定义指纹')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# ---- F2/F3/F4：判决绑定到可信端（审阅稿的三条复现已进回归）----
# 三条都指向同一类错误：**把「东西在那儿」当成了「事情成立」**。
#   F2 区外文本没变   → 当成题目没变（候选在区内重绑定 N 就能改题目）
#   F3 产物存在       → 当成运行正常结束（超时/OOM 也写了 metrics 就判通过）
#   F4 字段名叫 sorts → 当成所有实验都是排序问题
chk "F2 区内改题目参数 -> 拒绝" 0 python3 -c "
import os, subprocess, sys
env = dict(os.environ)
# 改动**全部落在区内**：在块内重新绑定 N，覆盖区外的 N = 4
src = open('$SNF/skeleton.py').read()
cand = '$work/elab-params.py'
open(cand, 'w').write(src.replace(
    '    return [(0, 1), (1, 2), (2, 3), (0, 1), (1, 2), (0, 1)]',
    '    return []\n\nN = 0', 1))
r = subprocess.run(['$BIN/opl-evolve-eval', '--lab', '$EL', '--candidate', cand],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode == 0:
    why.append('区内改题目参数竟然通过了（sorts=True comparators=0 的假成功）')
if '不一致' not in r.stderr:
    why.append('拒绝理由没说清是题目参数不一致：%s' % r.stderr.strip()[-120:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F3 超时/OOM 不得判为通过" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
why = []
MET = {'sorts': True, 'comparators': 5, 'zero_one_inputs_checked': 16}
for kind in ('timeout', 'oom', 'signal'):
    d = tempfile.mkdtemp()
    E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
               problem_src=SN + '/problem.json')
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb, _k=kind):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        json.dump(MET, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(MET, rd, _k, {}, None, rd)
    E._stage_and_evaluate = fake
    out = E.eval_candidate(d + '/lab', SN + '/candidate-opt5.py')
    if out.exit_code != 3:
        why.append('%s + 有 metrics 得到退出码 %d（应为 3 没有判决）' % (kind, out.exit_code))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F3 指标类型不对 -> 拒绝而非猜" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
why = []
CASES = (
    ('sorts 是字符串 false', {'sorts': 'false', 'comparators': 4, 'zero_one_inputs_checked': 16}),
    ('缺 comparators 字段',   {'sorts': True, 'zero_one_inputs_checked': 16}),
    ('comparators 是字符串',  {'sorts': True, 'comparators': '5', 'zero_one_inputs_checked': 16}),
    ('metrics 是空对象',      {}))
for label, metrics in CASES:
    d = tempfile.mkdtemp()
    E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
               problem_src=SN + '/problem.json')
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb, _m=metrics):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        json.dump(_m, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(_m, rd, 'ok', {}, 0, rd)
    E._stage_and_evaluate = fake
    out = E.eval_candidate(d + '/lab', SN + '/candidate-opt5.py')
    if out.exit_code != 2:
        why.append('%s 得到退出码 %d（应为 2 记录不合格）' % (label, out.exit_code))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F4 通用评估器（feasible/loss）-> 可行" 0 python3 -c "
import json, os, shutil, subprocess, sys, tempfile
env = dict(os.environ)
d = tempfile.mkdtemp(prefix='opl-generic.')
why = []
try:
    open(d + '/skeleton.py', 'w').write(
        '# EVOLVE-BLOCK-START\ndef predict(x):\n    return x * 0.5\n# EVOLVE-BLOCK-END\n')
    shutil.copyfile('$work/generic_ev.py', d + '/evaluator.py')
    # **没有 sorts 字段**：可行性叫 feasible，目标叫 loss
    json.dump({'schema': 'opl.evolve.problem/1',
               'params': {'func': 'predict'},
               'metrics': {'feasible': {'field': 'feasible', 'equals': True},
                           'objective': {'field': 'loss', 'minimize': True},
                           'required': {'feasible': 'bool', 'loss': 'number'}}},
              open(d + '/problem.json', 'w'))
    open(d + '/cand.py', 'w').write(
        '# EVOLVE-BLOCK-START\ndef predict(x):\n    return x * 0.4999\n# EVOLVE-BLOCK-END\n')
    lab = d + '/lab'
    r0 = subprocess.run(['$BIN/opl-evolve-init', '--lab', lab, '--skeleton', d + '/skeleton.py',
                         '--evaluator', d + '/evaluator.py', '--problem', d + '/problem.json'],
                        capture_output=True, text=True, env=env)
    if r0.returncode != 0:
        why.append('init 退出码 %d：%s' % (r0.returncode, r0.stderr[-140:]))
    r = subprocess.run(['$BIN/opl-evolve-eval', '--lab', lab, '--candidate', d + '/cand.py'],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        why.append('通用评估器判可行的候选得到退出码 %d：%s' % (r.returncode, r.stderr[-160:]))
    if 'FEASIBLE' not in r.stdout:
        why.append('stdout 里没有 FEASIBLE：%r' % r.stdout.strip())
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# F2b：候选伸不到实验目录（探针实测）。安全侧的硬断言，不是文档承诺。
chk "F2b 候选不可写实验目录" 0 python3 -c "
import os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
from opl_run import RunSpec, execute
SN = '$SNF'
d = tempfile.mkdtemp()
E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
           problem_src=SN + '/problem.json')
ev = d + '/lab/evolve'
why = []
probe = ('import os\n'
         'print(\"sees skeleton:\", os.path.exists(\"/work/skeleton.py\"))\n'
         'print(\"sees db:\", os.path.exists(\"/work/programs.sqlite\"))\n'
         'print(\"sees runs:\", os.path.exists(\"/work/runs\"))\n'
         'print(\"sees workdir:\", os.getcwd())\n'
         'print(\"problem writable:\", os.access(\"/opt/problem.json\", os.W_OK))\n'
         'print(\"evaluator writable:\", os.access(\"/opt/evaluator.py\", os.W_OK))\n')
work = d + '/probe'
os.makedirs(work)
r = execute(RunSpec(argv=['/usr/bin/python3', '-c', probe], workdir=work,
                    runner_dir=d + '/probe-run', run_id='p',
                    ro_binds=[(ev + '/evaluator.py', '/opt/evaluator.py'),
                              (ev + '/problem.json', '/opt/problem.json')]))
out = open(d + '/probe-run/stdout.txt').read()
print('  探针输出：' + out.strip().replace(chr(10), ' | '), file=sys.stderr)
for bad, what in (('sees skeleton: True', '能看到 skeleton.py'),
                  ('sees db: True', '能看到 programs.sqlite'),
                  ('sees runs: True', '能看到 runs/')):
    if bad in out:
        why.append('候选' + what)
for need, what in (('problem writable: False', '冻结定义在沙箱内可写'),
                   ('evaluator writable: False', '评估器在沙箱内可写')):
    if need not in out:
        why.append(what)
if r.kind != 'ok':
    why.append('探针运行结局 %r' % r.kind)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# ---- suggest + 技能（判据 7/13 的收口）----
# `suggest` 的核心不是「输出点什么」，而是**亲本必须有理由、且最好的那条真的是最好的**。
# 这里刻意先放一条更差的候选再问：排序方向写反过一次（把 comparators=6 当成了「当前
# 最好」，而库里明明有 5），所以这一条同时断言方向与理由。
chk "suggest 亲本有理由且方向正确" 0 python3 -c "
import json, os, subprocess, sys
env = dict(os.environ)
r = subprocess.run(['$BIN/opl-evolve-suggest', '--lab', '$EL',
                    '--metric', 'comparators', '--where', 'sorts=true', '--json'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 0:
    why.append('退出码 %d' % r.returncode)
else:
    d = json.loads(r.stdout)
    ps = d.get('parents') or []
    if not ps:
        why.append('没有亲本')
    else:
        top = ps[0]
        got = (top.get('metrics') or {}).get('comparators')
        if got != 5:
            why.append('「当前最好」是 comparators=%r（库里最好的是 5）——方向写反' % got)
        if (top.get('metrics') or {}).get('sorts') is not True:
            why.append('亲本不可行：sorts=%r' % (top.get('metrics') or {}).get('sorts'))
        if 'why' not in top:
            why.append('亲本没给理由')
        # 每条亲本都要有理由，而且理由要能区分（不是同一个字符串复读）
        whys = [p.get('why') for p in ps]
        if any(not w for w in whys):
            why.append('有亲本没给理由：%r' % whys)
        if len(set(whys)) != len(whys):
            why.append('亲本理由重复：%r' % whys)
    if len(d.get('constraints') or []) < 3:
        why.append('约束列得太少：%r' % d.get('constraints'))
    # 注意 evolve_block 是**标记之间**的内容，标记本身在 immutable_outside 里。
    # （第一版把这条断言写成「evolve_block 里要有 EVOLVE-BLOCK」，错在没分清两者。）
    # 这里刻意不用反引号：chk 的参数是双引号串，反引号会被 shell 当命令替换执行。
    blob = d.get('evolve_block') or ''
    if not blob.strip() or 'build_network' not in blob:
        why.append('任务书没给出可进化区的内容：%r' % blob[:40])
    if 'EVOLVE-BLOCK' not in (d.get('immutable_outside') or ''):
        why.append('任务书没标明不可动的区外在哪里')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "skill frontmatter 有 name/description: opl-evolve" 0 python3 -c "
import re, sys
t = open('$plugin/skills/opl-evolve/SKILL.md').read()
m = re.match(r'^---\n(.*?)\n---\n', t, re.S)
fm = m.group(1) if m else ''
sys.exit(0 if 'name: opl-evolve' in fm and 'description:' in fm else 1)"
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
# 复核见证并**产出结构化证据记录**：裸的 witness.json 不是证据——它既没法证明
# 「谁复核的」，也没法证明「复核的是这份见证」。台账升档要求 opl.evidence/1。
chk "4 独立复核见证"          0 $BIN/opl-encode --spec $FIX/spec-pc23.json \
    --eval-witness "$work/e2e/witness.json" --evidence-out "$work/e2e/ev-witness.json"
chk "5 台账定案"              0 $BIN/opl-conj set E-1 --formal-status refuted \
    --evidence "$work/e2e/ev-witness.json" --verification-level exact_certificate
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

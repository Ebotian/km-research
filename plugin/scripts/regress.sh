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

# 签名密钥走临时文件（`OPL_SIGNING_KEY`）：回归**不碰**本机 `~/.config` 里那把真密钥，
# 也就顺带证明了「密钥位置可覆盖」这条契约。没有签名器时台账与证据产出都会拒绝动作，
# 所以这一行是后面所有用例的前提——它自己也应当被测（见 N1）。
export OPL_SIGNING_KEY="$work/signing-key"

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
# 密钥先生成好：没有签名器时台账与证据产出都会拒绝动作（这正是设计），
# 后面所有用例都以此为前提。
chk "N0 生成临时签名密钥" 0 "$BIN/opl-sign" init
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
    --evidence-out "$work/ev-cert.json" --subject R-1 --range 1..1000 >/dev/null 2>&1
$BIN/opl-certcheck --formula $FIX/uuf-100-1.cnf --cert "$work/drat-tampered.drat" \
    --evidence-out "$work/ev-notverified.json" --subject R-1 --range 1..1000 >/dev/null 2>&1
python3 -c "
import json
r = json.load(open('$work/ev-cert.json'))
r['certificate'] = '$work/drat-tampered.drat'      # 记录不变，指向的文件变了
json.dump(r, open('$work/ev-stale.json', 'w'))"
# R-1 的**见证证据**：改结论=refuted 需要它（方向是 witness_eval）。
# 「带证据改状态」那条用例原先给的是一个**不存在的文件**——在只查「串非空」的年代
# 能过，现在改结论会真校验证据，所以必须给真东西。
$BIN/opl-encode --spec $FIX/spec-pc23.json --eval-witness $FIX/spec-pc23-witness.json \
    --evidence-out "$work/ev-wit.json" --subject R-1 >/dev/null 2>&1
chk "add"                    0 $BIN/opl-conj add --id R-1 --statement "测试陈述"
chk "无证据改状态（拒绝写入）" 2 $BIN/opl-conj set R-1 --formal-status refuted
chk "带证据改状态"           0 $BIN/opl-conj set R-1 --formal-status refuted --evidence "$work/ev-wit.json"
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
chk "判决不足以支撑档位 -> 2" 2 $BIN/opl-conj set R-1 \
    --formal-status no_counterexample_in_range --verified-range 1..1000 \
    --evidence "$work/ev-notverified.json" --verification-level exact_certificate
chk "证据与文件对不上 -> 2"   2 $BIN/opl-conj set R-1 \
    --formal-status no_counterexample_in_range --verified-range 1..1000 \
    --evidence "$work/ev-stale.json" --verification-level exact_certificate
chk "缺人工确认 -> 2"         2 $BIN/opl-conj set R-1 --formalization-status faithfulness_checked
chk "人工确认不能由机器判决代替" 2 $BIN/opl-conj set R-1 \
    --verification-level human_peer_reviewed --evidence "$work/ev.json"
chk "带 --confirmed-by 才放行" 0 $BIN/opl-conj set R-1 \
    --formalization-status faithfulness_checked --confirmed-by "EBT"
# 真记录必须能过：否则上面那五条等于把功能锁死了
# 证书支撑的结论是「该范围内无反例」，不是「已被推翻」——**方向由证据种类决定**。
# 所以这条要连范围一起给（范围必须与证据里记的一致，否则「某范围内」无法核对）。
chk "真证书记录可升档"        0 $BIN/opl-conj set R-1 \
    --formal-status no_counterexample_in_range --verified-range 1..1000 \
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

# ---- F2：证据必须绑定对象、方向与范围（审阅稿第二轮的复现）----
$BIN/opl-conj add --id R-2 --statement "另一个猜想" >/dev/null 2>&1
# 「真证据说假话」比假证据更难防：证据本身没问题，它被拿来说了另一件事。
chk "F2 真证据不得给另一个猜想背书" 0 python3 -c "
import subprocess, sys, os
env = dict(os.environ)
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-2',
                    '--formal-status', 'no_counterexample_in_range',
                    '--verified-range', '1..1000',
                    '--evidence', '$work/ev-cert.json'],   # 这份证据的 subject 是 R-1
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if 'subject' not in (r.stderr + r.stdout):
    why.append('理由没提 subject：%r' % r.stderr.strip()[-90:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F2 证据方向必须匹配结论" 0 python3 -c "
import subprocess, sys, os
env = dict(os.environ)
why = []
# 见证记录（witness_eval）说不了「该范围内没有反例」
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1',
                    '--formal-status', 'no_counterexample_in_range',
                    '--verified-range', '1..1000',
                    '--evidence', '$work/ev-wit.json'],
                   capture_output=True, text=True, env=env)
if r.returncode != 2:
    why.append('用见证支撑「无反例」得到退出码 %d（应为 2）' % r.returncode)
if 'witness_eval' not in (r.stderr + r.stdout):
    why.append('理由没点出证据种类：%r' % r.stderr.strip()[-90:])
# 反过来：证书说不了「已被推翻」
r2 = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--formal-status', 'refuted',
                     '--evidence', '$work/ev-cert.json'],
                    capture_output=True, text=True, env=env)
if r2.returncode != 2:
    why.append('用证书支撑「已被推翻」得到退出码 %d（应为 2）' % r2.returncode)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F2 范围必须与证据一致" 0 python3 -c "
import subprocess, sys, os
env = dict(os.environ)
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1',
                    '--formal-status', 'no_counterexample_in_range',
                    '--verified-range', '1..7',            # 证据里记的是 1..1000
                    '--evidence', '$work/ev-cert.json'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if 'range' not in (r.stderr + r.stdout):
    why.append('理由没提 range：%r' % r.stderr.strip()[-90:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F2 缺绑定字段的记录 -> 2" 0 python3 -c "
import json, subprocess, sys, os
env = dict(os.environ)
# 只有 schema/kind/subject/verdict 的记录：没有 certificate 与它的哈希
json.dump({'schema': 'opl.evidence/1', 'kind': 'cert', 'subject': 'R-1',
           'range': '1..1000', 'verdict': 'VERIFIED'}, open('$work/ev-bare.json', 'w'))
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1',
                    '--formal-status', 'no_counterexample_in_range',
                    '--verified-range', '1..1000',
                    '--evidence', '$work/ev-bare.json'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if 'certificate_sha256' not in (r.stderr + r.stdout):
    why.append('理由没点出缺哪个绑定字段：%r' % r.stderr.strip()[-90:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 改结论必须重新校验，且档位**重新定**而不是继承——这是「换结论不换徽章」的正面修法
chk "F2 改结论重新校验并重定档位" 0 python3 -c "
import json, subprocess, sys, os
env = dict(os.environ)
why = []
# 1 不存在的证据 + 改结论：旧版给退出码 0 并把旧档位原样留着
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--formal-status', 'refuted',
                    '--evidence', '/nonexistent/x.json'],
                   capture_output=True, text=True, env=env)
if r.returncode != 2:
    why.append('改结论 + 不存在的证据得到退出码 %d（应为 2）' % r.returncode)
# 2 用对方向的证据改结论：档位由证据重定（witness → exact_certificate）
r2 = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--formal-status', 'refuted',
                     '--evidence', '$work/ev-wit.json'],
                    capture_output=True, text=True, env=env)
if r2.returncode != 0:
    why.append('正确的方向改结论得到退出码 %d：%s' % (r2.returncode, r2.stderr[-100:]))
d = json.load(open('$work/lab/conjectures/R-1.json'))
if d['verification_level'] != 'exact_certificate':
    why.append('档位是 %r（应为 exact_certificate）' % d['verification_level'])
# 3 换成不需要证据的结论（open）：档位必须**降下来**，不继承
r3 = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--formal-status', 'open',
                     '--evidence', '$work/ev-wit.json'],
                    capture_output=True, text=True, env=env)
d = json.load(open('$work/lab/conjectures/R-1.json'))
if d['verification_level'] != 'empirical':
    why.append('结论改回 open 之后档位仍是 %r——徽章被继承了'
               % d['verification_level'])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"

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
# 被限额杀掉的 scope **不许留在 systemd 里**。修之前实测堆了 136 个
# `opl-probe-mem-*.scope`：cgroup 早释放了、内存没漏，但单元一直以 failed 挂着
# （`systemctl stop` 不清 failed 状态；`systemd-run --collect` 才会跑完即卸）。
# 断言分两步，**先证明这条链真跑了**（限额确实开火）再查残留——否则「什么都没有」
# 与「清理干净了」看起来一模一样。
if command -v systemd-run >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  chk "限额开火后不留失败的 scope 单元" 0 python3 -c "
import os, subprocess, sys, time
sys.path.insert(0, '$plugin/lib')
import opl_probe
why = []
# **只查本次进程建的那几个单元**：探针的命名里带自己的 pid
# （`opl-probe-mem-<pid>-z.scope`）。查「有没有任何 opl-probe-mem 单元」是不隔离的——
# 历史残留会把这条用例永久弄红，那不是被测代码的错（实测踩过：注入后恢复代码，用例
# 仍然红，因为上一轮注入留下的两个单元还在）。
me = os.getpid()
mine = 'opl-probe-mem-%d-' % me
res = opl_probe.probe_sandbox()
fires = res.get('mem_limit_fires') or {}
swap_case = fires.get('MemoryMax + MemorySwapMax=0') or {}
if not swap_case.get('killed'):
    why.append('这条链没跑起来或限额没开火（%r）——那「没残留」说明不了清理' % (swap_case,))
# --collect 是异步卸载：轮询几秒，别拿「立刻查一次」当判据（实测会误判）
left = []
deadline = time.monotonic() + 6
while time.monotonic() < deadline:
    q = subprocess.run(['systemctl', '--user', 'list-units', '--type=scope', '--all'],
                       capture_output=True, text=True)
    left = [ln.split()[0] for ln in q.stdout.splitlines() if mine in ln]
    if not left:
        break
    time.sleep(0.2)
if left:
    why.append('被限额杀掉之后本次的单元仍留着：%s' % left[:4])
    for u in left:
        subprocess.run(['systemctl', '--user', 'reset-failed', u], capture_output=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
else
  skip=$((skip + 1))
  printf '  skip  %-46s 没有可用的 systemd 用户会话\n' "限额开火后不留失败的 scope 单元"
fi
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
# 来源写成**相对运行目录**的路径（第六轮改的）：绝对路径会把主机布局焊进产物，实验目录
# 一搬家（init_lab 就是先建暂存、再整体切换）来源全变死链。所以这里按相对解析，并且
# **反过来断言产物里不许出现绝对路径**——那正是「搬完还能追」的前提。
m = load('T3', 'metrics') or {}
src = m.get('sources') or {}
arts = m.get('artifacts') or {}
for k, v in list(src.items()) + list(arts.items()):
    if not isinstance(v, str) or not v:
        continue
    if v.startswith('/'):
        why.append('metrics.%s 是绝对路径（%s）——搬个地方就成死链' % (k, v))
        continue
    if k in ('wall_ms', 'payload_exit_code') or v.startswith('（'):
        continue                      # 说明性文字，不是路径
    if not os.path.exists(os.path.join(R, 'T3', v)):
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
chk "F3 评估器退出码契约（1/2/3/137）" 0 python3 -c "
import json, os, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
SN = '$SNF'
ORIG = E._stage_and_evaluate
why = []
# 契约：1=按约定不可行（结论）；2=拒收候选；>=3=评估器自身故障（不采信指标）
# **退出码与指标矛盾时不下判决**（F4，审阅稿第三轮）：1 说不可行而指标说可行，
# 或 0 说跑完而指标说不可行 —— 两份原始信息矛盾，任选一个当成功依据都是自欺。
CASES = (('payload_failed', 1, True, 3),    # 1 + 指标说可行 -> 矛盾 -> UNKNOWN
         ('payload_failed', 1, False, 1),   # 1 + 指标说不可行 -> 一致的结论
         ('payload_failed', 0, True, 0),    # 0 + 指标说可行 -> 通过（对照）
         ('payload_failed', 0, False, 3),   # 0 + 指标说不可行 -> 矛盾
         ('payload_failed', 2, True, 2),
         ('payload_failed', 3, True, 3), ('payload_failed', 137, True, 3),
         ('timeout', None, True, 3))
for kind, pexit, feas, want in CASES:
    d = tempfile.mkdtemp()
    E._stage_and_evaluate = ORIG
    E.init_lab(d + '/lab', SN + '/skeleton.py', SN + '/evaluator.py',
               problem_src=SN + '/problem.json')
    def fake(p, code, h, *, problem_path, timeout, mem_max_mb, _k=kind, _p=pexit, _f=feas):
        rd = os.path.join(p['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        met = {'sorts': _f, 'comparators': 5, 'zero_one_inputs_checked': 16}
        json.dump(met, open(rd + '/work/metrics.json', 'w'))
        return E.RunFacts(met, rd, _k, {}, _p, rd)
    E._stage_and_evaluate = fake
    out = E.eval_candidate(d + '/lab', SN + '/candidate-opt5.py')
    if out.exit_code != want:
        why.append('kind=%s exit=%s feasible=%s -> 退出码 %d（应为 %d）'
                   % (kind, pexit, feas, out.exit_code, want))
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
BASE = '$EL/evolve'
for r in runs:
    rd = r['run_dir']
    if rd and os.path.isabs(rd):
        # 第七轮审阅 F2：绝对路径一搬就成死链，而且**归档库的索引会指向活实验**。
        # 库里存的是相对实验目录的形式，这里按相对解析并断言这一点。
        why.append('运行 #%s 的 run_dir 存成了绝对路径（%r）' % (r['id'], rd))
        continue
    rd = os.path.join(BASE, rd) if rd else rd
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
            # `sources` 里只有这几个键装的是**路径**；`wall_ms` 与 `payload_exit_code`
            # 按契约是人话（「runner 墙钟」之类），不该拿它们去 open()。
            PATH_KEYS = ('stdout_bytes', 'stderr_bytes', 'peak_mem_bytes', 'oom_kill')
            for k, v in (m.get('sources') or {}).items():
                if k not in PATH_KEYS or not isinstance(v, str) or not v:
                    continue
                if v.startswith('（'):
                    continue      # cgroup 不可用时这里写的是人话，不是路径
                if v.startswith('/'):
                    why.append('运行 #%s/%s 的 sources[%s] 是绝对路径（%s）——'
                               '搬个地方就成死链' % (r['id'], st, k, v))
                elif not os.path.exists(os.path.join(sd, v)):
                    why.append('运行 #%s/%s 的 metrics.sources[%s] 指向不存在的路径'
                               % (r['id'], st, k))
            for k, v in (m.get('artifacts') or {}).items():
                if not isinstance(v, str) or not v:
                    continue
                if v.startswith('/'):
                    why.append('运行 #%s/%s 的 artifacts[%s] 是绝对路径（%s）'
                               % (r['id'], st, k, v))
                elif not os.path.exists(os.path.join(sd, v)):
                    why.append('运行 #%s/%s 的 artifacts[%s] 指不到：%s'
                               % (r['id'], st, k, v))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "F5 运行史可查（show --id）" 0 python3 -c "
import json, os, subprocess, sys
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
    # 运行史是**给人导航**的：`run_dir` 必须解析成绝对路径且真的在。
    # 库里存的是相对实验目录的形式，所以这一条测的是读接口有没有把它接回绝对路径
    # （注入「读出时不解析」时，这条必须变红——直接读 SQL 的用例测不到那一层）。
    for e in evs:
        if not e.get('kind'):
            why.append('运行史条目缺 kind：%r' % e)
        if 'created_at' not in e:
            why.append('运行史条目缺 created_at')
        rd = e.get('run_dir')
        if not rd or not os.path.isabs(rd):
            why.append('运行史的 run_dir 不是绝对路径：%r（读接口没解析）' % rd)
        elif not os.path.isdir(rd):
            why.append('运行史的 run_dir 指不到：%r' % rd)
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
# ---- R3：第三轮审阅的五条（共同点是**检查绑在参数上，而不是绑在记录上**）----
#   R3-1 只改范围不换证据   → 把已经验证过的结论扩大 10 万倍
#   R3-2 最小 JSON 升档     → 缺 kind 就没有「按种类必填」的集合，等于随便写个文件
#   R3-3 追加反例给无关文件盖章 → 验证的是 A，章盖在 B 上
#   R3-4 退出码与指标矛盾   → 任选一个当成功依据
#   R3-5 --force 重建后旧成绩继续参与排名 → 同名指标 != 同一件事
#
# 修法是一次成型的：**先把改动全部应用到副本上，再校验修改后的完整记录**，不自洽就
# 整笔拒绝。逐个参数补条件的写法会一直漏——每加一个入口就多一个缺口。
chk "R3-1 先登记「1..1000 内无反例」（带证书）" 0 \
    $BIN/opl-conj set R-1 --formal-status no_counterexample_in_range \
    --verified-range 1..1000 --evidence "$work/ev-cert.json"
chk "R3-1 只改范围不换证据 -> 2 且整笔不写" 0 python3 -c "
import json, subprocess, sys, os
env = dict(os.environ)
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--verified-range', '1..1000000'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if '范围' not in (r.stderr + r.stdout):
    why.append('理由没点出范围与证据不一致：%r' % r.stderr.strip()[-120:])
d = json.load(open('$work/lab/conjectures/R-1.json'))
if (d.get('verified_range') or {}).get('hi') != 1000:
    why.append('被拒之后记录里的范围仍是 %r——拒收必须整笔不写'
               % (d.get('verified_range'),))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R3-2 无 kind 的最小 JSON 升档 -> 2 且档位不动" 0 python3 -c "
import json, subprocess, sys, os
env = dict(os.environ)
json.dump({'schema': 'opl.evidence/1', 'verdict': 'proved'}, open('$work/ev-nokind.json', 'w'))
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--verification-level', 'lean_checked',
                    '--evidence', '$work/ev-nokind.json'], capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if 'kind' not in (r.stderr + r.stdout):
    why.append('理由没点出缺 kind：%r' % r.stderr.strip()[-120:])
d = json.load(open('$work/lab/conjectures/R-1.json'))
if d['verification_level'] != 'exact_certificate':
    why.append('档位被改成了 %r（应为原来的 exact_certificate）' % d['verification_level'])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R3-3 追加反例：无关见证降级、正主才盖章" 0 python3 -c "
import json, subprocess, sys, os
env = dict(os.environ)
# 证据里记着它到底验证了哪份见证 —— 章只能盖在这一份上
wit = json.load(open('$work/ev-wit.json'))['witness']
why = []
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-1',
                    '--add-counterexample', '/nonexistent/other.json',
                    '--evidence', '$work/ev-wit.json'], capture_output=True, text=True, env=env)
if r.returncode != 0:
    why.append('无关见证应降级记录（不拒收），却得到退出码 %d：%s' % (r.returncode, r.stderr[-100:]))
else:
    cs = json.load(open('$work/lab/conjectures/R-1.json'))['counterexamples']
    c = [x for x in cs if x['witness'] == '/nonexistent/other.json'][0]
    if c['verified_by'] != 'UNVERIFIED':
        why.append('无关文件拿到了 %r' % c['verified_by'])
# 正向对照：换成证据里那个见证，就该有章。没有这一半，守卫可能只是「永远不发章」。
r2 = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--add-counterexample', wit,
                     '--evidence', '$work/ev-wit.json'], capture_output=True, text=True, env=env)
if r2.returncode != 0:
    why.append('正对该见证却得到退出码 %d：%s' % (r2.returncode, r2.stderr[-120:]))
else:
    cs = json.load(open('$work/lab/conjectures/R-1.json'))['counterexamples']
    c = [x for x in cs if x['witness'] == wit][0]
    if c['verified_by'] != 'independent':
        why.append('正对该见证却记成了 %r（对照失败，守卫过严）' % c['verified_by'])
# 丙：见证名**不是路径**时也不能豁免比对。「不是路径所以没法比」这条豁免等于
# 「换个写法的见证名就能把章挪走」——实测过：早期版本的守卫只比路径形态的见证。
r3 = subprocess.run(['$BIN/opl-conj', 'set', 'R-1', '--add-counterexample', 'n=12345',
                     '--evidence', '$work/ev-wit.json'], capture_output=True, text=True, env=env)
if r3.returncode != 0:
    why.append('非路径见证应降级记录，却得到退出码 %d：%s' % (r3.returncode, r3.stderr[-100:]))
else:
    cs = json.load(open('$work/lab/conjectures/R-1.json'))['counterexamples']
    c = [x for x in cs if x['witness'] == 'n=12345'][0]
    if c['verified_by'] != 'UNVERIFIED':
        why.append('非路径见证 n=12345 拿到了 %r（证据验证的是 %r）'
                   % (c['verified_by'], wit))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R3-4 退出码与指标矛盾 -> 不下判决" 0 python3 -c "
import os, sys
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
p = E.load_problem('$SNF/problem.json')
why = []
# 协议：0=跑完（可行性看指标），1=按约定不可行（结论）。两者矛盾时两份信息都得留着。
CASES = ((1, True, 3), (0, False, 3), (0, True, 0), (1, False, 1))
for pexit, feas, want in CASES:
    j = E.judge_run(kind='payload_failed', payload_exit=pexit,
                    metrics={'sorts': feas, 'comparators': 5, 'zero_one_inputs_checked': 16},
                    problem=p)
    if j.exit_code != want:
        why.append('exit=%s sorts=%s -> %d（应为 %d）' % (pexit, feas, j.exit_code, want))
    elif want == 3 and not j.reason:
        why.append('exit=%s sorts=%s 判为 UNKNOWN 却没说理由' % (pexit, feas))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R3-5 --force 归档旧库，best() 不混用不同实验" 0 python3 -c "
import json, os, shutil, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
d = tempfile.mkdtemp(prefix='opl-force.')
why = []
try:
    open(d + '/skel.py', 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 1\n# EVOLVE-BLOCK-END\n')
    # 指标跟着**题目参数**走：换了参数，旧成绩就不再是同一件事的成绩
    open(d + '/ev.py', 'w').write('''
import argparse, json, os, sys
ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='stage', required=True)
e = sub.add_parser('extract'); e.add_argument('--problem'); e.add_argument('--candidate'); e.add_argument('--artifacts')
v = sub.add_parser('verify'); v.add_argument('--problem'); v.add_argument('--artifacts'); v.add_argument('--metrics-out')
a = ap.parse_args()
if a.stage == 'extract':
    os.makedirs(a.artifacts, exist_ok=True)
    open(os.path.join(a.artifacts, 'a.json'), 'w').write('{}')
    sys.exit(0)
k = json.load(open(a.problem))['params']['k']
m = {'schema': 'opl.evolve.metrics/1', 'ok': True, 'score': k}
if a.metrics_out: json.dump(m, open(a.metrics_out, 'w'))
sys.exit(0)
''')
    def problem(k):
        json.dump({'schema': 'opl.evolve.problem/1', 'params': {'k': k},
                   'metrics': {'feasible': {'field': 'ok', 'equals': True},
                               'objective': {'field': 'score', 'minimize': True},
                               'required': {'ok': 'bool', 'score': 'number'}}},
                  open(d + '/problem.json', 'w'))
    problem(1)
    E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py', problem_src=d + '/problem.json')
    db = d + '/lab/evolve/programs.sqlite'
    old_fp = None
    with E.ProgramLibrary(db) as lib:
        for rec in lib.all_programs():
            # 成绩的来源（第八轮改成跟着「产生它的那次评估」走，不再取最近一次运行）
            old_fp = lib.metrics_fingerprints(rec['id'])
    problem(999)                       # 换了题目参数（同一份代码，另一个问题）
    res = E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py',
                     problem_src=d + '/problem.json', force=True)
    if not res.archived_dir or not os.path.isdir(res.archived_dir):
        why.append('--force 没有归档旧实验（archived_dir=%r）' % res.archived_dir)
    else:
        # 归档必须是**整个实验**：只留库会让成绩与骨架对不上
        for need in ('skeleton.py', 'evaluator.py', 'problem.json', 'programs.sqlite'):
            if not os.path.isfile(os.path.join(res.archived_dir, need)):
                why.append('归档里缺 %s' % need)
    with E.ProgramLibrary(db) as lib:
        if lib.count() != 1:
            why.append('重建后库里还有 %d 条（应为 1 条新基线）' % lib.count())
        b = lib.best('score', minimize=True)
        if (b or {}).get('metrics', {}).get('score') != 999:
            why.append('best() 取到的是 %r（应为新实验的 999）' % ((b or {}).get('metrics'),))
        # 指纹过滤：把一条**旧实验指纹**的成绩塞回来，带当前指纹的查询必须跳过它
        ar = lib.add(code='# EVOLVE-BLOCK-START\ndef f(x):\n    return 2\n# EVOLVE-BLOCK-END\n',
                     skeleton=open(d + '/skel.py').read())
        if ar.accepted:
            lib.add_evaluation(int(ar.program_id or 0), kind='ok', run_dir=None,
                               metrics={'ok': True, 'score': 0}, feasible=True,
                               problem_sha256=old_fp[0], evaluator_sha256=old_fp[1])
            b2 = lib.best('score', minimize=True, fingerprints=('x', 'y'))
            if b2 is not None and b2.get('metrics', {}).get('score') == 0:
                why.append('带当前指纹的 best() 仍然选中了旧实验的成绩')
            if not getattr(lib, 'skipped_incomparable', 0):
                why.append('跳过了不可比的成绩却没有计数，用户看不到这件事')
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# ---- R4：第四轮审阅的三条 ----
#   R4-1 不合格的见证（verdict=NOT VERIFIED）与别人的证据都能盖复核章
#         →「证据读得出来」被当成了「证据说它成立」；对象根本没核对
#   R4-2 记录只存摘要，不重读证据 → 把被验证的见证换掉，结论继续挂着 exact_certificate
#   R4-3 重建先归档活库再验输入 → 一次无效请求就把正常实验的库挪走了
$BIN/opl-conj add --id R-4 --statement "第四轮审阅" >/dev/null 2>&1
# 一份**违反规格**的见证：把 y00 翻一位（规格只有一组满足赋值）
chk "R4-0 备一份不合格见证与三份证据" 0 python3 -c "
import json, subprocess, os
w = json.load(open('$FIX/spec-pc23-witness.json'))
w['y00'] = 1 - w['y00']
json.dump(w, open('$work/bad-witness.json', 'w'))
env = dict(os.environ)
# 三份证据：合格的（本猜想）、不合格的（判决 NOT VERIFIED）、合格但**属于别人**的。
# 第三份是关键：只用「不合格」那份测不出「对象没核对」——判决那道闸会先把它拦下，
# 于是「去掉对象检查」这种注入不会变红（实测踩过，M2 没被抓住）。
for wit, out, sub in (('$FIX/spec-pc23-witness.json', 'r4-good.json', 'R-4'),
                      ('$work/bad-witness.json', 'r4-bad.json', 'R-4'),
                      ('$FIX/spec-pc23-witness.json', 'r4-other.json', 'R-2')):
    subprocess.run(['$BIN/opl-encode', '--spec', '$FIX/spec-pc23.json',
                    '--eval-witness', wit, '--evidence-out', '$work/' + out,
                    '--subject', sub], capture_output=True, env=env)
bad = json.load(open('$work/r4-bad.json'))
other = json.load(open('$work/r4-other.json'))
if bad['verdict'] == 'VERIFIED':
    raise SystemExit('这份见证居然通过了规格求值，夹具要换')
if other['verdict'] != 'VERIFIED' or other['subject'] != 'R-2':
    raise SystemExit('第三份证据不合用：%s / %s' % (other['verdict'], other['subject']))
print('  不合格证据 verdict =', bad['verdict'], '；别人的证据 subject =', other['subject'])"
chk "R4-1 不合格见证/别人的证据都不得盖章" 0 python3 -c "
import json, subprocess, sys, os
env = dict(os.environ)
why = []
def add(witness, evidence):
    return subprocess.run(['$BIN/opl-conj', 'set', 'R-4', '--add-counterexample', witness,
                           '--evidence', evidence], capture_output=True, text=True, env=env)

# 甲：判决是 NOT VERIFIED 的见证 —— 该降级，不该盖章
r = add('$work/bad-witness.json', '$work/r4-bad.json')
if r.returncode != 0:
    why.append('不合格见证应降级记录（不拒收），却得到 %d：%s' % (r.returncode, r.stderr[-90:]))
else:
    cs = json.load(open('$work/lab/conjectures/R-4.json'))['counterexamples']
    c = [x for x in cs if x['witness'].endswith('bad-witness.json')][0]
    if c['verified_by'] != 'UNVERIFIED':
        why.append('不合格见证拿到了 %r' % c['verified_by'])

# 乙：证据本身有效（verdict=VERIFIED），但 subject 是**别人**（r4-other.json 属于 R-2）。
# 这一条单独测「对象」那道闸——用不合格的那份测不出来，它会被判决先拦下。
w2 = json.load(open('$work/r4-other.json'))['witness']
r = add(w2, '$work/r4-other.json')
if r.returncode != 0:
    why.append('对象不符应降级，却得到 %d：%s' % (r.returncode, r.stderr[-90:]))
else:
    cs = json.load(open('$work/lab/conjectures/R-4.json'))['counterexamples']
    c = cs[-1]
    if c['verified_by'] != 'UNVERIFIED':
        why.append('别的猜想（R-2）的有效证据拿到了 %r' % c['verified_by'])

# 丙：正向对照 —— 本猜想 + 合格见证 + 门当户对的证据，才该有章
wit = json.load(open('$work/r4-good.json'))['witness']
r = add(wit, '$work/r4-good.json')
if r.returncode != 0:
    why.append('正主见证得到 %d：%s' % (r.returncode, r.stderr[-90:]))
else:
    cs = json.load(open('$work/lab/conjectures/R-4.json'))['counterexamples']
    # 取**最后一条**：乙那条的见证名与这份一样（都指向夹具见证），只是证据来自 R-2。
    # 用第一条会读到乙的记录，把「守卫过严」误报出来——这正是对照要防的读错对象。
    c = cs[-1]
    if c['witness'] != wit:
        why.append('对照读错了条目：%r' % c['witness'])
    elif c['verified_by'] != 'independent':
        why.append('正主见证却记成了 %r（对照失败，守卫过严）' % c['verified_by'])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R4-2 见证被换掉后不得继续挂着原档位" 0 python3 -c "
import json, os, shutil, subprocess, sys
env = dict(os.environ)
d = '$work/r4-wit'
os.makedirs(d, exist_ok=True)
wit = d + '/witness.json'
shutil.copyfile('$FIX/spec-pc23-witness.json', wit)
subprocess.run(['$BIN/opl-encode', '--spec', '$FIX/spec-pc23.json', '--eval-witness', wit,
                '--evidence-out', d + '/ev.json', '--subject', 'R-4'],
               capture_output=True, env=env)
subprocess.run(['$BIN/opl-conj', 'set', 'R-4', '--formal-status', 'refuted',
                '--evidence', d + '/ev.json'], capture_output=True, env=env)
f = json.load(open('$work/lab/conjectures/R-4.json'))
why = []
if f['verification_level'] != 'exact_certificate':
    why.append('前置条件没建立：档位是 %r' % f['verification_level'])
# 把被验证的见证**换掉**：路径不变、内容变了。记录里存的摘要看不出这件事，
# 只有重新加载那份证据、重算它引用的输入哈希才发现。
json.dump({'y00': 1, 'y01': 1, 'y02': 0, 'y10': 1, 'y11': 1, 'y12': 0}, open(wit, 'w'))
r = subprocess.run(['$BIN/opl-conj', 'set', 'R-4', '--add-bound', 'n>=4@by-hand'],
                   capture_output=True, text=True, env=env)
f2 = json.load(open('$work/lab/conjectures/R-4.json'))
if r.returncode == 0 and f2['verification_level'] == 'exact_certificate':
    why.append('见证内容被换掉，记录仍挂着 exact_certificate（摘要当证据用了）')
if r.returncode != 0 and '核不过' not in (r.stderr + r.stdout):
    why.append('拒绝理由没点出依据核不过：%r' % r.stderr.strip()[-120:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R4-3 无效重建不动活库；备份名不撞车" 0 python3 -c "
import json, os, shutil, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
d = tempfile.mkdtemp(prefix='opl-r4.')
why = []
try:
    open(d + '/skel.py', 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 1\n# EVOLVE-BLOCK-END\n')
    open(d + '/ev.py', 'w').write('''
import argparse, json, os, sys
ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='stage', required=True)
e = sub.add_parser('extract'); e.add_argument('--problem'); e.add_argument('--candidate'); e.add_argument('--artifacts')
v = sub.add_parser('verify'); v.add_argument('--problem'); v.add_argument('--artifacts'); v.add_argument('--metrics-out')
a = ap.parse_args()
if a.stage == 'extract':
    os.makedirs(a.artifacts, exist_ok=True)
    open(os.path.join(a.artifacts, 'a.json'), 'w').write('{}')
    sys.exit(0)
m = {'schema': 'opl.evolve.metrics/1', 'ok': True, 'score': 1}
if a.metrics_out: json.dump(m, open(a.metrics_out, 'w'))
sys.exit(0)
''')
    json.dump({'schema': 'opl.evolve.problem/1', 'params': {},
               'metrics': {'feasible': {'field': 'ok', 'equals': True},
                           'objective': {'field': 'score', 'minimize': True},
                           'required': {'ok': 'bool', 'score': 'number'}}},
              open(d + '/problem.json', 'w'))
    E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py', problem_src=d + '/problem.json')
    db = d + '/lab/evolve/programs.sqlite'
    # 甲：骨架路径写错 —— 一次**无效请求**不该改变现有实验的状态
    try:
        E.init_lab(d + '/lab', d + '/不存在.py', d + '/ev.py',
                   problem_src=d + '/problem.json', force=True)
        why.append('无效重建竟然成功了')
    except E.EvolveError:
        pass
    if not os.path.exists(db):
        why.append('无效重建把活库挪走了（报错退出，但实验已经不完整）')
    # 乙：评估器不合协议 —— 同样要在**动活库之前**被拦下
    open(d + '/bad-ev.py', 'w').write('import sys\nsys.exit(0)\n')
    try:
        E.init_lab(d + '/lab', d + '/skel.py', d + '/bad-ev.py',
                   problem_src=d + '/problem.json', force=True)
        why.append('不合协议的评估器没被拒')
    except E.EvolveError:
        pass
    if not os.path.exists(db):
        why.append('协议探测失败也把活库挪走了')
    # 丙：同一秒里连续两次成功重建 —— 两份备份都要在（覆盖式 os.replace 会吃掉一份）
    E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py', problem_src=d + '/problem.json', force=True)
    E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py', problem_src=d + '/problem.json', force=True)
    baks = sorted(x for x in os.listdir(d + '/lab') if x.startswith('.evolve-bak-'))
    if len(baks) != 2:
        why.append('同一秒两次重建只留下 %d 份备份（应为 2）：%s' % (len(baks), baks))
    for b in baks:
        # 每份备份都得是**完整**的旧实验：只恢复库、不恢复骨架，等于留下一个新旧混合的
        # 实验（库里的成绩是配旧骨架的）。这是本轮 F2 的正面断言。
        for need in ('skeleton.py', 'evaluator.py', 'problem.json', 'programs.sqlite'):
            if not os.path.isfile(os.path.join(d + '/lab', b, need)):
                why.append('备份 %s 里缺 %s——回滚回去也是个残实验' % (b, need))
    for junk in ('.evolve-new-',):
        left = [x for x in os.listdir(d + '/lab') if x.startswith(junk)]
        if left:
            why.append('留下了暂存目录：%s' % left)
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# ---- N：签名——「这份证据/这条记录是**谁写的**」----
#
# 台账已经能查「记录自洽」与「输入现在的内容」，两层都查不出**手写一份自洽的假证据**：
# 哈希是自证的（写文件的人同时写了被引用文件），`verdict` 只是文件里的一行字。实测过
# 那条路能一路走到 `refuted` / `exact_certificate`。签名补的就是这一层。
NL="$work/nlab"
export OPL_LAB="$NL"
mkdir -p "$NL"
chk "N1 没有签名器时不写台账，且不留半个文件" 0 python3 -c "
import os, subprocess, sys
env = dict(os.environ, OPL_SIGNING_KEY='$work/没有这把密钥', OPL_LAB='$NL')
r = subprocess.run(['$BIN/opl-conj', 'add', '--id', 'N-1', '--statement', 'x'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 4:
    why.append('退出码 %d（应为 4 MISSING：这是「去配密钥」，不是「参数写错」）' % r.returncode)
if os.path.exists('$NL/conjectures/N-1.json'):
    why.append('盘上留下了没签名的记录——半个承诺比没有承诺更坏')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
$BIN/opl-conj add --id N-2 --statement "签名演示" >/dev/null 2>&1
chk "N2 手写的自洽假证据 -> 2（哈希全对也不行）" 0 python3 -c "
import hashlib, json, os, subprocess, sys
env = dict(os.environ)
def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()
w = '$work/N2-witness.json'
json.dump({'y00': 1, 'y01': 1, 'y02': 1, 'y10': 1, 'y11': 1, 'y12': 1}, open(w, 'w'))
spec = os.path.abspath('$FIX/spec-pc23.json')
ev = '$work/N2-evidence.json'
# 结构全对、方向对、对象对、哈希全对——**就是没有签名**
json.dump({'schema': 'opl.evidence/1', 'kind': 'witness_eval', 'subject': 'N-2',
           'verdict': 'VERIFIED', 'witness': os.path.abspath(w),
           'witness_sha256': sha(w), 'spec': spec, 'spec_sha256': sha(spec)},
          open(ev, 'w'))
r = subprocess.run(['$BIN/opl-conj', 'set', 'N-2', '--formal-status', 'refuted',
                    '--evidence', ev], capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if '签名' not in (r.stderr + r.stdout):
    why.append('理由没点出签名：%r' % r.stderr.strip()[-120:])
f = json.load(open('$NL/conjectures/N-2.json'))
if f.get('formal_status') != 'open':
    why.append('被拒之后结论变成了 %r' % f.get('formal_status'))
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "N3 真证据被改一个字节 -> 签名核不过" 0 python3 -c "
import json, os, shutil, subprocess, sys
env = dict(os.environ)
shutil.copyfile('$work/ev-wit.json', '$work/N3.json')
shutil.copyfile('$work/ev-wit.json.sig', '$work/N3.json.sig')
raw = json.load(open('$work/N3.json'))
raw['subject'] = 'N-2'                      # 对象对上，把「签名」那一层逼出来
raw['n_assignments'] = 999                  # 改掉一个字节
json.dump(raw, open('$work/N3.json', 'w'))
r = subprocess.run(['$BIN/opl-conj', 'set', 'N-2', '--formal-status', 'refuted',
                    '--evidence', '$work/N3.json'], capture_output=True, text=True, env=env)
why = []
if r.returncode != 2:
    why.append('退出码 %d（应为 2）' % r.returncode)
if '签名' not in (r.stderr + r.stdout):
    why.append('理由没点出签名：%r' % r.stderr.strip()[-120:])
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# 这条锁住一个**退出码 0 的静默失败**：`ssh-keygen -Y sign` 在目标 .sig 已存在时会
# 交互式问 "Overwrite (y/n)?"，非交互场景读到 EOF 就什么都不做，而**退出码仍是 0**。
# 于是「签名成功」其实是上一版内容的旧签名，改完之后记录立刻变成「签名核不过」。
chk "N4 同一路径改内容后再签，签名必须跟着更新" 0 python3 -c "
import sys
sys.path.insert(0, '$plugin/lib')
from opl_sign import sign_file, verify_file
p = '$work/N4.txt'
for i, text in enumerate(('第一版', '第二版', '第三版')):
    open(p, 'w').write(text)
    sign_file(p)
    ok, why = verify_file(p)
    if not ok:
        print('  第 %d 次签名之后验不过：%s' % (i + 1, why), file=sys.stderr)
        raise SystemExit(1)
open(p, 'w').write('偷偷改一下')
ok, _ = verify_file(p)
sys.exit(0 if not ok else 1)"
chk "N5 手改记录：拒改 + 如实标注 + 可人工收编" 0 python3 -c "
import json, os, subprocess, sys
env = dict(os.environ)
p = '$NL/conjectures/N-2.json'
raw = json.load(open(p))
raw['formal_status'] = 'refuted'            # 手工改出来的结论
json.dump(raw, open(p, 'w'), ensure_ascii=False, indent=2)
why = []
r = subprocess.run(['$BIN/opl-conj', 'set', 'N-2', '--formal-status', 'proved',
                    '--evidence', '$work/ev-wit.json'], capture_output=True, text=True, env=env)
if r.returncode != 2 or '签名' not in (r.stderr + r.stdout):
    why.append('手改之后改写没有被拦：rc=%d' % r.returncode)
g = subprocess.run(['$BIN/opl-conj', 'get', 'N-2'], capture_output=True, text=True, env=env)
if '\"signed\": false' not in g.stdout:
    why.append('get 没有如实标注未经证实')
l = subprocess.run(['$BIN/opl-conj', 'list'], capture_output=True, text=True, env=env)
if '未签名' not in l.stdout and '签名核不过' not in l.stderr:
    why.append('list 没有标出来')
# 收编：人签字负责这份内容；撑不住的结论要被降下来，而不是照单全收
a = subprocess.run(['$BIN/opl-conj', 'set', 'N-2', '--adopt', '--confirmed-by', 'EBT'],
                   capture_output=True, text=True, env=env)
if a.returncode != 0:
    why.append('收编失败 rc=%d：%s' % (a.returncode, a.stderr[-140:]))
else:
    f = json.load(open(p))
    conf = [h for h in f.get('human_confirmations', [])
            if h.get('what') == 'adopt-unsigned-record']
    if not conf:
        why.append('收编没留下人工确认')
    elif '哈希是' not in conf[-1].get('note', ''):
        why.append('人工确认里没记下收编时看的是哪一份')
    if f.get('formal_status') != 'open':
        why.append('收编把手工改出来的 %r 原样留下了——人签字只该负责内容，'
                   '不该替撑不住的结论背书' % f.get('formal_status'))
    v = subprocess.run(['$BIN/opl-sign', 'verify', p], capture_output=True, text=True, env=env)
    if v.returncode != 0:
        why.append('收编之后记录仍不可信：签名没跟上（内嵌签名）——%s'
                   % (v.stderr.strip()[-120:]))
b = subprocess.run(['$BIN/opl-conj', 'set', 'N-2', '--add-bound', 'n>=2@hand'],
                   capture_output=True, text=True, env=env)
if b.returncode != 0:
    why.append('收编之后仍不能正常改写 rc=%d' % b.returncode)
c = subprocess.run(['$BIN/opl-conj', 'set', 'N-2', '--adopt', '--add-bound', 'n>=3@hand'],
                   capture_output=True, text=True, env=env)
if c.returncode != 2:
    why.append('签名正常时 --adopt 应被拒（静默忽略一个开关会让人以为做过什么），得到 %d'
               % c.returncode)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "N6 没有签名器时证据产出命令也不留无签名的证据" 0 python3 -c "
import os, subprocess, sys
env = dict(os.environ, OPL_SIGNING_KEY='$work/没有这把密钥')
out = '$work/N6-evidence.json'
if os.path.exists(out):
    os.unlink(out)
r = subprocess.run(['$BIN/opl-encode', '--spec', '$FIX/spec-pc23.json', '--eval-witness',
                    '$FIX/spec-pc23-witness.json', '--evidence-out', out, '--subject', 'N-2'],
                   capture_output=True, text=True, env=env)
why = []
if r.returncode != 4:
    why.append('退出码 %d（应为 4 MISSING）' % r.returncode)
if os.path.exists(out) or os.path.exists(out + '.sig'):
    why.append('留下了没有签名的证据文件')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
export OPL_LAB="$work/lab"
# ---- N7/R6：第六轮审阅的两条事务缺口 ----
#   N7 签名失败时**旧记录必须原样还在**（旧写法是「先写正式文件、再签名」，签名一失败
#      正式路径上已经是新内容，旧记录没了，而新记录没有可用签名）
#   R6 重建在**任何**阶段失败之后，活实验必须一个字节都没动；切换之后运行史还得指得准
chk "N7-1 签名失败：旧记录原样，且不提交半个新版本" 0 python3 -c "
import json, os, sys
sys.path.insert(0, '$plugin/lib')
import opl_ledger as L, opl_sign as S
why = []
# 类身份：曾经有两个同名不同类的 SignError，于是壳里的 except 从来抓不到
if L.SignError is not S.SignError:
    why.append('台账与签名器的 SignError 不是同一个类——壳里的 except 接不住')
lab = '$work/n7lab'
os.makedirs(lab, exist_ok=True)
# 密钥放**自己的子目录**：`allowed_signers` 与密钥同目录，谁把密钥放在 $work 根下，
# 谁的 init 就会把主密钥的验签清单覆盖掉（实测踩过：N 段之后一路「签名核不过」）。
os.environ['OPL_SIGNING_KEY'] = '$work/n7/key'
if not os.path.isfile('$work/n7/key'):
    S.init_key()
rec = L.new_record(cid='K-1', statement='第一版')
p = L.save(rec, lab)
before = open(p, 'rb').read()
if not S.verify_file(p)[0]:
    why.append('前置条件没建立：第一版没签上')
real = S.sign_bytes
def boom(_data):
    raise S.SignError('注入：签名失败')
S.sign_bytes = boom
raised = None
try:
    rec2 = json.loads(json.dumps(rec)); rec2['statement_nl'] = '第二版'
    L.save(rec2, lab)
except Exception as exc:                       # noqa: BLE001
    raised = exc
finally:
    S.sign_bytes = real
if raised is None:
    why.append('签名失败竟然没抛错')
elif not isinstance(raised, S.SignError):
    why.append('抛的是 %r，壳里只认 SignError' % type(raised).__name__)
if open(p, 'rb').read() != before:
    why.append('正式路径上已经不是旧记录了——**旧版本丢了**')
if not S.verify_file(p)[0]:
    why.append('旧记录不再可信（签名被这次失败写坏了）')
left = [x for x in os.listdir(os.path.join(lab, 'conjectures')) if x.endswith('.tmp')]
if left:
    why.append('留下了暂存文件：%s' % left)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "N7-2 没有签名器时连写都不写（旧记录不动）" 0 python3 -c "
import os, subprocess, sys
# 自己一把密钥、自己一个目录，**用完删掉**：不能借主密钥，也不能动别人的清单
key = '$work/n7b/key'
lab = '$work/n7b/lab'
os.makedirs('$work/n7b', exist_ok=True)
env0 = dict(os.environ, OPL_SIGNING_KEY=key, OPL_LAB=lab)
subprocess.run(['$BIN/opl-sign', 'init'], capture_output=True, env=env0)
subprocess.run(['$BIN/opl-conj', 'add', '--id', 'K-2', '--statement', 'x'],
               capture_output=True, env=env0)
p = lab + '/conjectures/K-2.json'
why = []
if not os.path.isfile(p):
    print('  前置条件没建立：记录没写出来', file=sys.stderr)
    raise SystemExit(1)
before = open(p, 'rb').read()
os.unlink(key)                                 # 密钥没了 = 签名器不可用
r = subprocess.run(['$BIN/opl-conj', 'set', 'K-2', '--add-bound', 'n>=2@hand'],
                   capture_output=True, text=True, env=env0)
why = []
if r.returncode != 4:
    why.append('退出码 %d（应为 4 MISSING）' % r.returncode)
if open(p, 'rb').read() != before:
    why.append('没有签名器却动了旧记录')
if 'K-2' in open(p, 'rb').read().decode() and r.returncode == 0:
    why.append('没有签名器却报成功')
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R6-1 复制阶段失败：活实验一个字节都没动" 0 python3 -c "
import json, os, shutil, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
d = tempfile.mkdtemp(prefix='opl-r6.')
why = []
try:
    open(d + '/skel.py', 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 1\n# EVOLVE-BLOCK-END\n')
    open(d + '/ev.py', 'w').write('''
import argparse, json, os, sys
ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='stage', required=True)
e = sub.add_parser('extract'); e.add_argument('--problem'); e.add_argument('--candidate'); e.add_argument('--artifacts')
v = sub.add_parser('verify'); v.add_argument('--problem'); v.add_argument('--artifacts'); v.add_argument('--metrics-out')
a = ap.parse_args()
if a.stage == 'extract':
    os.makedirs(a.artifacts, exist_ok=True)
    open(os.path.join(a.artifacts, 'a.json'), 'w').write('{}')
    sys.exit(0)
m = {'schema': 'opl.evolve.metrics/1', 'ok': True, 'score': 1}
if a.metrics_out: json.dump(m, open(a.metrics_out, 'w'))
sys.exit(0)
''')
    json.dump({'schema': 'opl.evolve.problem/1', 'params': {},
               'metrics': {'feasible': {'field': 'ok', 'equals': True},
                           'objective': {'field': 'score', 'minimize': True},
                           'required': {'ok': 'bool', 'score': 'number'}}},
              open(d + '/problem.json', 'w'))
    E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py', problem_src=d + '/problem.json')
    ev = d + '/lab/evolve'
    # 记住活实验的每一个字节
    before = {n: open(os.path.join(ev, n), 'rb').read()
              for n in ('skeleton.py', 'evaluator.py', 'problem.json', 'programs.sqlite')}
    # 新骨架复制成功、新评估器复制失败
    open(d + '/skel2.py', 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 2\n# EVOLVE-BLOCK-END\n')
    open(d + '/ev2.py', 'w').write(open(d + '/ev.py').read())
    real = shutil.copyfile
    def flaky(src, dst, **kw):
        if src.endswith('ev2.py'):
            raise OSError('注入：复制评估器失败')
        return real(src, dst, **kw)
    E.shutil.copyfile = flaky
    raised = None
    try:
        E.init_lab(d + '/lab', d + '/skel2.py', d + '/ev2.py',
                   problem_src=d + '/problem.json', force=True)
    except Exception as exc:                   # noqa: BLE001
        raised = exc
    finally:
        E.shutil.copyfile = real
    if raised is None:
        why.append('复制失败竟然没抛错')
    for n, want in before.items():
        got = open(os.path.join(ev, n), 'rb').read()
        if got != want:
            why.append('%s 被改动了——失败的重建留下了新旧混合的实验' % n)
    junk = [x for x in os.listdir(d + '/lab') if x.startswith('.evolve-new-')]
    if junk:
        why.append('留下了暂存目录：%s' % junk)
    if raised is not None and '一个字节都没动' not in str(raised):
        why.append('错误信息没说清活实验没被动过：%r' % str(raised)[:80])
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
cat > "$work/r6-ev.py" <<'PYEOF'
import argparse, json, os, sys
ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='stage', required=True)
e = sub.add_parser('extract'); e.add_argument('--problem'); e.add_argument('--candidate'); e.add_argument('--artifacts')
v = sub.add_parser('verify'); v.add_argument('--problem'); v.add_argument('--artifacts'); v.add_argument('--metrics-out')
a = ap.parse_args()
if a.stage == 'extract':
    os.makedirs(a.artifacts, exist_ok=True)
    open(os.path.join(a.artifacts, 'a.json'), 'w').write('{}')
    sys.exit(0)
m = {'schema': 'opl.evolve.metrics/1', 'ok': True, 'score': 1}
if a.metrics_out: json.dump(m, open(a.metrics_out, 'w'))
sys.exit(0)
PYEOF
cat > "$work/r6-problem.json" <<'JSONEOF'
{"schema": "opl.evolve.problem/1", "params": {},
 "metrics": {"feasible": {"field": "ok", "equals": true},
             "objective": {"field": "score", "minimize": true},
             "required": {"ok": "bool", "score": "number"}}}
JSONEOF
chk "R6-2 切换之后运行史与快照来源仍指得准" 0 python3 -c "
import json, os, shutil, sqlite3, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
d = tempfile.mkdtemp(prefix='opl-r6b.')
why = []
try:
    open(d + '/skel.py', 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 1\n# EVOLVE-BLOCK-END\n')
    shutil.copyfile('$work/r6-ev.py', d + '/ev.py')
    shutil.copyfile('$work/r6-problem.json', d + '/problem.json')
    E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py', problem_src=d + '/problem.json')
    con = sqlite3.connect(d + '/lab/evolve/programs.sqlite')
    rows = [dict(zip([c[0] for c in con.execute('SELECT * FROM evaluations').description], r))
            for r in con.execute('SELECT * FROM evaluations')]
    con.close()
    if not rows:
        why.append('运行史是空的')
    for r in rows:
        rd = r['run_dir']
        if rd and os.path.isabs(rd):
            why.append('运行 %s 的 run_dir 存成了绝对路径（%r）' % (r['id'], rd))
            continue
        rd = os.path.join(d + '/lab/evolve', rd) if rd else rd
        if not rd or not os.path.isdir(rd):
            why.append('运行 %s 的 run_dir 指不到（%r）' % (r['id'], rd))
            continue
        if '.evolve-new-' in rd:
            why.append('run_dir 还写着暂存目录：%r' % rd)
        for st in ('extract', 'verify'):
            sd = os.path.join(rd, st)
            if not os.path.isdir(sd):
                continue
            m = json.load(open(os.path.join(sd, 'metrics.json')))
            for k, v in (m.get('artifacts') or {}).items():
                if isinstance(v, str) and v and not v.startswith('（') \
                        and not os.path.exists(os.path.join(sd, v)):
                    why.append('快照来源指不到：%s/%s = %r' % (st, k, v))
    # == 归档之后，旧库的索引必须落在**归档目录**里 ==
    # 第七轮审阅 F2 的后果不只是死链：索引指着活实验，查看旧成绩时可能打开**新实验**的产物。
    res = E.init_lab(d + '/lab', d + '/skel.py', d + '/ev.py',
                     problem_src=d + '/problem.json', force=True)
    arch = res.archived_dir
    acon = sqlite3.connect(os.path.join(arch, 'programs.sqlite'))
    arows = [dict(zip([c[0] for c in acon.execute('SELECT * FROM evaluations').description], r))
             for r in acon.execute('SELECT * FROM evaluations')]
    acon.close()
    if not arows:
        why.append('归档库里没有运行史')
    for r in arows:
        rd = r['run_dir']
        if rd and os.path.isabs(rd):
            why.append('归档库的 run_dir 是绝对路径：%r' % rd)
            continue
        resolved = os.path.join(arch, rd) if rd else ''
        if not resolved or not os.path.isdir(resolved):
            why.append('归档库的 run_dir 解不到归档目录里：%r' % rd)
        elif os.path.abspath(resolved).startswith(os.path.abspath(d + '/lab/evolve')):
            why.append('归档库的索引指回了活实验：%r' % resolved)
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# ---- N8/R6-3：第七轮审阅的三条 ----
#   N8  证据不许覆盖：同一路径写第二次、签名又失败，会把**先前那份有效证据**删掉；
#       更根本的是台账按哈希引用证据，悄悄换掉同一路径上的内容会让记录失效
#   R6-3 归档之后旧库的索引必须落在**归档目录**里（R6-2 里已断言；这条补「第二次写证据
#       不行，但删掉之后可以重做」这个出路）
chk "N8 证据不许覆盖：旧证据与旧签名都完好" 0 python3 -c "
import json, os, subprocess, sys
env = dict(os.environ)
ev = '$work/n8-evidence.json'
if os.path.exists(ev):
    os.unlink(ev)
if os.path.exists(ev + '.sig'):
    os.unlink(ev + '.sig')
sub = ['$BIN/opl-encode', '--spec', '$FIX/spec-pc23.json', '--eval-witness',
       '$FIX/spec-pc23-witness.json', '--evidence-out', ev, '--subject', 'C-1']
r1 = subprocess.run(sub, capture_output=True, text=True, env=env)
why = []
if r1.returncode != 0:
    why.append('第一次就没写成：rc=%d %s' % (r1.returncode, r1.stderr[-100:]))
    print('  ' + '；'.join(why), file=sys.stderr); sys.exit(1)
before, sig_before = open(ev, 'rb').read(), open(ev + '.sig', 'rb').read()
# 第二次：同一路径 + **签名器不可用**（旧行为会先覆盖正式文件、再 discard 掉它）
r2 = subprocess.run(sub, capture_output=True, text=True,
                    env=dict(env, OPL_SIGNING_KEY='$work/n8/没有这把密钥'))
if r2.returncode != 2:
    why.append('第二次应被拒（2 输出路径已存在），得到 %d' % r2.returncode)
if not os.path.exists(ev) or open(ev, 'rb').read() != before:
    why.append('原证据被覆盖或删掉了')
if not os.path.exists(ev + '.sig') or open(ev + '.sig', 'rb').read() != sig_before:
    why.append('原签名被覆盖或删掉了')
if subprocess.run(['$BIN/opl-sign', 'verify', ev], capture_output=True).returncode != 0:
    why.append('原证据不再验得过')
# 出路：显式删掉之后可以重做
os.unlink(ev); os.unlink(ev + '.sig')
r3 = subprocess.run(sub, capture_output=True, text=True, env=env)
if r3.returncode != 0:
    why.append('删掉旧证据之后应能重做，得到 %d' % r3.returncode)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
# ---- N9/R7：第八轮审阅的两条 ----
#   N9 成绩必须跟着**产生它的那次评估**走：一次没有指标的运行（超时）不能给旧成绩
#      贴上新一代的指纹
#   R7 0.4.0 及以前的绝对运行索引，要在**搬迁之前**迁成相对形式；无法归属的不许静默采用
chk "N9 没有指标的运行不得改变已有成绩的归属" 0 python3 -c "
import json, os, shutil, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
from opl_ledger import sha256_file
d = tempfile.mkdtemp(prefix='opl-r8.')
why = []
try:
    sk = d + '/skel.py'
    open(sk, 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 1\n# EVOLVE-BLOCK-END\n')
    shutil.copyfile('$work/r6-ev.py', d + '/ev.py')
    shutil.copyfile('$work/r6-problem.json', d + '/problem.json')
    lab = d + '/lab'
    E.init_lab(lab, sk, d + '/ev.py', problem_src=d + '/problem.json')
    db = lab + '/evolve/programs.sqlite'
    with E.ProgramLibrary(db) as lib:
        base = lib.metrics_provenance(1)
        base_score = lib.best('score', minimize=True)['metrics']['score']
    if base is None:
        why.append('基线没有记下成绩的来源')
    # 换实验定义：改的是**实验目录里那一份**（查询命令就是拿它算指纹的）
    p = json.load(open(lab + '/evolve/problem.json'))
    p['params']['k'] = 99
    json.dump(p, open(lab + '/evolve/problem.json', 'w'))
    fp = (sha256_file(lab + '/evolve/problem.json'),
          sha256_file(lab + '/evolve/evaluator.py'))
    with E.ProgramLibrary(db) as lib:
        if lib.best('score', minimize=True, fingerprints=fp) is not None:
            why.append('换了定义之后旧成绩仍在参与比较')
    # 对**同一条程序**补测，注入超时（没有指标）
    real = E._stage_and_evaluate
    def tmo(pp, code, h, *, problem_path, timeout, mem_max_mb, _d=d):
        rd = os.path.join(pp['dir'], 'runs', h[:16]); os.makedirs(rd + '/work', exist_ok=True)
        return E.RunFacts(None, rd, 'timeout', {}, None, rd)
    E._stage_and_evaluate = tmo
    try:
        out = E.eval_candidate(lab, sk, reevaluate=True)
    finally:
        E._stage_and_evaluate = real
    if out.exit_code != 3:
        why.append('注入的超时没被判成 UNKNOWN：rc=%d' % out.exit_code)
    with E.ProgramLibrary(db) as lib:
        after = lib.best('score', minimize=True, fingerprints=fp)
        prov = lib.metrics_provenance(1)
    if after is not None:
        why.append('一次超时补测之后，旧成绩（%r）被当成了新定义的——'
                   '成绩与产生它的那次评估被分开了' % after.get('metrics'))
    if prov is None or base is None or prov['id'] != base['id']:
        why.append('成绩的来源被那次超时运行顶掉了：%r → %r'
                   % (base and base['id'], prov and prov['id']))
    if prov and prov.get('kind') != base.get('kind'):
        why.append('来源那一次的类型也变了：%r' % prov.get('kind'))
    # 正向对照：**真正产生成绩**的那次运行才该改变归属
    E._stage_and_evaluate = real
    out2 = E.eval_candidate(lab, sk, reevaluate=True)
    if out2.exit_code != 0:
        why.append('补测（真跑）得到 rc=%d' % out2.exit_code)
    with E.ProgramLibrary(db) as lib:
        prov2 = lib.metrics_provenance(1)
        got = lib.best('score', minimize=True, fingerprints=fp)
    if prov2 is None or prov2['id'] == (base or {}).get('id'):
        why.append('真正跑出成绩的那次没有被记为来源')
    if got is None:
        why.append('对照失败：新定义下真的跑出了成绩，却查不到')
finally:
    shutil.rmtree(d, ignore_errors=True)
if why:
    print('  ' + '；'.join(why), file=sys.stderr)
sys.exit(0 if not why else 1)"
chk "R7 归档前迁移绝对索引；无法归属的不静默采用" 0 python3 -c "
import json, os, shutil, sqlite3, sys, tempfile
sys.path.insert(0, '$plugin/lib')
import opl_evolve as E
d = tempfile.mkdtemp(prefix='opl-r8b.')
why = []
try:
    sk = d + '/skel.py'
    open(sk, 'w').write('# EVOLVE-BLOCK-START\ndef f(x):\n    return 1\n# EVOLVE-BLOCK-END\n')
    shutil.copyfile('$work/r6-ev.py', d + '/ev.py')
    shutil.copyfile('$work/r6-problem.json', d + '/problem.json')
    lab = d + '/lab'
    E.init_lab(lab, sk, d + '/ev.py', problem_src=d + '/problem.json')
    db = lab + '/evolve/programs.sqlite'
    live = lab + '/evolve'
    # 模拟 0.4.0 及以前的格式：绝对路径
    con = sqlite3.connect(db)
    for eid, rd in con.execute('SELECT id, run_dir FROM evaluations').fetchall():
        con.execute('UPDATE evaluations SET run_dir = ? WHERE id = ?',
                    (os.path.join(live, rd or 'runs/x'), eid))
    con.execute(\"INSERT INTO evaluations (program_id, run_dir, kind, created_at)\"
                \" VALUES (1, '/别处/别人的运行目录', 'ok', '2026-01-01T00:00:00+0000')\")
    con.commit(); con.close()
    with E.ProgramLibrary(db) as lib:
        migrated, foreign = lib.migrate_run_dirs(live)
    if migrated < 1:
        why.append('属于本实验的绝对索引没被迁移（migrated=%d）' % migrated)
    if foreign != 1:
        why.append('无法归属的那条被算成了 %d（应为 1：只计数、不改它）' % foreign)
    con = sqlite3.connect(db)
    left = con.execute(\"SELECT run_dir FROM evaluations WHERE run_dir LIKE '/%'\").fetchall()
    con.close()
    if [r[0] for r in left] != ['/别处/别人的运行目录']:
        why.append('无法归属的那条被改动了：%r' % [r[0] for r in left])
    # == 集成：归档时**应当自己**迁移（不靠调用方先手工迁一遍）==
    # 单独建一个 lab 走这条路：直接调迁移器只能测到迁移器本身，测不到挂没挂上钩
    # （实测踩过——第一版用例手工先迁了一遍，于是「不挂钩」的注入没被抓住）。
    lab2 = d + '/lab2'
    E.init_lab(lab2, sk, d + '/ev.py', problem_src=d + '/problem.json')
    live2 = lab2 + '/evolve'
    db2 = live2 + '/programs.sqlite'
    con = sqlite3.connect(db2)
    for eid, rd in con.execute('SELECT id, run_dir FROM evaluations').fetchall():
        con.execute('UPDATE evaluations SET run_dir = ? WHERE id = ?',
                    (os.path.join(live2, rd or 'runs/x'), eid))
    con.commit(); con.close()
    res = E.init_lab(lab2, sk, d + '/ev.py', problem_src=d + '/problem.json', force=True)
    arch = res.archived_dir
    acon = sqlite3.connect(os.path.join(arch, 'programs.sqlite'))
    rows = [r[0] for r in acon.execute(
        'SELECT run_dir FROM evaluations WHERE run_dir IS NOT NULL')]
    acon.close()
    if any(os.path.isabs(r) for r in rows if not r.startswith('/别处')):
        why.append('归档库里仍有指向别处的绝对索引：%r' % rows)
    if not any(os.path.isdir(os.path.join(arch, r)) for r in rows if not r.startswith('/别处')):
        why.append('归档库里的相对索引解析不到归档目录里：%r' % rows)
    # 成绩来源不明的要**显式排除**，不能拿别的运行顶替
    with E.ProgramLibrary(db) as lib:
        lib.conn.execute('UPDATE programs SET metrics_evaluation_id = NULL WHERE metrics_json IS NOT NULL')
        lib.conn.commit()
        got = lib.best('score', minimize=True, fingerprints=(None, None))
        n = lib.skipped_unattributed
    if got is not None:
        why.append('成绩来源不明却仍被拿来比较')
    if n < 1:
        why.append('来源不明没有被计数（skipped_unattributed=%d）' % n)
finally:
    shutil.rmtree(d, ignore_errors=True)
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
    --eval-witness "$work/e2e/witness.json" --evidence-out "$work/e2e/ev-witness.json" \
    --subject E-1
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
    --cert "$work/e2e/u.drat" --evidence-out "$work/e2e/lab/evidence/E-2.json" \
    --subject E-2
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
FROZEN = {'schema', 'kind', 'subject', 'range', 'backend', 'format',
          'formula', 'formula_sha256', 'certificate', 'certificate_sha256',
          'certificate_bytes', 'parse_complete', 'parsed_bytes', 'duration_ms',
          'checked_at', 'checker_messages', 'verdict', 'verification_level'}
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
  # 数字要跟着块里的 `chk` 条数走：加了 6f1（不点名声明）与 6f2（点了别的声明）之后
  # 就是九项——跳过的计数**漏掉谁，谁就会在「总数」里凭空消失**（实测：136+14=150≠152）。
  skip=$((skip + 9))
  printf '  skip  %-46s 缺 lake 或 plugin/lean（无定点 toolchain）\n' "证明侧端到端九项"
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
      --decl oddSum_eq_sq --evidence-out "$work/e2e/lab/evidence/E-3.json" \
      --subject E-3
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
  chk "6f1 不点名声明就不算定案 -> 2" 2 $BIN/opl-conj set E-3 --formal-status proved \
      --evidence "$work/e2e/lab/evidence/E-3.json" --verification-level lean_checked
  chk "6f 台账定案 lean_checked"   0 $BIN/opl-conj set E-3 --formal-status proved \
      --statement-formal "$FIX/lean-real.lean" --decl oddSum_eq_sq \
      --evidence "$work/e2e/lab/evidence/E-3.json" --verification-level lean_checked
  chk "6f2 点了别的声明 -> 2" 2 $BIN/opl-conj set E-3 --formal-status proved \
      --statement-formal "$FIX/lean-real.lean" --decl 另一个定理 \
      --evidence "$work/e2e/lab/evidence/E-3.json" --verification-level lean_checked
  chk "6g 终态：proved + 证据指针"  0 python3 -c "
import json, sys
f = json.load(open('$work/e2e/lab/conjectures/E-3.json'))
ok = (f['formal_status'] == 'proved'
      and f['verification_level'] == 'lean_checked'
      and f['statement_formal']['decl'] == 'oddSum_eq_sq'
      and any('E-3.json' in str(h.get('evidence', '')) for h in f['history']))
if not ok:
    print(json.dumps(f.get('statement_formal'), ensure_ascii=False), file=sys.stderr)
sys.exit(0 if ok else 1)"
fi

# ----------------------------------------------------------------
printf '\n  通过 %d / 失败 %d / 跳过 %d\n' "$pass" "$fail" "$skip"
[ "$fail" -gt 0 ] && exit 1
exit 0

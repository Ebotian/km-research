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
chk "取不存在的记录"         5 $BIN/opl-conj get R-404
chk "list 无匹配"            5 $BIN/opl-conj list --status proved

# ---------------------------------------------------------------- 能力探测
echo "capabilities —— 必需层"
chk "必需层齐全"             0 $BIN/opl-capabilities --layer required --quiet

# ---------------------------------------------------------------- 编码
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

# ----------------------------------------------------------------
printf '\n  通过 %d / 失败 %d\n' "$pass" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0

#!/usr/bin/env bash
# 验证压缩包：打包 -> 解压到干净目录 -> 在那里跑通端到端五步。
#
# 为什么必须解压后再跑：包里的路径与仓库里不同，第三方二进制靠
# `bin_dirs()` 从插件根解析（不是 PATH，也不是 OPL_BINDIR）。只有解压到别处
# 跑一遍，才能证明这条解析链成立、软链已换成真文件、运行时夹具没漏。
#
# 用法：verify-zip.sh [--with-carcara]

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
cd "$plugin"

zip=$(./scripts/build-zip.sh "$@" | sed -n 's/^  产物：//p')
[ -f "$zip" ] || { echo "打包失败，没拿到 zip" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/opl-verifyzip.XXXXXX")
trap 'rm -rf "$work"' EXIT
unzip -q "$zip" -d "$work"
# 顶层目录名取自 zip 内部（是插件名），不是 zip 文件名——两者不同：
# zip 叫 open-problem-lab-0.1.0.zip，内部根目录是 open-problem-lab/。
top=$(unzip -Z1 "$zip" | head -1 | cut -d/ -f1)
root="$work/$top"
[ -d "$root" ] || { echo "解压后找不到顶层目录 $top" >&2; exit 1; }

pass=0; fail=0
chk() {
  local name=$1 want=$2; shift 2
  "$@" >"$work/out" 2>"$work/err"; local rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass+1)); printf '  ok   %-40s %s\n' "$name" "$rc"
  else
    fail=$((fail+1)); printf '  FAIL %-40s %s (期望 %s)\n' "$name" "$rc" "$want"
    head -3 "$work/err" | sed 's/^/         /'
  fi
}

echo "解压后结构"
chk "清单在根"        0 test -f "$root/kimi.plugin.json"
chk "两个技能都在"    0 test -f "$root/skills/opl-entry/SKILL.md" -a -f "$root/skills/opl-refute/SKILL.md"
chk "无残留软链"      0 test -z "$(find "$root" -type l)"
chk "运行时夹具在位"  0 test -f "$root/tests/fixtures/tiny.clrat"

echo "包内第三方后端（不设 OPL_BINDIR，靠插件根解析）"
for b in drat-trim lrat-check; do
  chk "找得到 $b" 0 test -x "$root/bin/third-party/$b"
done

echo "干净目录里的端到端五步"
export OPL_LAB="$work/lab"
F="$root/tests/fixtures"
chk "1 登记"          0 "$root/bin/opl-conj" add --id Z-1 --title "PC(2,3)" \
    --statement "3 个洞容得下 2 只鸽子" --source "$F/spec-pc23.json"
chk "2 编码一致"      0 "$root/bin/opl-encode" --spec "$F/spec-pc23.json" --check-consistency
chk "3 搜索出见证"    0 "$root/bin/opl-search" --spec "$F/spec-pc23.json" \
    --cnf-out "$work/m.cnf" --witness-out "$work/w.json"
chk "4 独立复核"      0 "$root/bin/opl-encode" --spec "$F/spec-pc23.json" --eval-witness "$work/w.json"
chk "5 定案"          0 "$root/bin/opl-conj" set Z-1 --formal-status refuted \
    --evidence "$work/w.json" --verification-level exact_certificate
chk "unsat 侧出证明"  0 "$root/bin/opl-search" --spec "$F/spec-pc43.json" \
    --cnf-out "$work/u.cnf" --proof-out "$work/u.drat"
chk "包内 drat-trim 复核" 0 "$root/bin/opl-certcheck" --formula "$work/u.cnf" \
    --cert "$work/u.drat" --evidence-out "$work/evidence.json"
chk "证据记录字段正确" 0 python3 -c "
import json, sys
d = json.load(open('$work/evidence.json'))
ok = (d['schema'] == 'opl.evidence/1' and d['verdict'] == 'VERIFIED'
      and d['verification_level'] == 'exact_certificate' and d['backend'] == 'drat-trim')
sys.exit(0 if ok else 1)"

printf '\n  通过 %d / 失败 %d\n' "$pass" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0

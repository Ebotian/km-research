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
# 跳过与通过是两件事：Lean 缺失时那几项*没跑*，不该显得像通过。
skip=0
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
# 反向检查：清单里列出的每个技能都必须在包里。漏列或漏拷一个，它在平台上会静默
# 不加载——正向检查（磁盘上有的都在清单里）抓不到「包比清单少」这种情况。
chk "清单列出的技能全在包里" 0 python3 -c "
import json, os, sys
d = json.load(open('$root/kimi.plugin.json'))
miss = [s for s in d['skills']
        if not os.path.isfile(os.path.join('$root', s.lstrip('./'), 'SKILL.md'))]
if miss:
    print('  漏包：', ', '.join(miss), file=sys.stderr)
sys.exit(0 if not miss else 1)"
# 运行时库：这三个是下沉重构后新增的，bin/ 里的命令全都依赖它们。
for m in opl_lean opl_certcheck opl_probe opl_ledger opl_sandbox; do
  chk "lib/$m.py 在包里" 0 test -f "$root/lib/$m.py"
done
chk "opl-leancheck 在包里且可执行" 0 test -x "$root/bin/opl-leancheck"
chk "无残留软链"      0 test -z "$(find "$root" -type l)"
chk "运行时夹具在位"  0 test -f "$root/tests/fixtures/tiny.clrat"
chk "证明侧夹具在位"  0 test -f "$root/tests/fixtures/lean-real.lean"
chk "第三方许可声明在位" 0 test -f "$root/THIRD-PARTY-NOTICES.md"
chk "声明含 drat-trim 条款" 0 grep -qF "Permission is hereby granted, free of charge" "$root/THIRD-PARTY-NOTICES.md"
chk "声明含 cake_lpr 条款" 0 grep -qF "CakeML is free software" "$root/THIRD-PARTY-NOTICES.md"

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

# ---------------------------------------------------------------- Lean 路径
# 包里**故意不带**那 7 GB 外部 Lean 项目（build-zip.sh 会拒绝把它打进去），
# 所以包内的 Lean 路径分两种情形，两种都必须验：
#
#   缺 Lean 时：如实报缺失（MISSING(4)）或拒绝运行（USAGE(2)），**绝不伪造 0**。
#              这是这个项目最想防的那类错误——把「没跑」说成「跑通了」。
#   有 Lean 时：用 OPL_LEAN_PROJECT 指向定点的项目，在*解压目录里*把证明侧
#              链路完整跑一遍，终态落在 lean_checked。
echo "Lean 路径（包内无 lean/，按设计）"
chk "包内确实没有 lean/" 0 test ! -e "$root/lean"
# 没有项目 -> 拒绝运行。期望 2（无定点项目）或 4（lake 都没装）；两种都算如实降级，
# 唯一不可接受的是 0。哪一档取决于本机装没装 lake，所以不能写死一个数。
"$root/bin/opl-leancheck" --file "$F/lean-real.lean" --decl oddSum_eq_sq \
    --project "$work/nope" >/dev/null 2>&1
lc=$?
chk "无 Lean 项目 -> 2/4（绝不伪造 0）" 0 sh -c '[ "$1" = 2 ] || [ "$1" = 4 ]' _ "$lc"
# 没有 lake -> 必须报 4（后端缺失）。清掉 PATH 里的 elan 才能测出这一档。
chk "无 lake -> 4（MISSING）" 4 env PATH=/usr/bin:/bin "$root/bin/opl-leancheck" \
    --file "$F/lean-real.lean" --decl oddSum_eq_sq --project "$work/nope"

# 正例：环境里有定点项目时才跑。跳过计入 skip，不算通过。
lean_proj=${OPL_LEAN_PROJECT:-$plugin/lean}
if command -v lake >/dev/null 2>&1 && [ -f "$lean_proj/lean-toolchain" ]; then
  export OPL_LEAN_PROJECT="$(readlink -f "$lean_proj")"
  echo "  （Lean 可用：$OPL_LEAN_PROJECT）"
  chk "证明检查 + 证据记录" 0 "$root/bin/opl-leancheck" --file "$F/lean-real.lean" \
      --decl oddSum_eq_sq --evidence-out "$work/lab/evidence/Z-3.json"
  chk "证据记录判为 lean_checked" 0 python3 -c "
import json, sys
d = json.load(open('$work/lab/evidence/Z-3.json'))
ok = (d['verdict'] == 'proved' and d['verification_level'] == 'lean_checked'
      and d['sorries'] == [] and d['errors'] == []
      and set(d['axioms']['oddSum_eq_sq']) <= set(d['axiom_whitelist']))
sys.exit(0 if ok else 1)"
  chk "台账登记真命题" 0 "$root/bin/opl-conj" add --id Z-3 \
      --title "前 n 个奇数之和等于 n²" --statement "1+3+…+(2n-1) = n²" \
      --source "$F/lean-real.lean"
  chk "台账定案 lean_checked" 0 "$root/bin/opl-conj" set Z-3 --formal-status proved \
      --evidence "$work/lab/evidence/Z-3.json" --verification-level lean_checked
  chk "终态 proved + lean_checked" 0 python3 -c "
import json, sys
f = json.load(open('$work/lab/conjectures/Z-3.json'))
sys.exit(0 if (f['formal_status'] == 'proved'
               and f['verification_level'] == 'lean_checked') else 1)"
else
  skip=$((skip + 5))
  printf '  skip  %-40s 缺 lake 或定点项目\n' "包内 Lean 正例五项"
fi

printf '\n  通过 %d / 失败 %d / 跳过 %d\n' "$pass" "$fail" "$skip"
[ "$fail" -gt 0 ] && exit 1
exit 0

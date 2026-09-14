#!/usr/bin/env bash
# 类型检查：对 plugin/lib/ 求三个独立检查器的交集。
#
# 为什么跑三个而不是挑一个 —— 实测（2026-09-14）它们在「未注解函数」上结论不同：
#   run() 还没有返回注解时，把三元组按四元组解包：
#     pyright  1 error   ← 会推断未注解函数的返回类型
#     mypy     0 error   ← 未类型化函数，调用结果被当作 Any
#     ty       0 error
#   补上 `-> tuple[int | None, bytes, bytes]` 之后三个都报错。
# 单一检查器会漏。这与本项目「结论须经独立验证器复核」是同一条纪律。
#
# 检查器是 dev 依赖：不进插件、不进压缩包。缺失时警告并跳过；加 --require-all
# 改为硬失败（CI 上应当这样用）。
#
# 用法：typecheck.sh [--require-all]

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
cd "$plugin" || { echo "无法进入 $plugin" >&2; exit 2; }

require_all=0
[ "${1:-}" = "--require-all" ] && require_all=1

targets=(lib)
ran=0
missing=0
fails=0

# 从各检查器输出里取错误数。取不到即 0（干净时它们不打印计数行）。
count_errors() {
  case "$1" in
    mypy)    sed -n 's/^Found \([0-9]\+\) error.*/\1/p' | head -1 ;;
    pyright) sed -n 's/^\([0-9]\+\) error.*/\1/p' | head -1 ;;
    ty)      grep -cE '^error\[' ;;
  esac
}

report() {
  local name=$1 out=$2 n
  n=$(printf '%s' "$out" | count_errors "$name")
  n=${n:-0}
  ran=$((ran + 1))
  if [ "$n" -gt 0 ]; then
    printf '  %-8s %s 个错误\n' "$name" "$n" >&2
    printf '%s\n' "$out" | grep -E 'error' | head -8 | sed 's/^/           /' >&2
    fails=$((fails + 1))
  else
    printf '  %-8s 0 错误\n' "$name" >&2
  fi
}

probe() {
  local name=$1
  shift
  if ! command -v "$name" >/dev/null 2>&1; then
    printf '  %-8s 跳过（未安装）\n' "$name" >&2
    missing=$((missing + 1))
    return 0
  fi
  report "$name" "$("$@" 2>&1)"
}

printf '类型检查（%s）\n' "${targets[*]}" >&2
probe mypy    mypy "${targets[@]}"
probe pyright pyright "${targets[@]}"
probe ty      ty check "${targets[@]}"

printf '  已跑 %d 个检查器，失败 %d，缺失 %d\n' "$ran" "$fails" "$missing" >&2

if [ "$missing" -gt 0 ] && [ "$require_all" = 1 ]; then
  echo "  有检查器未安装，--require-all 下视为失败" >&2
  exit 1
fi
[ "$fails" -gt 0 ] && exit 1
exit 0

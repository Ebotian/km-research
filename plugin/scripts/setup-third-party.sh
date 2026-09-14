#!/usr/bin/env bash
# 把第三方证明工具装进 plugin/bin/third-party/。
#
# 为什么这些二进制不进版本控制：它们是别的项目的构建产物，体积与来源都不该由本
# 仓库代管（cake_lpr 单文件 560 KB，carcara 编译后 30 MB）。仓库里只留「怎么把
# 它造出来」——这个脚本。缺了它们插件仍能跑，只是能力探测会如实报 not_found，
# 需要证明复核的路径会返回 MISSING(4) 而不是给出结论。
#
# 用法：setup-third-party.sh [--dir WORKDIR] [--with-carcara]
#   默认在 ~/Downloads 下克隆与构建。

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
target="$(dirname "$here")/bin/third-party"
work="$HOME/Downloads"
with_carcara=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) shift; work=$1 ;;
    --with-carcara) with_carcara=1 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$target"
ok=0; skipped=0
say() { printf '  %-14s %s\n' "$1" "$2"; }

# 装一个工具。目标已是同一文件时要早退——本机可能留着指向源的软链，
# 直接 cp 会报 "are the same file" 并让状态误判成失败。
install_tool() {
  local src=$1 dst=$2
  [ -x "$src" ] || return 1
  if [ -e "$dst" ] && [ "$src" -ef "$dst" ]; then
    say "$(basename "$dst")" "ok（已是同一文件，无需复制）"
    return 0
  fi
  cp -p "$src" "$dst"
}

# ---------------------------------------------------------------- drat-trim 系
# 上游 Makefile 用 `-std=c99`，而那会置 `__STRICT_ANSI__`，glibc 于是隐藏
# `getc_unlocked`；GCC 14 起隐式函数声明是硬错误，所以原样 `make` 编译不过。
# 补 `-D_DEFAULT_SOURCE` 即可（保留 `-std=c99`）。另注意上游的 `FLAGS` 变量只被
# 三个目标使用，`drat-trim` 与 `gapless` 的配方是硬编码的——只改 `FLAGS` 不够。
src="$work/drat-trim"
if [ ! -d "$src" ]; then
  echo "克隆 drat-trim…"
  git clone --depth 1 https://github.com/marijnheule/drat-trim "$src" || {
    say drat-trim "克隆失败（无网络？）"; skipped=$((skipped+1)); }
fi
if [ -d "$src" ]; then
  ( cd "$src"
    for t in drat-trim gapless; do
      gcc "$t.c" -std=c99 -D_DEFAULT_SOURCE -O2 -o "$t" || exit 1
    done
    for t in lrat-check compress decompress; do
      gcc "$t.c" -std=c99 -D_DEFAULT_SOURCE -DLONGTYPE -O2 -o "$t" || exit 1
    done ) || { say drat-trim "编译失败"; skipped=$((skipped+1)); }
  # decompress 已知有上游 bug（read_lit 内遗留 printf，输出不是合法 LRAT），不装。
  for b in drat-trim lrat-check compress gapless; do
    install_tool "$src/$b" "$target/$b" && ok=$((ok+1))
  done
  say decompress "跳过（上游有 bug，装了也是坏的）"
fi

# ---------------------------------------------------------------- cake_lpr
# 这个不需要 CakeML 工具链：仓库自带预编译的 cake_lpr.S，make 只做 gcc 链接。
src="$work/cake_lpr"
if [ ! -d "$src" ]; then
  echo "克隆 cake_lpr…"
  git clone --depth 1 https://github.com/tanyongkiam/cake_lpr "$src" || {
    say cake_lpr "克隆失败"; skipped=$((skipped+1)); }
fi
if [ -d "$src" ]; then
  ( cd "$src" && make ) >/dev/null 2>&1
  install_tool "$src/cake_lpr" "$target/cake_lpr" && ok=$((ok+1)) \
    || { say cake_lpr "构建失败（需要 gcc）"; skipped=$((skipped+1)); }
fi

# ---------------------------------------------------------------- carcara（可选）
# 30 MB，只服务 Alethe 格式（SMT 侧），默认不装。
if [ "$with_carcara" = 1 ]; then
  src="$work/carcara"
  if [ ! -d "$src" ]; then
    echo "克隆 carcara…"
    git clone --depth 1 https://github.com/ufmg-smite/carcara "$src" || true
  fi
  if [ -d "$src" ]; then
    ( cd "$src" && cargo build --release ) >/dev/null 2>&1 \
      && cp -p "$src/target/release/carcara" "$target/carcara" \
      && say carcara "ok" && ok=$((ok+1)) \
      || { say carcara "构建失败（需要 cargo 1.93+）"; skipped=$((skipped+1)); }
  fi
else
  say carcara "跳过（30 MB，只服务 Alethe；--with-carcara 可装）"
fi

# ---------------------------------------------------------------- Lean 项目
# 插件需要一个*定点 toolchain* 的 Lean 项目：elan 的 default_toolchain = "stable"
# 会让每次 lean/lake 调用都联网解析版本（实测每次数秒且随机，定点后 0.02 秒）。
# 这里只检查，不替你造——那需要几 GB 的 Mathlib 缓存下载。
lean_link="$(dirname "$here")/lean"
if [ -f "$lean_link/lean-toolchain" ]; then
  say "lean 项目" "ok（$(cat "$lean_link/lean-toolchain")）"
elif [ -L "$lean_link" ] || [ -e "$lean_link" ]; then
  say "lean 项目" "存在但无 lean-toolchain —— 未定点，调用会变慢且不稳定"
else
  say "lean 项目" "未接。若要 Lean 路径：建一个含 lean-toolchain 的项目，"
  echo "                 再 ln -s <该项目> $lean_link"
fi

# ---------------------------------------------------------------- 自检
echo
echo "自检："
if [ -x "$target/drat-trim" ]; then
  fix="$(dirname "$here")/tests/fixtures"
  if [ -f "$fix/uuf-100-1.cnf" ]; then
    # drat-trim 用 `\r` 覆盖进度行，判决行前面会带 `\r`——必须先归一化，
    # 否则 `^s ` 匹配不到（这个坑在会话早期踩过一次）。
    out=$("$target/drat-trim" "$fix/uuf-100-1.cnf" "$fix/uuf-100-1.drat" 2>&1 \
          | tr '\r' '\n' | grep '^s ' | head -1)
    say drat-trim "复核自带夹具 -> ${out:-无判决}"
  fi
fi
echo
echo "  装好 $ok 个，跳过/失败 $skipped 个。产物在 $target"
echo "  运行 plugin/scripts/regress.sh 可验证整条链。"

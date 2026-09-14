#!/usr/bin/env bash
# 打出自包含、可安装的插件压缩包。
#
# 三处必须特意处理的，漏一个包就是废的：
#
# 1. `bin/third-party/` 里是*符号链接*，指向本机的 ~/Downloads/…。zip 会把它们
#    存成链接，解压到别的机器就全断。必须换成真文件。
# 2. `lean/` 是指向 7 GB 外部项目的符号链接（已归档的 emsx/leanproof）。绝不能进包。
# 3. `tests/fixtures/` 是*运行时*依赖而非测试专用：opl-capabilities 要读
#    tiny.clrat 才能判定 decompress 是「存在但坏了」，opl-certcheck 的回归也用它。
#    漏掉它，能力探测会静默退化。
#
# 用法：build-zip.sh [--with-carcara] [--out DIR]
#   --with-carcara  把 carcara（约 30 MB）也打进去。默认不带：它只服务 Alethe
#                   格式，属 M2 之外；不带时 opl-certcheck 会如实报缺失并降级，
#                   那正是能力探测的设计行为。

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
cd "$plugin"

with_carcara=0
out_dir="$plugin/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-carcara) with_carcara=1 ;;
    --out) shift; out_dir=$1 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

# M1–M2 真正需要的两个后端，加上同一构建里另两个小工具；cake_lpr 也带（572 KB，
# 它把 LPR 路径也补上，信任等级高于未经验证的 C 程序）。
third_party=(drat-trim lrat-check compress gapless cake_lpr)
[ "$with_carcara" = 1 ] && third_party+=(carcara)

ver=$(python3 -c "import json,sys; print(json.load(open('kimi.plugin.json'))['version'])")
name=$(python3 -c "import json,sys; print(json.load(open('kimi.plugin.json'))['name'])")
stage=$(mktemp -d "${TMPDIR:-/tmp}/opl-zip.XXXXXX")
trap 'rm -rf "$stage"' EXIT
root="$stage/$name"
mkdir -p "$root"

echo "打包 $name v$ver -> $out_dir"

# ---- 随包文件（不含 bin/third-party 与 lean）
for item in kimi.plugin.json skills lib tests scripts hooks; do
  [ -e "$item" ] || continue
  cp -r "$item" "$root/"
  echo "  + $item"
done
find "$root" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# ---- 第三方二进制：把符号链接换成真文件
mkdir -p "$root/bin/third-party"
for b in "${third_party[@]}"; do
  src="$plugin/bin/third-party/$b"
  if [ ! -e "$src" ]; then
    echo "  ! 缺 $b，跳过" >&2
    continue
  fi
  real=$(readlink -f "$src")          # 跟随软链取真文件
  cp -p "$real" "$root/bin/third-party/$b"
  printf '  + bin/third-party/%-12s %s\n' "$b" "$(du -h "$real" | cut -f1)"
done

# ---- 我们自己的命令
mkdir -p "$root/bin"
for f in "$plugin"/bin/opl-*; do
  cp -p "$f" "$root/bin/"
done
chmod +x "$root"/bin/opl-* "$root"/bin/third-party/* "$root"/scripts/*.sh "$root"/hooks/* 2>/dev/null || true

# ---- 自检：包里不能有软链，不能有 lean
bad_links=$(find "$root" -type l | wc -l)
if [ "$bad_links" -ne 0 ]; then
  echo "打包失败：包里仍有 $bad_links 个符号链接（解压后会断）" >&2
  find "$root" -type l >&2
  exit 1
fi
if [ -e "$root/lean" ]; then
  echo "打包失败：lean/ 不该进包（指向 7 GB 外部项目）" >&2
  exit 1
fi
# 运行时代理依赖检查：能力探测要读它
if [ ! -f "$root/tests/fixtures/tiny.clrat" ]; then
  echo "打包失败：缺 tests/fixtures/tiny.clrat —— 能力探测会静默退化" >&2
  exit 1
fi

mkdir -p "$out_dir"
zip_path="$out_dir/${name}-${ver}.zip"
rm -f "$zip_path"
(cd "$stage" && zip -qr "$zip_path" "$name")
echo
echo "  产物：$zip_path"
echo "  大小：$(du -h "$zip_path" | cut -f1)"
echo "  条目：$(unzip -l "$zip_path" | tail -1 | awk '{print $2}')"

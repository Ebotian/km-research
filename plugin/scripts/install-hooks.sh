#!/usr/bin/env bash
# 把 plugin/hooks/ 装成 git 的钩子目录。
#
# 用 core.hooksPath 指向版本控制内的目录，而不是往 .git/hooks/ 里拷文件——
# 后者不受版本控制，改了什么没人看得见，也没法在 review 里讨论。
#
# 注意：core.hooksPath 存在 .git/config（本地，不随 clone 传播），
# 所以换一台机器或重新 clone 之后要再跑一次这个脚本。
#
# 用法：install-hooks.sh [--uninstall]

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
root=$(git -C "$plugin" rev-parse --show-toplevel 2>/dev/null) || {
  echo "不在 git 仓库里，无法安装钩子" >&2
  exit 2
}
rel=$(realpath --relative-to="$root" "$plugin/hooks")

if [ "${1:-}" = "--uninstall" ]; then
  git -C "$root" config --unset core.hooksPath || true
  echo "已卸载（core.hooksPath 恢复为默认的 .git/hooks）"
  exit 0
fi

chmod +x "$plugin/hooks/pre-commit" "$plugin"/scripts/*.sh
git -C "$root" config core.hooksPath "$rel"
echo "已安装：core.hooksPath = $rel"
echo "钩子文件："
ls -1 "$plugin/hooks" | sed 's/^/  /'
echo "绕过单次提交：git commit --no-verify"

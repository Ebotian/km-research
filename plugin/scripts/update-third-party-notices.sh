#!/usr/bin/env bash
# 重新生成 plugin/THIRD-PARTY-NOTICES.md。
#
# 为什么要有这个脚本，而不是手抄一份：压缩包内含第三方的二进制，而
# drat-trim（MIT）与 cake_lpr（CakeML 的 BSD-3 条款式许可）都要求*随二进制
# 分发时附上版权声明与免责声明*。手抄条款容易抄错——那等于没声明。
# 这里从上游源码目录原样拼入，并在末尾做一次一致性校对。
#
# 用法：update-third-party-notices.sh [--dir WORKDIR]
#   WORKDIR 默认 ~/Downloads（与 setup-third-party.sh 一致）

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
work="$HOME/Downloads"
[ "${1:-}" = "--dir" ] && work=$2

out="$plugin/THIRD-PARTY-NOTICES.md"
drat="$work/drat-trim/LICENSE"
cake="$work/cake_lpr/LICENSE"

missing=0
for f in "$drat" "$cake"; do
  [ -f "$f" ] || { echo "缺上游许可文件：$f（先跑 setup-third-party.sh）" >&2; missing=1; }
done
[ "$missing" = 1 ] && exit 1

{
cat <<'HEADER'
# 第三方许可声明

本插件的压缩包内含以下第三方二进制。它们**不在本仓库的版本控制里**
（由 `scripts/setup-third-party.sh` 克隆并构建），但会随 `scripts/build-zip.sh`
的产物一起分发，因此其许可要求随附声明。

各家的许可正文由本文件从上游源码目录**原样拼入**，不做转录——以避免抄错条款。
本文件由 `scripts/update-third-party-notices.sh` 生成。

---

## drat-trim / lrat-check / compress / gapless

上游：<https://github.com/marijnheule/drat-trim>
用于 DRAT 与 LRAT 证书的独立复核。

```text
HEADER
cat "$drat"
cat <<'MID'

```

---

## cake_lpr

上游：<https://github.com/tanyongkiam/cake_lpr>
用于 LPR 证书的复核。由 CakeML 编译，正确性经形式化验证。

```text
MID
cat "$cake"
cat <<'TAIL'

```

---

## carcara（可选，默认不打进包）

上游：<https://github.com/ufmg-smite/carcara>
用于 Alethe 证书的复核。许可为 Apache-2.0，全文见上游仓库的 `LICENSE`。

```text
Copyright 2022-2024 by the Carcara authors.
Licensed under the Apache License, Version 2.0.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
```

---

## 未随包分发的部分

SAT / CP / SMT 求解器（[PySAT](https://github.com/pysathq/pysat)、
[OR-Tools](https://github.com/google/or-tools)、[cvc5](https://github.com/cvc5/cvc5)）
以 Python 依赖形式安装在使用方的环境里，不随本包分发。
TAIL
} > "$out"

# 校对：关键条款句必须一字不差地出现，否则说明上游许可换了版本
fail=0
check() {
  if ! grep -qF "$1" "$out"; then
    echo "  校对失败：找不到「$1」——上游许可可能已变更，请人工过目" >&2
    fail=1
  fi
}
check "Permission is hereby granted, free of charge"
check "CakeML is free software"
echo "  已生成 $out（$(wc -l < "$out") 行）"
[ "$fail" = 1 ] && exit 1
exit 0

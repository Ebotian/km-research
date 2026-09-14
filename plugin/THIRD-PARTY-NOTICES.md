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
Copyright (c) 2014 Marijn Heule and Nathan Wetzler, The University of Texas at Austin.
Copyright (c) 2015-2016 Marijn Heule, The University of Texas at Austin.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

```

---

## cake_lpr

上游：<https://github.com/tanyongkiam/cake_lpr>
用于 LPR 证书的复核。由 CakeML 编译，正确性经形式化验证。

```text
cake_lpr Copyright Notice, License, and Disclaimer.

Copyright 2020-2023 by Marijn Heule, Magnus Myreen, and Yong Kiam Tan.

All rights reserved.

This binary release is subject to the CakeML's copyright notice, license, and
disclaimer, which is reproduced below.

CakeML Copyright Notice, License, and Disclaimer.

Copyright 2013-2023 by Anthony Fox, Google LLC, Ramana Kumar, Magnus Myreen,
Michael Norrish, Scott Owens, Yong Kiam Tan, and other contributors listed
at https://cakeml.org

All rights reserved.

CakeML is free software. Redistribution and use in source and binary forms,
with or without modification, are permitted provided that the following
conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.

    * The names of the copyright holders and contributors may not be
      used to endorse or promote products derived from this software without
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS''
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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

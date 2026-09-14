# kimi-research

为 [Kimi Code](https://moonshotai.github.io/kimi-code/) 制作的开放问题研究插件，代号 **open-problem-lab**。

它的目标很窄：**把「求解器说 UNSAT」变成可被第三方复核的结论**。
为此它不追求功能多，而追求结论可信——判决走退出码，证据落盘，
缺验证器时硬失败。

---

## 为什么需要这么一套东西

调研 24 个专题后，这类工具的失效模式反复落在三处（详见 `doc/sections/`）：

- **形式化鸿沟**：自动形式化的编译率会系统性高估语义忠实度——陈述自动形式化的
  语义正确率约 76%，而「Lean 编译通过」看不出那 24%。
- **验证器缺位**：[AI Scientist](https://github.com/SakanaAI/AI-Scientist) v1 的
  复现研究观察到 42% 实验因编码错误失败、多篇生成论文含幻觉数值。
- **伪报成功**：[Erdős Problems](https://www.erdosproblems.com/) 的公开案例里，
  某次「AI 自主解决」经复核降级为独立重发现；另一次「解决 10 个问题」经查是误报，
  因为站点的 `open` 标签不保证最新。

三者的公共对策是同一条：**让独立验证器对结论拥有否决权**。

## 核心契约：判决走退出码

所有命令共用一套约定。这不是风格偏好——它让最关键的一类错误在**数值上**无法发生：

| 码 | 判决 | 含义 |
|---|---|---|
| `0` | `PASS` | 断言成立，且已被独立复核 |
| `1` | `REJECT` | 断言被推翻：找到见证，或证书被判定无效 |
| `2` | `USAGE` | 参数、规格或输入有错 |
| `3` | `UNKNOWN` | 无法判定，**必须**附原因 |
| `4` | `MISSING` | 所需后端不存在。此时*不许*回退到估算 |
| `5` | `EMPTY` | 正常运行，但没有任何结果 |

两条要点：

- `unsat` 是 `0`，`unknown` 是 `3`。shell 里的 `if` 不可能把两者弄混。
- `1` 只在*主动推翻*时出现。「我读不懂这份证书」只能走 `3`，否则就是伪证。

`stdout` 只出机器可解析内容（一行 `s <判决>` 或一个 JSON 对象），诊断走 `stderr`。

## 已实现的五个命令与两个技能

| 命令 | 一个职责 |
|---|---|
| `opl-capabilities` | 探测后端，产出 `capabilities.json`。含 Python 模块探测与解释器分裂检测 |
| `opl-conj` | 猜想台账。一题一文件；**状态变更必须带 `--evidence`**，否则拒绝写入（退出码 `2`） |
| `opl-encode` | 规格 → CNF / CP-SAT；双后端一致性检查；见证直接求值 |
| `opl-search` | 跑搜索，产出见证或 DRAT 证明 |
| `opl-certcheck` | 用独立校验器复核证书 |

（都在 `plugin/bin/` 下；下面出现时按完整路径写。）

证书格式与检查器（均实测通过）：

| 格式 | 检查器 | 上游 |
|---|---|---|
| DRAT | [drat-trim](https://github.com/marijnheule/drat-trim) | Marijn Heule，MIT |
| LRAT | lrat-check | 同上仓库 |
| LPR | [cake_lpr](https://github.com/tanyongkiam/cake_lpr) | 经 [CakeML](https://cakeml.org/) 形式化验证过编译 |
| Alethe | [carcara](https://github.com/ufmg-smite/carcara)（可选） | Apache-2.0 |

技能：`opl-entry`（总纲与路由）、`opl-refute`（反例搜索五步流程）。

`opl-encode` 与 `opl-search` 的逻辑已下沉到 `lib/*.py`（可类型检查、可单测），
`bin/` 下只做 argv 解析与退出码翻译。另外三个命令（`opl-capabilities`、`opl-conj`、
`opl-certcheck`）写得更早，逻辑仍在 `bin/` 里——因此**暂时不在类型检查范围内**。
这是一处已知债务，见文末「已知边界」。

## 准备第三方证明工具

那些二进制**不在仓库里**（它们是别的项目的构建产物），由脚本安装：

```bash
plugin/scripts/setup-third-party.sh            # drat-trim / lrat-check / cake_lpr
plugin/scripts/setup-third-party.sh --with-carcara   # 另加 Alethe 检查器（30 MB）
```

脚本里含两处实测得来的必要修补：

- [drat-trim](https://github.com/marijnheule/drat-trim) 上游 Makefile 用 `-std=c99`，
  而那会置 `__STRICT_ANSI__`、glibc 于是隐藏 `getc_unlocked`；GCC 14 起隐式声明是
  硬错误，原样 `make` 编译不过。补 `-D_DEFAULT_SOURCE`（保留 `c99`）。
- `decompress`（同仓库）上游有 bug：`read_lit` 内遗留 `printf`，输出不是合法 LRAT。
  脚本明确跳过，而不是装个坏的。

求解器走一个 venv，命令在运行时会自动解析并切换解释器——不需要把 shebang 写死到
某个绝对路径。它们分别是 [PySAT](https://github.com/pysathq/pysat)（内置
Glucose42 / Lingeling）、[OR-Tools](https://github.com/google/or-tools) 的 CP-SAT，
以及 [cvc5](https://github.com/cvc5/cvc5)。

## 快速上手：五步闭环

以下命令都在**仓库根目录**执行。

```bash
# 规格是你写的：有限域约束 JSON。语义约定是「找到解 = 反例存在」。
# 仓库自带一个可直接跑的例子（2 只鸽子、3 个洞、每只独占一个洞）：
SPEC=plugin/tests/fixtures/spec-pc23.json

# 1 登记
plugin/bin/opl-conj add --id C-0001 \
  --statement "3 个洞容得下 2 只鸽子，每只独占一个洞" --source "$SPEC"

# 2 编码，让两条独立路径互相证伪（退出码 1 = 编码有错，不是「无解」）
plugin/bin/opl-encode --spec "$SPEC" --check-consistency

# 3 搜索（sat 出见证，unsat 出 DRAT 证明）
plugin/bin/opl-search --spec "$SPEC" \
  --cnf-out lab/runs/C-0001/formula.cnf \
  --witness-out lab/runs/C-0001/witness.json --timeout 300

# 4 独立复核：sat 侧用规格直接求值（这条路径与任何编码器无关）
plugin/bin/opl-encode --spec "$SPEC" --eval-witness lab/runs/C-0001/witness.json

# 5 定案（不带 --evidence 会被拒绝写入，退出码 2）
plugin/bin/opl-conj set C-0001 --formal-status refuted \
  --evidence lab/runs/C-0001/witness.json --verification-level exact_certificate
```

unsat 侧把第 3、4 步换成 `--proof-out` 与 `opl-certcheck`（`spec-pc43.json` 是
同一族的不可满足实例）：

```bash
plugin/bin/opl-search --spec plugin/tests/fixtures/spec-pc43.json \
  --cnf-out lab/runs/C-0002/formula.cnf --proof-out lab/runs/C-0002/proof.drat
plugin/bin/opl-certcheck --formula lab/runs/C-0002/formula.cnf \
  --cert lab/runs/C-0002/proof.drat --evidence-out lab/evidence/C-0002.json
# 退出码 0 且 stdout 为 `s VERIFIED` 才算「该域内无反例」
```

## 打包与安装

```bash
plugin/scripts/build-zip.sh      # -> plugin/dist/open-problem-lab-<版本>.zip（约 250 KB）
plugin/scripts/verify-zip.sh     # 解压到干净目录并跑通上面那条链
```

包里不含 `carcara`（30 MB）与 `decompress`（上游有 bug）——缺它们时命令会如实报
`MISSING(4)` 并降级，那正是能力探测的设计行为。

包内含第三方二进制，因此附有 [`plugin/THIRD-PARTY-NOTICES.md`](plugin/THIRD-PARTY-NOTICES.md)：
drat-trim 的 MIT 与 cake_lpr 的 CakeML 许可都要求随二进制分发时附上条款声明，
该文件由 `scripts/update-third-party-notices.sh` **从上游源码目录原样拼入**并做一致性
校对，不靠手抄。`build-zip.sh` 缺了它直接拒绝出包。

`capabilities.json` 里的 `split_brain` 字段值得一提：它会检测「没有任何单一
解释器同时满足某一组依赖」的情况。这不是假想的——本项目就踩过一次（系统
Python 有 `z3`/`sympy`，另一个 venv 有 `cvc5`/`ortools`，两边都缺对方）。

## 仓库结构

```
plugin/                 插件本体
  kimi.plugin.json      清单（skills 显式列出）
  THIRD-PARTY-NOTICES.md  随包分发的第三方许可声明
  bin/                  五个命令（含 third-party/，由脚本安装，不入库）
  lib/                  全部逻辑，可类型检查、可单测
  skills/               opl-entry · opl-refute
  scripts/              typecheck · regress · build-zip · verify-zip
                        setup-third-party · update-third-party-notices · install-hooks
  hooks/pre-commit      提交前：类型检查 + 退出码回归
  tests/fixtures/       运行时与回归共用的夹具（84 KB）
doc/
  plan/                 设计方案 8 章（790 行）
  sections/             调研附录 24 篇（4565 行）
  main.typ              合稿入口，[Typst](https://typst.app/) 编译出 175 页
```

## 验证方式

一切都靠实跑，不靠声明：

```bash
plugin/scripts/regress.sh        # 47 项退出码契约回归，夹具自包含
plugin/scripts/typecheck.sh      # mypy + pyright + ty
plugin/scripts/verify-zip.sh     # 17 项：解压到干净目录并跑通整条链
plugin/scripts/install-hooks.sh  # 挂成提交前钩子
```

回归里有三处**故障注入**——故意编坏 CNF 侧、故意让反解码返回错值、故意把
「无证据改状态」的退出码改掉，断言它们都被检出。负向对照一律用*内容篡改*，
从不用截断证明：实测截断后 `drat-trim` 仍报 `VERIFIED`（正向传播自己就导出了
冲突），拿它做验收会得到一个永远通过的假验收。

类型检查跑三个而不是挑一个，因为实测它们在未注解函数上结论不同：`run()` 还没
写返回注解时，把三元组按四元组解包，[pyright](https://github.com/microsoft/pyright)
抓到了而 [mypy](https://github.com/python/mypy) 与
[ty](https://github.com/astral-sh/ty) 沉默。单一检查器会漏。

## 已知边界

- **交叉验证有固有边界**：双后端一致性检查能抓「改变可满足性」或「见证违反规格」
  的编码错误，抓不到「只让编码变松而恰好没改变所找到的模型」的潜在错误。
- **编码代价闸门**：作用域赋值组合超过上限（默认 20 万）即拒绝编码并报 `USAGE(2)`，
  不静默降级——一个悄悄截断的编码会让「范围内无反例」毫无意义。
- **尖端的 SAT 实例**目前表达不出来：规格语言只支持 `linear` 与 `alldiff`，
  没有子句/表约束，所以无法直接编码随机 3-SAT 这类难例。
- **`unknown` 无法用预算强制**：PySAT 的 `conf_budget` / `prop_budget` 实测对
  Glucose42 无效（设成 0 仍照常解完）。超时只能用 `--timeout`（墙钟 + 子进程）。
- **类型检查有盲区**：`bin/` 下的命令没有 `.py` 扩展名（Unix 可执行文件本该如此），
  于是 `mypy` 报 `Cannot find implementation`、`ty` 报 `unresolved-import`。
  目前只有 `lib/` 被检查。修法不是改名，而是把剩下三个命令的逻辑也下沉到 `lib/`。

## 状态

`opl-encode` / `opl-search` 与其下游的证书链已实现并纳入回归；设计方案里的
Lean 形式化验证、进化式程序搜索、基准统计与报告生成尚未实现（设计见
`doc/plan/03-toolchain.typ` 的命令清单）。

## 许可

本项目为 AGPL-3.0，见 [LICENSE](LICENSE)。

仓库不含第三方二进制；`scripts/setup-third-party.sh` 会从各自的上游仓库克隆与
构建，随包分发时的许可声明见 [`plugin/THIRD-PARTY-NOTICES.md`](plugin/THIRD-PARTY-NOTICES.md)。

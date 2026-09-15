# km-research

为 [Kimi Code](https://moonshotai.github.io/kimi-code/) 制作的开放问题研究插件，代号 **open-problem-lab**。

它的目标很窄：**让结论两侧都经得起独立复核**——反例侧把「求解器说 UNSAT」
变成可被第三方证书复核的结论，证明侧把「命题已证」变成可被独立内核复核的结论。
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

## 已实现的六个命令与四个技能

| 命令 | 一个职责 |
|---|---|
| `opl-capabilities` | 探测后端，产出 `capabilities.json`。含 Python 模块探测与解释器分裂检测 |
| `opl-conj` | 猜想台账。一题一文件；**状态变更必须带 `--evidence`**，否则拒绝写入（退出码 `2`） |
| `opl-encode` | 规格 → CNF / CP-SAT；双后端一致性检查；见证直接求值 |
| `opl-search` | 跑搜索，产出见证或 DRAT 证明 |
| `opl-certcheck` | 用独立校验器复核证书 |
| `opl-leancheck` | 编译 Lean 文件并审计证明状态（公理白名单 + `sorry` 检测） |

（都在 `plugin/bin/` 下；下面出现时按完整路径写。）

证书格式与检查器（均实测通过）：

| 格式 | 检查器 | 上游 |
|---|---|---|
| DRAT | [drat-trim](https://github.com/marijnheule/drat-trim) | Marijn Heule，MIT |
| LRAT | lrat-check | 同上仓库 |
| LPR | [cake_lpr](https://github.com/tanyongkiam/cake_lpr) | 经 [CakeML](https://cakeml.org/) 形式化验证过编译 |
| Alethe | [carcara](https://github.com/ufmg-smite/carcara)（可选） | Apache-2.0 |

技能：`opl-entry`（总纲与路由）、`opl-refute`（反例搜索五步流程）、
`opl-formalize`（命题 → Lean 陈述）、`opl-prove`（Lean 证明的审计与定案）。

**六个命令的逻辑全部在 `lib/*.py` 内**（可类型检查、可单测），`bin/` 下只做 argv
解析与退出码翻译。这是必需的而不是偏好：`bin/` 里的命令没有 `.py` 扩展名，
是三个类型检查器的共同盲区（`mypy` 报 `Cannot find implementation`、
`ty` 报 `unresolved-import`），逻辑只要留在那儿就等于没有类型检查。

## 准备 Lean（证明侧）

反例侧只需要上面「准备第三方证明工具」那一步，证明侧还需要一个**定点 toolchain**
的 Lean 项目：

```bash
ln -s /path/to/your/lean/project plugin/lean   # 或设 OPL_LEAN_PROJECT
plugin/bin/opl-capabilities --json | grep -A5 lean_project
```

**必须定点**（项目里要有 `lean-toolchain`），否则 elan 的
`default_toolchain = "stable"` 会让每次 `lean`/`lake` 调用都联网解析版本。
同一条 `lake --version` 在无 `lean-toolchain` 的目录里实测三轮分别耗
**5.0/3.0/5.0、12.0/3.0/9.9、7.4/3.8/1.3 秒**（跨度 1.3–12 秒，最坏一次撞上 12 秒
上限），定点目录里为 **21/20/20 ms**——差两个到三个数量级，且哪一次卡住纯看网络。

两侧的应对是**同一条**：**有定点就用，没定点不探**。

- `opl-leancheck` 在未定点的目录里**拒绝运行**（退出码 `2`），而不是替你触发一次
  工具链下载。
- `opl-capabilities` 在**没有定点项目**时，`lean` / `lake` 两个可执行文件只报
  「在不在 PATH 上」这个文件系统事实（`probe_skipped: "unpinned"`），**一次都不调用**
  它们，并把推荐做法（`advice`）与不含子进程的环境事实（`env`：elan 装了哪些
  toolchain、`default_toolchain` 解析到哪个）一并给出。有定点项目时则**在那个目录里
  探**，`probe_ms` 是 20 毫秒量级；`pinned_fast` 为此保留了它唯一有意义的场景——
  「看着定点、其实仍在联网」（比如项目里的 `lean-toolchain` 被删了）。

这条不是洁癖，是实测数字：未定点的 cwd 里跑一次完整的 `opl-capabilities`，原先
30 秒（`lean_project`）+ 5 秒 ×2（通用探针）**合计 40 秒**，换回三个
`probe_timeout`、零条有效信息；现在 0.1 秒出结果，且该给的信息一样不少。

本机链的是 `~/Downloads/emsx/leanproof`（`leanprover/lean4:v4.33.0-rc1`，
Mathlib 已构建 8,279 个 `.olean`）。**那个仓库不含 Lean 项目**——它是指向本机路径
的软链，对别人是断链，所以已 gitignore，需要你自己接一个。

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

### 证明侧：真命题 → `lean_checked`

```bash
# 1 形式化：写一个 .lean 文件（opl-formalize 技能负责这一步的纪律）
#   一份真命题的样例见 plugin/tests/fixtures/lean-real.lean
#   「前 n 个奇数之和等于 n²」，带真正的归纳证明

# 2 登记
plugin/bin/opl-conj add --id C-0003 --title "前 n 个奇数之和等于 n²" \
  --statement "1+3+5+…+(2n-1) = n²" --source plugin/tests/fixtures/lean-real.lean

# 3 证明检查 + 独立内核复核：退出码 0 且 stdout 为 `s PROVED`
#   审计不问「编译过了吗」，而是向内核要公理集合（#print axioms）
plugin/bin/opl-leancheck --file plugin/tests/fixtures/lean-real.lean \
  --decl oddSum_eq_sq --evidence-out lab/evidence/C-0003.json

# 4 台账定案
plugin/bin/opl-conj set C-0003 --formal-status proved \
  --evidence lab/evidence/C-0003.json --verification-level lean_checked
```

第 3 步里「证明检查」与「独立内核复核」是同一条命令的两件事：编译告诉你能不能被
内核接受，而**判决取的是内核报出的公理集合**。

为什么第 2 步不能只看「编译通过」：**`sorry` 与 `native_decide` 都退出 `0`**。
前者是没证完，后者向逻辑新增一条断言公理（`#print axioms` 会报出
`<定理名>._native.native_decide.ax_N_M`）。所以判定一律以公理集合是否落在
`{propext, Classical.choice, Quot.sound}` 内为准——这与 `cake_lpr`、`carcara`
是同一类陷阱：**工具的退出码不携带我们要的那个区别**。

## 打包与安装

```bash
plugin/scripts/build-zip.sh      # -> plugin/dist/open-problem-lab-<版本>.zip（约 285 KB）
plugin/scripts/verify-zip.sh     # 解压到干净目录并跑通两条链（反例侧 + 证明侧）
```

包里不含 `carcara`（30 MB）与 `decompress`（上游有 bug）——缺它们时命令会如实报
`MISSING(4)` 并降级，那正是能力探测的设计行为。**包里也不含 Lean 项目**（那是指向
本机路径的软链，且 Mathlib 有数 GB），所以包内的证明侧链路依赖你自己接一个定点项目；
缺它时 `opl-leancheck` 报 `2` 或 `4`，并计入 `skip` 而不是 `pass`。

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
  bin/                  六个命令（含 third-party/，由脚本安装，不入库）
  lib/                  全部逻辑（2,228 行），可类型检查、可单测
  skills/               opl-entry · opl-refute · opl-formalize · opl-prove
  scripts/              typecheck · regress · build-zip · verify-zip
                        setup-third-party · update-third-party-notices · install-hooks
  hooks/pre-commit      提交前：类型检查 + 退出码回归
  tests/fixtures/       运行时与回归共用的夹具（108 KB）
  lean                  指向本机 Lean 项目的软链（不入库）
doc/
  plan/                 设计方案 8 章（790 行）
  sections/             调研附录 24 篇（4565 行）
  main.typ              合稿入口，[Typst](https://typst.app/) 编译出 175 页
```

## 验证方式

一切都靠实跑，不靠声明：

```bash
plugin/scripts/regress.sh        # 93 项退出码契约回归，夹具自包含
plugin/scripts/typecheck.sh      # mypy + pyright + ty
plugin/scripts/verify-zip.sh     # 41 项：解压到干净目录并跑通两条链
plugin/scripts/install-hooks.sh  # 挂成提交前钩子
```

回归里有两处**跳过**的路数，刻意与「通过」分开计数：Lean 相关的那几项在没有
`lake` 或没有定点项目时**不跑**（`regress.sh` 报 `79 通过 / 0 失败 / 14 跳过`），
`verify-zip.sh` 在同样情形下报 `27 通过 / 0 失败 / 5 跳过`。
跳过与通过是两件事——把没跑的算成通过，正是这个项目最想防的那类错误。

回归里有两处**故障注入**——在*临时副本*上故意编坏 CNF 侧、故意让反解码返回错值，
断言它们都被检出（真实代码树全程不被碰）。更早还有第三处「故意把『无证据改状态』
的退出码改掉」，后来被一条直接断言的用例取代了——注入版与直接版覆盖同一档，
留两个只会让脚本更长。
负向对照一律用*内容篡改*，从不用截断证明：实测截断后 `drat-trim` 仍报 `VERIFIED`
（正向传播自己就导出了冲突），拿它做验收会得到一个永远通过的假验收。

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
  修法不是改名，而是把逻辑下沉到 `lib/`——**六个命令现已全部下沉**（`bin/` 合计
  889 行，只剩 argv 与退出码翻译；逻辑 2,228 行全在 `lib/` 内）。但盲区本身没有消失：
  往 `bin/` 里新写一段逻辑，它照样不会被任何检查器看到，只能靠自律。
- **Lean 侧依赖外部项目**：`plugin/lean` 是本机软链，仓库不含那个项目。
  压缩包因此开箱跑不了证明侧链路（会如实报 `2`/`4` 并降级）。这是刻意的——
  那是一个 7 GB 的已归档项目，不该进包。
- **「独立内核复核」目前是公理审计，不是第二内核**：Lean 自带的 `leanchecker`
  （只跑内核、不跑策略层）没有接进来，因为它要求 `.olean` 落在项目 root 之内，
  而 `plugin/lean` 按边界约定只读使用，写临时产物进去越界。
  现用的是 `#print axioms` + 文件级 `hasSorry` 两条互补信道——它们能抓出
  `sorry`/`native_decide`，但终究是同一个内核给出的答案。

## 状态

已实现并纳入回归：`opl-encode` / `opl-search` 与其下游的证书链（反例侧），
以及 `opl-leancheck` 与其两个技能（证明侧）。两侧的端到端都固化在
`plugin/scripts/regress.sh` 与 `verify-zip.sh` 里，不是一次性手跑。

设计方案里尚未实现：进化式程序搜索（M4）、基准与统计（M5）与报告生成，
命令清单见 `doc/plan/03-toolchain.typ`，里程碑见 `doc/plan/07-roadmap.typ`。

## 许可

本项目为 AGPL-3.0，见 [LICENSE](LICENSE)。

仓库不含第三方二进制；`scripts/setup-third-party.sh` 会从各自的上游仓库克隆与
构建，随包分发时的许可声明见 [`plugin/THIRD-PARTY-NOTICES.md`](plugin/THIRD-PARTY-NOTICES.md)。

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

## 已实现的十二个命令与五个技能

| 命令 | 一个职责 |
|---|---|
| `opl-capabilities` | 探测后端，产出 `capabilities.json`。含 Python 模块探测、解释器分裂检测与**功能性沙箱探测** |
| `opl-conj` | 猜想台账。一题一文件；状态变更必须带 `--evidence`，证据还要与结论**绑对象、绑方向、绑范围、绑输入哈希**；改动先在副本上应用完再校验整条记录，不自洽就整笔拒绝、一个字段都不写（退出码 `2`）。校验读的不是记录里抄下的摘要，而是**当场重新加载**的那份证据（含它引用的见证/公式/Lean 文件的哈希）。反例的复核章要求种类 `witness_eval`、判决 `VERIFIED`、对象是本猜想、被验见证逐字相同，四条全过才写 `independent`，缺哪条就记 `UNVERIFIED` 并警告；章在**每次写入**时都重核一遍，核不过整笔拒绝。结论是 `proved` 时必须点名声明（`--statement-formal F.lean --decl NAME`），且那个声明必须在该证据审过的声明里。**记录由工具写出时签名；核不过就拒改**（退出码 `2`，可 `--adopt --confirmed-by` 收编，收编时撑不住的声称逐级降下来） |
| `opl-sign` | 本机工具密钥与验签，`init` / `status` / `verify` / `trust` 四个子命令。补的是「这份证据/这条记录是谁写的」：哈希只能证明**自洽**，手写一份自洽的假证据能一路走到 `refuted` + `exact_certificate`。密钥在本机，沙箱里的候选与评估器看不到它，但同一用户下有 shell 的进程仍能读——降的是自欺的概率，不是不可伪造 |
| `opl-encode` | 规格 → CNF / CP-SAT；双后端一致性检查；见证直接求值 |
| `opl-search` | 跑搜索，产出见证或 DRAT 证明 |
| `opl-certcheck` | 用独立校验器复核证书 |
| `opl-leancheck` | 编译 Lean 文件并审计证明状态（公理白名单 + `sorry` 检测） |
| `opl-run` | 在沙箱里跑一条命令，落四份快照（`cmd`/`env`/`capabilities`/`metrics`），支持 `--detach` / `--wait` |
| `opl-evolve-init` | 建程序库：拷入骨架与评估器，并把骨架作为第 0 代**带指标**入库；`--force` 重建时**先把三份新输入与两阶段协议全部验完，再动旧实验**——无效的重建请求不会先移走正常实验；新实验先在 sibling 暂存目录 `<lab>/.evolve-new-<时间戳>` 里整个建完（骨架、评估器、实验定义、基线评估、库、运行史都齐了），再整体切换，中间任何一步失败活实验一个字节都没动；旧实验**整个目录**归档到 `<lab>/.evolve-bak-<时间戳>`，归档名撞了就顺延成 `-2`、`-3`，不原地复用也不覆盖上一份备份 |
| `opl-evolve-suggest` | 出一份变异任务书（可进化区 + 带理由的亲本 + 提交时会执行的约束） |
| `opl-evolve-eval` | 在沙箱里评估一份候选并入库；区外越界、重复各有各的退出码 |
| `opl-evolve-show` | 看程序库；`--best` 必须配 `--where`，否则可能选出不可行的程序；它只比较**当前实验定义与评估器指纹一致**的成绩，指纹取的是**产生这条成绩的那一次运行**而不是最近一次，成绩**说不清来源**的同样排除；跳过的**不可比**条数会报出来，`--id` 指出当前成绩来自哪一次运行、哪条索引解不到 |

（都在 `plugin/bin/` 下；下面出现时按完整路径写。上表 12 行是因为 `opl-evolve-*`
占了四行——四个命令同属一个子系统。）

证书格式与检查器（均实测通过）：

| 格式 | 检查器 | 上游 |
|---|---|---|
| DRAT | [drat-trim](https://github.com/marijnheule/drat-trim) | Marijn Heule，MIT |
| LRAT | lrat-check | 同上仓库 |
| LPR | [cake_lpr](https://github.com/tanyongkiam/cake_lpr) | 经 [CakeML](https://cakeml.org/) 形式化验证过编译 |
| Alethe | [carcara](https://github.com/ufmg-smite/carcara)（可选） | Apache-2.0 |

技能：`opl-entry`（总纲与路由）、`opl-refute`（反例搜索五步流程）、
`opl-formalize`（命题 → Lean 陈述）、`opl-prove`（Lean 证明的审计与定案）、
`opl-evolve`（程序骨架的变异搜索）。

**十二个命令的逻辑全部在 `lib/*.py` 内**（可类型检查、可单测），`bin/` 下只做 argv
解析与退出码翻译。这是必需的而不是偏好：`bin/` 里的命令没有 `.py` 扩展名，
是三个类型检查器的共同盲区（`mypy` 报 `Cannot find implementation`、
`ty` 报 `unresolved-import`），逻辑只要留在那儿就等于没有类型检查。实测印证过：
一次编辑让 `bin/opl-run` 引用了未导入的名字，**三个类型检查器都没出声**，是回归
跑出四项红并打出 traceback 才发现的。

## 签名：这句话是谁说的

台账已经能查两件事：**记录自洽**（范围、对象、档位对得上）与**输入现在是什么**
（每次写入重新加载证据、重算它引用的见证/公式/Lean 文件的哈希）。两层都查不出的
是最简单的一种攻击——**手写一份自洽的假证据**。实测：按 `opl.evidence/1` 手写一份
`kind` 是 `witness_eval`、`verdict` 是 `VERIFIED` 的证据，再手写它引用的那个见证
文件，然后把记录改成与它自洽，台账**全盘接受**：`formal_status=refuted`、档位
`exact_certificate`、反例盖上 `independent`。

原因不是校验写漏了，而是**哈希自证**：写文件的人同时写了被引用的文件，于是每个
哈希都对；`verdict` 只是文件里的一行字，没有任何东西验过它。哈希证明的是这份证据
**自洽**，证明不了它**是谁写的**——`opl-sign` 补的就是后者。

它用系统自带 OpenSSH 的 `ssh-keygen -Y sign` / `-Y verify`（SSHSIG，带命名空间
`open-problem-lab`）：不自己实现密码学，也不加第三方依赖。密钥刻意是**无口令**的
工具密钥，因为它是自动流程的一部分，口令要么被旁路、要么变成阻塞（等一个永远不会
来的输入）；要口令保护的密钥得用 ssh-agent 持有，那是另一件事。

| 子命令 | 一个职责 |
|---|---|
| `opl-sign init [--force]` | 生成无口令的本机工具密钥（默认 `~/.config/open-problem-lab/ledger_ed25519`，`OPL_SIGNING_KEY` 可覆盖），并写好 `allowed_signers` 验签清单。**不覆盖已有密钥**，除非 `--force` |
| `opl-sign status` | 签名器状态：密钥、公钥、验签清单各在哪。就绪 `0`，没装 `ssh-keygen` 报 `4`，密钥没生成或有口令报 `1` |
| `opl-sign verify FILE...` | 验签：`0` 全部可信 / `1` 至少一个核不过（**「没有签名」也算核不过**）/ `4` 没装 `ssh-keygen`——无从判定 |
| `opl-sign trust PUBKEY` | 把别处来的公钥加进验签清单（本机自用不需要） |

`4 MISSING` 在这里的含义与别处一致：这台机器没有可用的签名器，于是**不签**
（`init`、`status`、`verify` 都这么判）。**验签不需要私钥**——只要 `ssh-keygen` 与一份
可信公钥清单，所以别人拿你的公钥 + 你签过的文件，在自己机器上就能复核。而「验不了」
与「验不过」是两件事：前者是 `4`，后者是 `1`，把「我读不懂」说成「它是错的」是这个项目
最不能犯的错。这与「找不到 bwrap 就不降级到裸跑」是同一条纪律。

**信任边界要说清楚，别把它当零信任。** 密钥在本机，而沙箱的挂载是显式列表（只挂
评估器与实验定义），所以沙箱里的候选/评估器看不到它——那是它主要挡的对象。但同一
用户下、有 shell 的进程（包括宿主 agent）**仍然能读密钥、照样签**。它把「写个
JSON」升级成「动一次密钥」：不同性质、可以计数、可以审计的动作，降的是**自欺的
概率**，涨的是**事后可复查性**，不是不可伪造。

签名落在两处：

- **证据必须带签名，而且不许覆盖。** `opl-certcheck`、`opl-encode --eval-witness`、
  `opl-leancheck` 写出 `--evidence-out` 时当场签出 `<path>.sig`；**没有签名器就不产出
  无签名的证据**，删掉刚写下的那份文件并以 `4 MISSING` 结束。台账加载证据时在**结构
  检查之后**加一道验签：没有签名或核不过一律拒（退出码 `2`，理由点出签名）。同一个
  `--evidence-out`（或它的 `.sig`）已经存在时，这三条命令以 `2` 拒绝，出路是显式删掉
  旧的那份（或换一个路径）再重做——直接的理由是那个失败窗口：产出流程是「先写正式
  文件、再签名」，签名失败会 `discard()` 那份文件，于是**用同一路径写第二次、而签名器
  恰好不可用**会把先前那份**有效**证据连同签名一起删掉（实测：第一次 `0` 有签名，
  第二次 `4`，旧证据与旧签名都没了）。更根本的是台账**按哈希引用证据**，悄悄换掉同一
  路径上的内容，那条记录当场变成「核不过」，所以证据是**一次写出**的产物，那个 `rm`
  是刻意留给人的：「我知道旧的那份将被丢弃」的确认动作。用例：
  `N8 证据不许覆盖：旧证据与旧签名都完好`。
- **记录也签，而且是内嵌签名。** 记录 JSON 顶层多一个 `signature` 字段
  （`{"format": "sshsig-embedded", "namespace": "open-problem-lab", "value": <SSHSIG>}`），
  所以记录与它的签名在同一个文件里。签名覆盖的是**去掉 `signature` 之后的规范序列化**
  （`sort_keys=True, indent=2`），于是「只改空白或键序」不算改动，任何**语义**改动都会破签。
  为什么不是旁挂一个 `.sig`：旁挂是两个文件，而两个文件**没法一起原子替换**。这一步
  实测过后果——签名失败时正式路径上已经是新内容、旧记录没了，那条新记录又没有可用的
  签名，读的人只会看到「签名核不过」。现在的顺序是**签名先算出来 → 整条写进 `.tmp` →
  在暂存处自验一遍 → 一次 `os.replace` 提交**：任何一步失败都在提交之前，正式路径
  **一个字节都没动**，也不存在「新记录配旧签名」的中间态；签名器不可用就**不写**
  （`4 MISSING`）。提交成功后顺手删掉可能遗留的旁挂 `.sig`——0.3.0 写出的记录是旁挂
  签名的，重写之后那份已经多余，留着只会让「这文件有几个签名」变成一道谜题。
  加载时两种形态都认——先看内嵌，再看旁挂——所以 0.3.0 写出的旁挂记录照样验得过，
  不需要谁去手工迁移。

记录签名核不过只有三种来路：手写的、被工具之外的东西改过、从别处拷来的。读与写
各给一条路：

- **读**如实标注：`opl-conj get` 的 JSON 里多一个
  `"provenance": {"signed": false, "detail": …}`，并往 stderr 打印「未经证实」；
  `opl-conj list` 在行尾标「（未签名/签名核不过）」并给一条汇总。
- **写**拒（退出码 `2`），并给出两条出路：配好签名器重跑，或人工收编。
- **人工收编**：`opl-conj set <id> … --adopt --confirmed-by <谁>`。签名正常时用
  `--adopt` 会被拒（退出码 `2`）——静默忽略一个用户明确给的开关，会让他以为自己
  刚做过什么。

收编是**级联降级**，而不是照单全收：先加一条 `human_confirmations`（`what` 是
`adopt-unsigned-record`，note 里记着收编时**那份文件的哈希**，也就是人当时看的是
哪一份），然后按「档位压回 `empirical`」→「结论退回 `open`」→「核不过的复核章降
成 `UNVERIFIED`」逐级降，每一步都重新校验整条记录、进 `history`、往 stderr 打印
「降级：…」；三步走完仍不自洽就如实抛错。收编要保住的是事实（边界、反例、历史），
不是撑不住的声称——把「我手改过这个文件」静默洗成「工具产出的记录」，正是这一层
要防的事。

这六件事在回归里各有用例（`N1`…`N6`）：没有签名器时不写台账、也不留半个文件；
手写的自洽假证据被拒；真证据改一个字节即核不过；同一路径改内容后签名必须跟着
更新；手改过的记录被拒改，但可如实标注、可人工收编；没有签名器时证据产出命令
也不留无签名的证据。

**提交本身另有两条**（`N7-1 签名失败：旧记录原样，且不提交半个新版本`、
`N7-2 没有签名器时连写都不写（旧记录不动）`），测的是「失败发生在提交之前」——
盘上留着的那条旧记录**逐字节**还是原样，而不是「失败之后清理得干净」。

**踩过的坑值得留在这里**：`ssh-keygen -Y sign` 在 `<path>.sig` 已存在时会**交互式
问**「Overwrite (y/n)?」，非交互场景读到 EOF 就什么都不做，而**退出码仍然是
`0`**。于是「签名成功」其实是一份**旧签名**，内容一改立刻变成「签名核不过」。现在
`sign_file` 先删旧签名再签，**签完自己验一遍**，不过就丢弃并报错——退出码 `0` 不是
「事情做成了」，这一条在本仓库反复出现。

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
# 0 签名器：写台账、产出证据都要求它。本机工具密钥，跑一次就够
#   （没有它，写台账与产出证据的命令都以 4 MISSING 结束，而不是写出没签名的东西）
plugin/bin/opl-sign init

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

# 4 独立复核：sat 侧用规格直接求值（这条路径与任何编码器无关）。
#   同时也产出**证据记录**——裸的 witness.json 不是证据：它证明不了「谁复核的」，
#   也证明不了「复核的是这份见证」。这份记录由产出它的命令当场签出
#   `lab/evidence/C-0001.json.sig`（谁写的，用的是第 0 步的密钥）；
#   `--subject` 再把它绑到某个猜想上，少了它这份证据可以给**另一个**猜想背书，
#   台账会拒收
plugin/bin/opl-encode --spec "$SPEC" --eval-witness lab/runs/C-0001/witness.json \
  --subject C-0001 --evidence-out lab/evidence/C-0001.json

# 5 定案（不带 --evidence 会被拒；档位也要证据支撑，退出码 2）
plugin/bin/opl-conj set C-0001 --formal-status refuted \
  --evidence lab/evidence/C-0001.json --verification-level exact_certificate
```

unsat 侧把第 3、4 步换成 `--proof-out` 与 `opl-certcheck`（`spec-pc43.json` 是
同一族的不可满足实例）：

```bash
plugin/bin/opl-search --spec plugin/tests/fixtures/spec-pc43.json \
  --cnf-out lab/runs/C-0002/formula.cnf --proof-out lab/runs/C-0002/proof.drat
plugin/bin/opl-certcheck --formula lab/runs/C-0002/formula.cnf \
  --cert lab/runs/C-0002/proof.drat --subject C-0002 --evidence-out lab/evidence/C-0002.json
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

# 4 台账定案：结论是 proved 就必须点名声明，且必须是第 3 步审过的那个
#   —— 同一文件里换一个声明就是换了一个被证明的命题，不点名会被拒
plugin/bin/opl-conj set C-0003 --formal-status proved \
  --evidence lab/evidence/C-0003.json --verification-level lean_checked \
  --statement-formal plugin/tests/fixtures/lean-real.lean --decl oddSum_eq_sq
```

第 3 步里「证明检查」与「独立内核复核」是同一条命令的两件事：编译告诉你能不能被
内核接受，而**判决取的是内核报出的公理集合**。

为什么第 2 步不能只看「编译通过」：**`sorry` 与 `native_decide` 都退出 `0`**。
前者是没证完，后者向逻辑新增一条断言公理（`#print axioms` 会报出
`<定理名>._native.native_decide.ax_N_M`）。所以判定一律以公理集合是否落在
`{propext, Classical.choice, Quot.sound}` 内为准——这与 `cake_lpr`、`carcara`
是同一类陷阱：**工具的退出码不携带我们要的那个区别**。

## 程序搜索：`opl-evolve-*`（M4）

工具**不替你变异**——变异算子留给宿主 agent，可执行文件只做「数据库 + 评估器 +
沙箱」（`doc/plan/01-overview.typ` 定的分工）。它保证你变出来的东西**可独立复核、
可去重、不会越界**。

```bash
SN=plugin/tests/fixtures/sortnet       # 排序网络：骨架 6 个比较器，n=4 最优 5 个
plugin/bin/opl-evolve-init --lab lab --skeleton $SN/skeleton.py \
  --evaluator $SN/evaluator.py --problem $SN/problem.json
plugin/bin/opl-evolve-suggest --lab lab --metric comparators --where sorts=true
# …你按任务书改可进化区，交一份完整文件…
plugin/bin/opl-evolve-eval --lab lab --candidate ./cand-01.py --generation 1 --operation mutate
plugin/bin/opl-evolve-show --lab lab --best comparators --where sorts=true
```

判决分四档，各自的动作不同：`0` 入库且按定义可行 / `1` 入库但不可行（这只否定
**这一个候选**，不否定它的邻域或路线）/ `2` 候选不合格或**指标不符合实验定义**
（前者修候选，后者修评估器）/ `5` `code_hash` 命中，没有新增。
另有两种「没有判决」：`3` 沙箱没给出结论（超时 / 被 OOM 杀 / 没写出指标），或
**退出码与它写的指标互相矛盾**（标签 `verdict_conflict`，理由见下）；`4` 找不到 bwrap。

**成绩只在同一个实验里可比。** 换了题目参数或评估器就是换了问题，同名指标
（`comparators`、`loss`）不再是同一件事，所以 `--best` 只考虑实验定义 sha256 + 评估器
sha256 与当前实验一致的成绩，跳过多少条会打印出来。
**但这两枚指纹必须取自产生这条成绩的那一次运行，而不是最近一次运行。**
`programs` 上多一列 `metrics_evaluation_id`，记着当前头条指标是哪一次
运行跑出来的；`add_evaluation()` 写指标时把来源一起更新，所以不会出现
「成绩来自 A、身份写着 B」；`best()` 顺着这一列取那一行的指纹
（`metrics_fingerprints`）。为什么不能拿「最近一次运行」当身份——失败运行
（超时、评估器崩）**不写指标，却照样追加一行运行史**，于是
「旧定义的成绩 + 新定义的指纹」被判为可比：让一次**没有产生任何成绩**的运行
去代表成绩的归属，一次超时补测就能把旧定义的成绩洗成新定义的。实测：四路排序
基线 6 个比较器，改成五路定义后 `--best` 正确为空；对同一程序补测、注入一次
超时（退出码 `3`），再查 `--best` 就把旧的四路成绩当成新定义的返回了。用例：
`N9 没有指标的运行不得改变已有成绩的归属`。

成绩在、却**说不清是哪一次跑出来的**（旧库没回填上，或被手工改过）时，`best()` 把它
**排除**在比较之外并单独计数（`skipped_unattributed`，与「不可比」的
`skipped_incomparable` 分列），**不拿别的运行的指纹替它作证**——替它作证，跟一次超时
把旧成绩洗白是同一件事。旧库打开时会自动补列并回填（取该程序**最后一条带指标的
评估**，不是猜：`add_evaluation()` 只在传入指标时才更新头条指标，两者本来就同一件
事），补不上的才算来源不明。`opl-evolve-show --id` 会指出**当前成绩来自哪一次运行**，
也会指出成绩说不清来源的那种情况。

重建实验时 `--force` 把**旧实验整个目录**归档，是同一条理由的另一半：不归档，旧成绩
会继续参与排名，于是「最好的一条」来自一个已经不存在的实验；而只归档库文件不够——
库里的成绩是配着旧骨架、旧评估器算出来的，留下骨架就等于留下一个成绩与代码对不上
的实验，所以归档的是骨架、评估器、实验定义、运行史、库这一整套，路径
`<lab>/.evolve-bak-<时间戳>`。整目录归档还让索引跟着走：运行史里的
`evaluations.run_dir` 存的是**相对实验目录**的路径，归档之后每条索引落在归档目录里，
不指回活实验。0.4.0 及以前写进库的是**绝对**路径，它们要在实验被归档**之前**一次性
迁成相对形式——`init_lab` 在搬迁之前调 `migrate_run_dirs`，因为搬完就再也说不清某条
绝对路径原属哪个实验了，迁移条数会打印出来；**无法归属的**（绝对路径不在这个实验
目录下）**只计数、原样保留**并打印一句提醒——静默把它当成正确索引，等于给一个来历
不明的路径背书。读接口因此多给一个 `run_dir_exists`，`opl-evolve-show --id` 对解
不到的索引标「**索引解不到**」。用例：
`R7 归档前迁移绝对索引；无法归属的不静默采用`。

新实验也不是拷进活目录的：它先在 sibling 暂存目录 `<lab>/.evolve-new-<时间戳>` 里
**整个建完**（三份输入 + 基线评估 + 建库 + 写运行史），全部成功了才**整体切换**（两次
`os.replace`，都在同一文件系统内）。于是复制、评估、数据库写入**任何一步**失败，活实验
**一个字节都没动**，暂存目录被清掉；切换那一步失败，把旧实验原样放回原处并同样清掉暂存。
旧写法是往活目录里增量拷文件，拷到一半失败就留下「库被放回去了、骨架却已换新」的混合
实验，而库里的成绩配的是旧骨架。归档因此**排在新输入验完之后**——骨架路径写错、评估器
不合协议这类无效请求，不该在报错之前先把正常实验挪走；归档名也按「不存在就取下一个」来
定，同一秒里重建两次不会覆盖掉上一份备份。**提交（两次 rename）之后不再有任何写操作**：
运行史里记的运行目录是**相对实验目录**的路径（`runs/cc74d0fe` 这样），暂存期与正式期
因此是同一个字符串，原先那步「切换之后改写运行史里的路径」已经删掉——那一步在切换之后
改库，一次失败会让命令报错、而活实验已经换成了新版。这两条都有用例：
`R6-1 复制阶段失败：活实验一个字节都没动`、
`R6-2 切换之后运行史与快照来源仍指得准`（它另外断言归档库的索引必须落在**归档目录**里）。

**评估器是两阶段的（硬约定）**：`extract` 跑候选、只把产物写成数据；`verify` 读数据、
**独立判定**。插件把两步跑在两个独立沙箱进程里，`verify` 那一侧**没有候选**。
理由是实测的：候选在可进化区里替换掉 `itertools.product`，就能把单进程评估器的枚举器
换掉，于是只查一个输入便报「通过」——**只读挂载挡不住内存里的东西**，边界只能画在
进程上。不合规的评估器会被拒绝，不降级。

**评估器的退出码是契约**：`0` 跑完（可行性看实验定义指定的 `feasible` 字段）/
`1` 结论是按约定不可行 / `2` 拒收候选 / `3+` 评估器自身故障（含被信号杀）。`3+` 时
**它写的指标一概不采信**——实测「按约定返回 1」与「写完指标后崩了」都表现为非零
退出码，不区分就会把一次崩溃算成一条结论。

退出码与它写的指标**矛盾**时同样不下判决：`1` 而指标说可行、或 `0` 而指标说不可行，
都返回 `3`（标签 `verdict_conflict`），理由里两份原始信息都留着。矛盾说明评估器自己
不自洽，而两份说法谁真谁假工具分辨不了——任选一份当依据，就是把一次自相矛盾的运行
洗成一条确定的判决。

**判决顺序是先问「这次跑完了吗」，再问「它说行不行」。** 实测：评估器先写出
`metrics` 再卡死，旧逻辑会因为「产物存在」而判为通过。产物存在只说明写过文件，
**不说明这次运行正常结束**。同理，`sorts: "false"`（字符串）既不是真也不是假——
它是**错的**，按真假猜会把一个坏记录变成一条判决。

**五处刻意取严的约束，都有实测理由：**

- **程序身份与评估运行分列。** 同一份程序可以跑很多次（补测、换预算、换机器），
  每次都进运行史并留自己的四份快照与运行目录。但**默认**重复提交仍会被
  `code_hash` 拒（退出码 `5`，不花沙箱的钱）——要再跑一次得显式 `--reevaluate`。
  反过来（默认重跑）会让「重复提交」静默地又跑一遍。补测不会抹掉旧指标：
  一次后来的坏运行不该让库里的最好结果随运气漂移。


- **题目参数冻结在可信端（`--problem`）。** 区外逐字节比对只能保证**文本**没变，
  保证不了**题目**没变：实测把 `N = 0` 放进可进化区重新绑定，评估器就看到一个零路
  问题并报 `sorts=true, comparators=0`，而区外一字未改。所以题目参数由实验定义给出
  （以**只读**方式挂给评估器），候选声明的值必须与之一致。
- **可行性与指标契约来自实验定义，插件不认识 `sorts`。** 原先硬编码 `sorts`，一个
  返回 `{"feasible": true, "loss": …}` 的通用评估器其候选会被判成「不可行」。


- **区外逐字节不许变。** 「研究者写死骨架」得由工具执行，不能靠自觉。改一个空格
  也算改动——这会误拒「只重排格式」的候选，但绝不会放过一次真实的区外改动，
  而两种错的代价不对称。
- **`best` 必须带 `--where`。** 实测：库里有一条 4 比较器的候选，它**并不排序**。
  不加过滤时 `--best comparators` 会选中它——「从 6 个改进到 4 个」听起来像提升，
  实际是把不可行的东西当成了成绩。可行性必须显式给出；工具刻意不替你猜哪个字段
  意味着「可行」，猜错的那一次就会静默产出一条假曲线。

## 沙箱执行：`opl-run`

候选在 `bwrap` 里跑（禁网 + 独立 PID namespace + 只读系统库），外面套一层**自己建的
per-run cgroup**（内存/进程数限额 + 收口 + OOM 归因）。三条实测推翻了三个想当然：

| 想当然 | 实测 |
|---|---|
| `systemd-run -p IPAddressDeny=any` 能禁网 | **不禁网，而且不报错**（退出 0、无警告）。它靠 cgroup 的 `bpf` 控制器，而本机根 cgroup 没有 `bpf`。禁网因此一律走 `bwrap --unshare-net` |
| `MemoryMax` 能限住内存 | **拦不住**：8 GB swap 把匿名页吸收掉，200 MB 逐页写照样成功（退出 0）。加上 `MemorySwapMax=0` 才开火（被杀，退出 `-9`，`memory.events` 记 `oom_kill 1`）。**两个结果都在这里写着**——只写对自己有利的那一个就成了假验收 |
| `os.killpg` 能收干净 | **收不住 `setsid` 逃逸**（孙子活下来）。`cgroup.kill` 收得住；`bwrap --unshare-pid` 也收得住（内核在 PID namespace 的 init 终止时连坐） |

`opl-capabilities --layer sandbox` 会**当场做一次**这些检查（不是查版本），因为只查
`command -v` 会把「接受参数但什么都不做」的后端记成可用。

`opl-run` 落的四份快照里，`metrics` 的每个值都带**来源**，而来源路径一律写成**相对运行
目录**的（`stdout.txt`、`work/`、`.`、`cgroup/memory.peak` 这样）。理由与「重建先建暂存、
再整体切换」是同一条：绝对路径把主机布局焊进了产物，实验目录一搬家，`sources` /
`artifacts` 就全指向已经不存在的文件——重建之后快照看起来还在，来源却已是一串死链，
「这个数字哪来的」当场断掉。写成相对的，这份 `metrics.json` 搬到哪都还指得准。数据库里的
`evaluations.run_dir` 同理存**相对实验目录**的路径（`runs/cc74d0fe` 这样），由读出接口
（`evaluations()`，也就是 `opl-evolve-show --id` 用的那条）解析成绝对路径再交出去：索引
要能从库里直接导航到某一次运行，而绝对路径一搬家就指着**活实验**——归档之后翻旧成绩会
打开新实验的产物。存相对的，归档库的索引跟着归档目录走。0.4.0 及以前写进库的绝对路径
照旧能读（读接口原样返回），不会被打回。`sources` 里按契约属于**人话**而不是路径的
值（`wall_ms`、`payload_exit_code` 的说明）原样保留；cgroup 不可用时 `peak_mem_bytes` /
`oom_kill` 的值是「（无 cgroup 证词）」这类文字，不是一个看着像路径的字符串。

## 打包与安装


```bash
plugin/scripts/build-zip.sh      # -> plugin/dist/open-problem-lab-<版本>.zip（约 425 KB）
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
  bin/                  十二个命令（含 third-party/，由脚本安装，不入库）
  lib/                  全部逻辑（5,743 行 / 12 个文件），可类型检查、可单测
  skills/               opl-entry · opl-refute · opl-formalize · opl-prove · opl-evolve
  scripts/              typecheck · regress · build-zip · verify-zip
                        setup-third-party · update-third-party-notices · install-hooks
  hooks/pre-commit      提交前：类型检查 + 退出码回归
  tests/fixtures/       运行时与回归共用的夹具（128 KB，含排序网络）
  lean                  指向本机 Lean 项目的软链（不入库）
doc/
  plan/                 设计方案 8 章（790 行）
  sections/             调研附录 24 篇（4565 行）
  main.typ              合稿入口，[Typst](https://typst.app/) 编译出 175 页
```

## 验证方式

一切都靠实跑，不靠声明：

```bash
plugin/scripts/regress.sh        # 166 项退出码契约回归，夹具自包含
plugin/scripts/typecheck.sh      # mypy + pyright + ty
plugin/scripts/verify-zip.sh     # 52 项：解压到干净目录并跑通两条链
plugin/scripts/install-hooks.sh  # 挂成提交前钩子
```

回归里有两处**跳过**的路数，刻意与「通过」分开计数：Lean 相关的那几项在没有
`lake` 或没有定点项目时**不跑**（`regress.sh` 那时报 `150 通过 / 0 失败 / 16 跳过`，
环境齐备时报 `166 通过 / 0 失败 / 0 跳过`），`verify-zip.sh` 在同样情形下报
`46 通过 / 0 失败 / 5 跳过`，环境齐备时报 `52 通过 / 0 失败 / 0 跳过`。
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
  修法不是改名，而是把逻辑下沉到 `lib/`——**命令都已全部下沉**（`bin/` 合计
  1,772 行，只剩 argv 与退出码翻译；逻辑 5,743 行全在 `lib/` 内）。但盲区本身没有消失：
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

**版本 `0.6.1`**（清单里的 `version` 是真源，压缩包名跟着它走）：

| 版本 | 覆盖 | 破坏性改动 |
|---|---|---|
| `0.1.0` | M0 契约与骨架、M1 编码与搜索、M2 反例搜索闭环 | — |
| `0.2.0` | 加上 M3 证明侧（`opl-leancheck` + 两个技能）与 M4 程序搜索（`opl-run` + `opl-evolve-*` + 技能），并修掉一批**假成功路径** | 两处：**证据记录**必须带 `subject` / `kind` / `range` 并绑定输入哈希（`opl-conj` 会核对）；**评估器**必须是两阶段协议（`extract` / `verify`），单阶段的会在 `init` 被拒 |
| `0.2.1` | 台账改成**事务式校验**（校验改完的整条记录，不再逐个参数补条件），评估器**退出码与指标矛盾**时不下判决，`--force` 重建归档旧库，`--best` 只比较同一实验的成绩 | 一处：台账会**拒绝**以前能写进去的改动——只改 `--verified-range` 不换证据、证据缺 `kind` 的升档、给无关见证盖复核章（最后一种仍降级记录，只是不再盖章） |
| `0.2.2` | 修掉两类**假成功**：**假复核**——反例的复核章现在要求种类 `witness_eval`、判决 `VERIFIED`、对象是本猜想、被验见证逐字相同，四条全过才写 `independent`，且每次写入都重新加载证据重核一遍，核不过整笔拒绝；**摘要当证据用**——台账不再拿记录里抄下的路径 + 哈希当依据，而是每次写入都重新加载那份证据并核对它引用的输入文件。结论是 `proved` 时必须点名声明，`--force` 重建改成**先验完新输入与协议、再动活库** | 两处：一份判决不是 `VERIFIED` 的见证、或属于**别的**猜想的证据，都不能再给反例盖 `independent`（降级为 `UNVERIFIED`）；结论是 `proved` 却不说证明了哪个声明（`--statement-formal F.lean --decl NAME`），或点的声明不在该证据审过的声明里，一律拒收（退出码 `2`） |
| `0.3.0` | 加上**签名层**（`opl-sign`，逻辑在 `lib/opl_sign.py`）：证据由产出它的命令当场签出 `<path>.sig`，记录由 `save()` 写盘时签，台账加载证据时验签；`opl-conj get` / `list` 如实标注签名核不过的记录，`opl-conj set` 拒改但可人工收编（`--adopt --confirmed-by`，级联降档位 → 退结论 → 复核章降 `UNVERIFIED`）。顺带修掉 `ssh-keygen -Y sign` 在目标签名已存在时静默不签却仍退 `0` 的坑——现在先删旧签名再签，签完自检一遍 | 一处：**任何写台账的动作现在都要求签名器**（先跑 `opl-sign init`，否则以 `4 MISSING` 结束）；**证据必须带签名**——老的、手写的、别处来的证据一律拒收（退出码 `2`）；老记录要 `opl-conj set … --adopt --confirmed-by <谁>` 收编，收编时撑不住的声称逐级降下来 |
| `0.4.0` | 补掉两处**事务缺口**。**写台账**改成「签名先算出来 → 整条写进 `.tmp` → 在暂存处自验 → 一次 `os.replace` 提交」，记录改成**内嵌签名**（顶层多一个 `signature` 字段，签的是去掉它之后的规范序列化），失败时正式路径一个字节都没动；**`--force` 重建**改成先在 sibling 暂存目录 `.evolve-new-<ts>` 里把整个新实验建完（含基线评估与库）再整体切换，归档的是整个旧实验目录 `.evolve-bak-<ts>`；运行快照里 `metrics.sources` / `metrics.artifacts` 的路径改成相对运行目录 | 两处：快照里的**来源路径**从绝对改成**相对运行目录**（下游若按绝对路径去找产物，搬家后会踩空；`evaluations.run_dir` 仍是绝对路径，由 `init_lab` 在搬家时改写）；`--force` 的归档从「库文件 `programs.sqlite.bak-*`」变成「**整个实验目录** `.evolve-bak-*`」 |
| `0.5.0` | 补掉三处**产物完整性缺口**。**证据不许覆盖**：`--evidence-out` 指向已存在的路径（或它的 `.sig`）时以 `2` 拒绝——证据是一次写出的产物，覆盖会让按哈希引用它的台账记录当场核不过；**运行索引改成相对实验目录存储**（`evaluations.run_dir` 存 `runs/<id>` 这样的相对路径，读出接口解析成绝对路径再交出去），于是归档库的索引落在归档目录里，`init_lab` **提交之后不再有任何写操作**（原先那步「切换后改写运行史路径」删掉了） | 两处：**证据输出路径已存在会被拒**（以前会覆盖，而「同一路径写第二次 + 签名器恰好不可用」会把旧证据与旧签名一起删掉）；**`evaluations.run_dir` 从绝对路径改成相对实验目录**存储（直接读 SQL 的下游要按实验目录解析，或用 `opl-evolve-show` 的接口） |
| `0.6.0` | 修掉两处**归属缺口**。**成绩跟着产生它的那次评估走**：`programs` 多一列 `metrics_evaluation_id`（`add_evaluation()` 写指标时把来源一起更新，不会出现「成绩来自 A、身份写着 B」），`best()` 比的是**那一次运行**的实验定义 sha256 + 评估器 sha256，不再是最近一次运行——失败运行只追加运行史，指标与来源两处都不动，于是「一次超时补测把旧定义的成绩洗成新定义」这条路被堵死；成绩说不清来源的（旧库没回填上、或被手工改过）被排除并单独计数，`opl-evolve-show --id` 指出当前成绩来自哪一次运行。**旧库的绝对运行索引在归档前一次性迁移**：`init_lab` 在搬迁之前把属于该实验目录的绝对索引改成相对形式，无法归属的只计数、原样保留并标记（读接口因此多一个 `run_dir_exists`） | 两处：`programs` 直接多出一列 `metrics_evaluation_id`（直接读 SQL 的下游要注意）；**`best()` 会把来源不明的成绩排除在比较之外**（以前会拿别的运行的指纹顶），所以有些查询会从「有结果」变成空 |
| `0.6.1` | 随设计文档同步更新两处**表述**：`lib/opl_common.py` 的退出码说明把 `0` 的含义收窄为「这一步完成了它那一步」（原文写着「且已被独立复核」，与四个候选实验侧的实际契约不符），并写明 `4 MISSING` 现在也含「没有签名器」；`kimi.plugin.json` 的 `interface.longDescription` 同步这两处措辞，`doc/` 各章补「同步状态」 | 无——行为、接口与产物结构都没变，改的是说明文字 |

0.x 里破坏性改动走 minor，所以是 `0.1.0 → 0.2.0`、`0.2.0 → 0.3.0`、`0.3.0 → 0.4.0`、
`0.4.0 → 0.5.0`、`0.5.0 → 0.6.0`；`0.2.1` 与 `0.2.2` 都是 patch。
`0.3.0` 不是——`0.2.x` 的调用方式在这里**不再照用**：写台账之前先要有签名器，证据没有
签名一律拒收，照旧方式调用会直接失败。
`0.4.0` 也不是：读快照的代码若按绝对路径去找产物，实验目录一搬家就踩空；按
`programs.sqlite.bak-*` 找备份的脚本则会什么都找不到，备份现在是一整个目录。`0.5.0`
同理：往同一个 `--evidence-out` 再写一次现在会被拒（以前是静默覆盖），而直接读
`evaluations.run_dir` 的下游拿到的是相对实验目录的路径——要么自己按实验目录解析，要么
改用 `opl-evolve-show` 的接口。`0.6.0` 也一样：直接读 `programs` 的下游会看到多出来的一
列；把 `best()` 当「总有一条当前最好的」来用的查询现在可能拿到空——成绩说不清来源时它
宁可空着，也不拿别的运行的指纹替它作证。这跟「缺验证器时硬失败」是同一条纪律：写不出
一份能验的证据，就不该写出一份像是能的。

已实现并纳入回归：`opl-sign` 与它支撑的签名层（记录与证据，跨三条链）；
`opl-encode` / `opl-search` 与其下游的证书链（反例侧）；
`opl-leancheck` 与其两个技能（证明侧）；`opl-run` 与 `opl-evolve-*` 四命令加
`opl-evolve` 技能（程序搜索侧，M4）。三条链的端到端都固化在
`plugin/scripts/regress.sh` 与 `verify-zip.sh` 里，不是一次性手跑。

**M4 要说清楚的一点**：改进是「提交一份更好的候选」验出来的，**不是搜索出来的**。
这符合设计（变异算子留给宿主 agent，插件只做数据库 + 评估器 + 沙箱），含义是——
工具不替你变异，它保证你变出来的东西可独立复核、可去重、不会越界。

设计方案里尚未实现：基准与统计（M5）、报告生成（M6），以及 `cell_key`
（MAP-Elites 特征格）的坐标定义——字段已在表里，但单维会退化成单目标，多维需要先
想清楚第二个维度是什么，所以没有编一个出来充数。命令清单见
`doc/plan/03-toolchain.typ`，里程碑见 `doc/plan/07-roadmap.typ`。

## 许可

本项目为 AGPL-3.0，见 [LICENSE](LICENSE)。

仓库不含第三方二进制；`scripts/setup-third-party.sh` 会从各自的上游仓库克隆与
构建，随包分发时的许可声明见 [`plugin/THIRD-PARTY-NOTICES.md`](plugin/THIRD-PARTY-NOTICES.md)。

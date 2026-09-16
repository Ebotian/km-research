---
name: opl-prove
description: 当需要在 Lean 中搜索一个证明时；当一份证明含 sorry、或依赖白名单外公理需要定位时；当需要判断一个 Lean 文件是否构成证明时。
---

# 在 Lean 里搜索证明

```bash
# 下文用 $OPL 指代插件的 bin 目录（agent 的 cwd 是用户工作区，不是插件目录）。
OPL="${KIMI_PLUGIN_ROOT:-<插件根>}/bin"
```

## 判决来自内核报告的公理集合，不是「编译通过」

这是本技能的全部依据，四个真实文件的实测：

| 文件 | 退出码 | `#print axioms` |
|---|---|---|
| 干净证明（`norm_num`） | 0 | `[propext]` |
| `sorry` | **0** | `[sorryAx]` |
| `native_decide` | **0** | `[<定理名>._native.native_decide.ax_1_1]` |
| 错误证明 | 1 | —（无） |

**`sorry` 与 `native_decide` 都退出 0。** 所以「编译通过」不能作为「命题已证」的
证据——这与 `cake_lpr`、`carcara` 是同一类陷阱：工具的退出码不携带我们要的区别。

## 判定为四值，动作各不相同

```bash
$OPL/opl-leancheck --file lab/lean/C0001.lean --decl opl_C0001
```

| 判决 | 退出码 | 含义 | 动作 |
|---|---|---|---|
| `PROVED` | 0 | 内核接受，且公理 ⊆ `{propext, Classical.choice, Quot.sound}` | 可以定案为 `proved`；**必须点名声明被证的是哪条定理**（见下） |
| `SORRY_AX` | 1 | 文件里有 `sorry`，或某定理依赖 `sorryAx` | 补证明；**不得**当作「基本完成」 |
| `UNPROVED_AXIOMS` | 1 | 无 sorry，但依赖白名单外公理 | 多半是 `native_decide`；见下 |
| `FAILED` | 1 | 编译不过 | 先修编译 |

外部工具调用还要另看两种：`UNKNOWN`(3) 是超时（今回没有结论，**不是** Lean 不可用）；
`MISSING`(4) 是没有 lake；`UNPINNED`/2 是项目没定点 toolchain。

## 循环

`Plan → Work → Checkpoint → Review → Replan → Stop`

- **Work**：每次改动后用 `--file` 拿文件级诊断（`import Init` 约 0.5 秒，
  `import Mathlib` 约 2.2 秒）。**不要**每次改动都跑整包 `lake build`。
- **Checkpoint**：只在稳定的中间点跑 `lake build`，确认没有破坏别的声明。
- **Review**：确认 `#print axioms` 落在白名单。这是唯一的验收动作。
- **Replan**：同一目标连续三次尝试都没进展，换策略而不是加大力度重试。
- **Stop**：换过策略仍卡住，**停下来报告**——报告卡在哪一步、试过什么、当前
  最好状态是什么。不要为了让循环看起来有产出而留下 `sorry` 然后声称完成。

## `native_decide` 不是证明

它在 Lean 里会通过，但核心文档自述该机制**向逻辑新增一条断言公理**，并把编译器与
`@[implemented_by]` 定义拉进可信基。`#print axioms` 会把它报成
`<定理名>._native.native_decide.ax_N_M`——不在白名单里，因此判为未证明。

需要给开放问题存档的结论，走 `norm_num` / `linarith` / `omega` 这类产出可检验
证明项的路径。

## `--decl` 怎么用

`#print axioms` 只报告**被点名那条定理**的公理。所以：

- 想审计哪条定理，就 `--decl <定理名>`（可重复）。工具会把它追加到**临时副本**，
  原文件不动。点过的名字会写进证据记录的 `decls`——那张名单是「这份证据审的是哪个
  命题」的唯一凭据，后面的定案要照着它点名。
- 文件里其他没被点名的 `sorry` 不会被漏掉——工具另有一条**文件级**通道
  （`kind == "hasSorry"` 诊断），只要文件里有 `sorry` 就判 `SORRY_AX`。
  实测这个组合能抓到「被点名的定理干净、但旁边有个 ghost 带 sorry」的情形。
- 定理名打错时 `#print axioms` 会报 `Unknown constant` 且退出码 1 → `FAILED`。

## 定案为 `proved` 必须点名声明

判决不会自己变成结论，落台账时要点名说出「被证明的是哪条定理」：

```bash
# 出证据：--decl 点的是这次审计的定理，--subject 是这份证据为哪个猜想而出
$OPL/opl-leancheck --file lab/lean/C0001.lean --decl opl_C0001 \
  --evidence-out lab/evidence/C0001.json --subject C-0001

# 定案：再点一次名，这一次点的是被证明的对象
$OPL/opl-conj set C-0001 --formal-status proved \
  --statement-formal lab/lean/C0001.lean --decl opl_C0001 \
  --evidence lab/evidence/C0001.json --verification-level lean_checked
```

`--evidence-out` 落盘时**自动签出 `<path>.sig`**（走系统自带的 `ssh-keygen -Y sign`，
不自己实现密码学、不加第三方依赖）。这不是装饰：证据是「结论撑不撑得住」的唯一依据，
所以「这句话是谁说的」也得有凭据。**没有签名器时这条命令以 `MISSING`(4) 结束，并删掉
刚写下的文件——不留无签名的证据**，与「找不到 bwrap 就不降级到裸跑」是同一条纪律。
本机还没有密钥就先跑 `$OPL/opl-sign init`（生成无口令的本机工具密钥，已有密钥不覆盖，
除非 `--force`）；证据来自别的机器，就把那边的公钥用 `opl-sign trust` 加进验签清单。
三个产出证据的命令都这样：`opl-certcheck`、`opl-encode --eval-witness`、`opl-leancheck`。

- `--decl` 必须是证据里 `decls` 记着的名字之一。不点名，或点同一个文件里的**另一个**
  声明，都被拒（退出码 `2`）。理由是**路径一致不代表被证明的对象没变**——同一个
  `.lean` 文件里换一个定理就是换了一个命题，只比文件路径分不出这两件事。
- `--statement-formal` 的 `file` 按**绝对路径**与证据里的 `file` 比对，所以写相对路径
  不会误伤同一个文件（证据记的是绝对路径，两种写法指的是同一个文件）。
- 证据的 `subject` 要与猜想 id 相同，否则也拒（退出码 `2`）——一份真证据不能给另一个
  猜想背书。

## 定案之后，证据每次写入都要重新核

记录里的 `evidence` 只是路径 + 哈希 + 几个字段的摘要，**摘要不是证据**：每次写入都会
重新加载那份证据，核对它自己的哈希、它引用的输入（这里就是那个 Lean 文件）的哈希、
以及种类 / 判决 / 对象是否仍与结论相称。所以「把 Lean 文件的内容换掉、路径不动」不再
能让记录继续挂着 `proved`——核不过就整笔拒绝（退出码 `2`），一个字段都不写。

上面这些检查加起来只说明这份证据**自洽**，而哈希是**自证**的：写文件的人同时写了被
引用的文件。于是手写一份自洽的假证据可以全部通过——实测手写
`{"kind":"witness_eval","verdict":"VERIFIED",…}` 连同它引用的见证，台账照收，把猜想
定成 `refuted`、档位 `exact_certificate`、反例盖上 `independent`。`verdict` 只是文件里的
一行字，没有任何东西验过它。所以 `load_evidence` 在**结构检查之后**加一道签名校验：
**没有签名或核不过就拒**（退出码 `2`，理由点出签名），并指路 `opl-sign init` 或
`opl-sign trust`。签名补的就是「这句话是谁说的」。

## 记录本身也签，核不过的记录只有三条出路

`save()` 写盘后同样签名；签名器不可用就**不写**（`MISSING`(4)），写了一半的会被清掉，
连同可能遗留的旧签名——盘上留一份没签名的记录，读的时候分不出它和手写的 JSON。

记录签名核不过，只可能是手写的、被工具之外的东西改过、或从别处拷来的：

- **读**如实标注：`opl-conj get` 的 JSON 里多一个 `"provenance": {"signed": false,
  "detail": …}`，并在 stderr 打印「未经证实」；`opl-conj list` 在行尾标
  `（未签名/签名核不过）`，并给一条汇总。
- **写**被拒（退出码 `2`），并告诉你两条出路。
- **可以人工收编**：`opl-conj set <id> … --adopt --confirmed-by <谁>`。

收编不是照单全收，而是**级联降级**：先记一条 `human_confirmations`（`what` 是
`adopt-unsigned-record`，note 里记着收编时**那份文件的哈希**）；随后按「档位压回
`empirical`」→「结论退回 `open`」→「核不过的复核章降成 `UNVERIFIED`」逐级降，每一步都进
`history` 并在 stderr 打印「降级：…」；三步走完仍不自洽就如实抛错——那是别的问题，
收编不替它兜底。签名正常时给 `--adopt` 会被拒（退出码 `2`）：静默忽略一个用户明确给的
开关，会让他以为自己刚做过什么。

## 已经踩过的坑

- **`#print axioms` 在无公理时打印 `'t' does not depend on any axioms`**，不是
  `depends on axioms: []`。只匹配后者会把最干净的证明判成「无法判定」。
- **`ssh-keygen -Y sign` 在 `<path>.sig` 已存在时会问 `Overwrite (y/n)?`**，非交互读到
  EOF 就什么都不做，而**退出码仍是 `0`**——于是「签名成功」其实是一份旧签名，内容一改
  立刻变成「签名核不过」。所以签名前先删旧签名、签完当场自验，不过就丢弃。与上面
  「编译通过」是同一条陷阱：**退出码 0 不是「事情做成了」**。
- **`lean --json` 下退出码仍然有效**，但 stdout 每行是一个 JSON 对象——不要拿
  行文本去 grep 判决。
- **无 import 的 Lean 文件连 `ℕ` 都不在作用域**，`(1:ℕ)+1=2` 会报
  `failed to synthesize instance`。最小可用导入是 `import Init`。

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
| `PROVED` | 0 | 内核接受，且公理 ⊆ `{propext, Classical.choice, Quot.sound}` | 可以定案为 `lean_checked` |
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
  原文件不动。
- 文件里其他没被点名的 `sorry` 不会被漏掉——工具另有一条**文件级**通道
  （`kind == "hasSorry"` 诊断），只要文件里有 `sorry` 就判 `SORRY_AX`。
  实测这个组合能抓到「被点名的定理干净、但旁边有个 ghost 带 sorry」的情形。
- 定理名打错时 `#print axioms` 会报 `Unknown constant` 且退出码 1 → `FAILED`。

## 已经踩过的坑

- **`#print axioms` 在无公理时打印 `'t' does not depend on any axioms`**，不是
  `depends on axioms: []`。只匹配后者会把最干净的证明判成「无法判定」。
- **`lean --json` 下退出码仍然有效**，但 stdout 每行是一个 JSON 对象——不要拿
  行文本去 grep 判决。
- **无 import 的 Lean 文件连 `ℕ` 都不在作用域**，`(1:ℕ)+1=2` 会报
  `failed to synthesize instance`。最小可用导入是 `import Init`。

---
name: opl-refute
description: 当需要为一个猜想寻找反例时；当需要排除某个有限域（断言「该范围内无反例」）时；当拿到一个疑似反例或一份证明需要独立复核时；当要把一次反例搜索的结论落进猜想台账时。
---

# 反例搜索：从猜想到可复核的结论

这个技能只做一件事——把一个**有限域上的判定问题**走成一条可复核的结论链。
任何一步的结论都不许跳过独立复核。

## 先想清楚：你的猜想能不能写成这个形状

本工具链处理的是**有限域约束规格**：找出一个满足全部约束的赋值。
语义约定是 **找到解 = 反例存在**；无解 = 在给定域内不存在反例。

规格是 JSON，由你写：

```json
{
  "name": "pigeonhole-4-3",
  "vars": [{"name": "y00", "lo": 0, "hi": 1}, {"name": "y01", "lo": 0, "hi": 1}],
  "constraints": [
    {"kind": "linear", "terms": [[1, "y00"], [1, "y01"]], "op": "==", "rhs": 1},
    {"kind": "alldiff", "vars": ["a", "b", "c"]}
  ]
}
```

- `vars`：整数变量与有限定义域（`lo`、`hi`）
- `linear`：`sum(coef * var)` 与 `rhs` 满足 `op`；`op` ∈ `== != <= >= < >`
- `alldiff`：所列变量两两不同

**两个硬约束**：
- 定义域必须有限且写死。这是「可自动验证」的前提。
- 若你无法把猜想写成这个形状，**如实说明**，不要用近似或抽样去代替——
  那会得到一个看起来像结论的东西。

## 五步

设规格在 `lab/C-0001.spec.json`，运行目录 `lab/runs/C-0001/`。

### 1. 登记

```bash
bin/opl-conj add --id C-0001 --title "短标题" \
  --statement "自然语言陈述，含全部前提" --source "<出处 URL 或文献>"
```

### 2. 编码，并让两条独立路径互相证伪

```bash
bin/opl-encode --spec lab/C-0001.spec.json --check-consistency
```

这一步把规格分别编成手写 CNF 与 CP-SAT 模型，各解一遍。**退出码 `1` 表示两条编码
结论矛盾，或某个见证不满足规格——那是编码错误，不是「无解」。** 先修编码。

编码代价超过闸门时返回 `2` 并说明哪种组合爆炸——**不要拉高上限去硬编**，
一个悄悄截断的编码会让后面的「无反例」毫无意义。

### 3. 搜索

```bash
bin/opl-search --spec lab/C-0001.spec.json \
  --cnf-out lab/runs/C-0001/formula.cnf \
  --witness-out lab/runs/C-0001/witness.json \
  --proof-out lab/runs/C-0001/proof.drat \
  --timeout 300
```

| 退出码 | 含义 | 下一步 |
|---|---|---|
| `0` 且写了见证 | 找到反例候选 | 走第 4a 步 |
| `0` 且写了证明 | 该域内无解 | 走第 4b 步 |
| `3` | 超时或求解器拒绝判定 | **不得**当作「无反例」；记下 reason，或换更大的 `--timeout` 重跑 |
| `4` | 缺求解器 | 如实报告缺失项，不换路径 |

### 4a. 复核见证（sat 侧）

```bash
bin/opl-encode --spec lab/C-0001.spec.json --eval-witness lab/runs/C-0001/witness.json
```

退出码 `0` 才算反例成立。这条路径是**规格的直接求值**，与任何编码器无关——
求解器说 sat 时它可能已经错了（编码把解排掉、或反解码翻错），这一步是唯一的裁决。

### 4b. 复核证明（unsat 侧）

```bash
bin/opl-certcheck --formula lab/runs/C-0001/formula.cnf \
  --cert lab/runs/C-0001/proof.drat \
  --evidence-out lab/evidence/C-0001.json
```

退出码 `0` 才算「该域内无反例」。`3` 表示无法判定（格式未识别、解析不完整、解压器坏了）——
**不许当成「证明无效」**，那是两件事。`1` 才是真的无效。

### 5. 定案

```bash
bin/opl-conj set C-0001 --formal-status refuted \
  --evidence lab/evidence/C-0001.json --verification-level exact_certificate
```

**不带 `--evidence` 会被拒绝写入（退出码 `2`）。** 这条纪律由工具强制，不是约定。

`verification_level` 只填你实际拿到的档：
`empirical` < `exact_certificate` < `lean_checked` < `human_peer_reviewed`。
只有见证经直接求值复核、或证明经独立检查器复核，才算 `exact_certificate`。

## 禁止事项

- 不得把 `unknown`（`3`）报成「无反例」。这是最严重的一类错。
- 不得把「已测试范围内未发现反例」改写成「无反例」。前者是 `empirical`。
- 不得用**截断证明**做负向对照。实测截断后 `drat-trim` 仍报 `VERIFIED`
  （正向传播自己就能导出冲突），拿它做验收会得到一个永远通过的假验收。
  要构造负向对照就**破坏内容**（翻转一个文字、改一个提示号）。
- 不得用 `Cadical195` 出证明。它在 PySAT 里 `with_proof=True` 时**静默返回空证明**，
  那比报错危险——下游会把「没有证明」当成「证明为空子句」。
  出证明用 `Glucose42` 或 `Lingeling`（`opl-search` 默认即是）。
- 不得用 `--timeout` 的返回值推断结论。超时是 `3`。

## 已经踩过的坑（省你重踩）

- **超时只能用 `--timeout`**。PySAT 的 `conf_budget` / `prop_budget` 在本机对
  Glucose42 完全无效——设成 0 仍照常解完。
- **CP-SAT 不产出可独立复核的证明**。要升到 `exact_certificate` 就必须走 SAT 路径出 DRAT。
- **空证明**：根层单元传播直接导出冲突时求解器可能不产出证明行。
  `opl-search` 会在 stderr 提示；此时该结论无法升到 `exact_certificate`。
- **`decompress` 是坏的**（上游 `read_lit` 内遗留 printf），`.clrat` 的还原路径不可用。
  改用 `drat-trim -L` 生成 LRAT，或直接用 DRAT。

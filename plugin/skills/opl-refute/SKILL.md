---
name: opl-refute
description: 当需要为一个猜想寻找反例时；当需要排除某个有限域（断言「该范围内无反例」）时；当拿到一个疑似反例或一份证明需要独立复核时；当要把一次反例搜索的结论落进猜想台账时。
---

# 反例搜索：从猜想到可复核的结论

这个技能只做一件事——把一个**有限域上的判定问题**走成一条可复核的结论链。
任何一步的结论都不许跳过独立复核。

```bash
# 下文用 $OPL 指代插件的 bin 目录。agent 的 cwd 是用户工作区，不是插件目录，
# 所以 `bin/opl-…` 这种写法会找不到命令——正确写法是 `$OPL/opl-…`。
OPL="${KIMI_PLUGIN_ROOT:-<插件根>}/bin"
```

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
$OPL/opl-conj add --id C-0001 --title "短标题" \
  --statement "自然语言陈述，含全部前提" --source "<出处 URL 或文献>"
```

### 2. 编码，并让两条独立路径互相证伪

```bash
$OPL/opl-encode --spec lab/C-0001.spec.json --check-consistency
```

这一步把规格分别编成手写 CNF 与 CP-SAT 模型，各解一遍。**退出码 `1` 表示两条编码
结论矛盾，或某个见证不满足规格——那是编码错误，不是「无解」。** 先修编码。

编码代价超过闸门时返回 `2` 并说明哪种组合爆炸——**不要拉高上限去硬编**，
一个悄悄截断的编码会让后面的「无反例」毫无意义。

### 3. 搜索

```bash
$OPL/opl-search --spec lab/C-0001.spec.json \
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
$OPL/opl-encode --spec lab/C-0001.spec.json \
  --eval-witness lab/runs/C-0001/witness.json \
  --evidence-out lab/evidence/C-0001.json
```

退出码 `0` 才算反例成立。这条路径是**规格的直接求值**，与任何编码器无关——
求解器说 sat 时它可能已经错了（编码把解排掉、或反解码翻错），这一步是唯一的裁决。

`--evidence-out` 是关键的一半：它把这句「复核过了」写成 `opl.evidence/1` 记录，
里面绑定了**规格与见证各自的 sha256**。裸的 `witness.json` 不是证据——它既证明不了
「谁复核的」，也证明不了「复核的是这份见证」。台账只认这种记录。

### 4b. 复核证明（unsat 侧）

```bash
$OPL/opl-certcheck --formula lab/runs/C-0001/formula.cnf \
  --cert lab/runs/C-0001/proof.drat \
  --evidence-out lab/evidence/C-0001.json
```

退出码 `0` 才算「该域内无反例」。`3` 表示无法判定（格式未识别、解析不完整、解压器坏了）——
**不许当成「证明无效」**，那是两件事。`1` 才是真的无效。

### 5. 定案 —— **两支的结论不同，别共用一条命令**

这是最容易写错的一步。sat 侧推翻的是**猜想**，unsat 侧推翻的只是**「该有限域内有反例」**：

```bash
# sat 侧：找到反例 → 猜想被推翻
$OPL/opl-conj set C-0001 --formal-status refuted \
  --evidence lab/evidence/C-0001.json --verification-level exact_certificate

# unsat 侧：该域内无解 → **不是**「猜想被推翻」，而是「这个范围内没有反例」
$OPL/opl-conj set C-0001 --formal-status no_counterexample_in_range \
  --verified-range 1..100 --method sat \
  --evidence lab/evidence/C-0001.json --verification-level exact_certificate
```

`no_counterexample_in_range` 之所以必须绑 `--verified-range`：**「没找到」只在说清
在哪个范围内时才有意义**。不写范围就写成 refuted，会把「我没有找到」记成「它不成立」。

**`--formal-status` / `--informal-status` 不带 `--evidence` 会被拒绝写入（退出码
`2`）。** 这条纪律由工具强制，不是约定。追加反例走的是另一条路：给不出可用的证据时
降级记 `UNVERIFIED`，不拒收。

**校验的对象是改完之后的整条记录，不是你这次传了哪些参数。** 工具先在副本上把改动
全部应用掉，再检查整条记录是否自洽；任何一处不自洽就**整笔拒绝**（退出码 `2`，
一个字段都不写），理由逐条列出。逐个参数补条件的写法每加一个入口就漏一个——只改
`--verified-range` 而不给新证据、把档位抬到依据支持不到的高度，都在这里被拦下。

**证据还必须与结论对得上**——四项绑定，缺一项就拒（退出码 `2`）：

| 绑定 | 规则 |
|---|---|
| 对象 | 证据的 `subject` 必须等于这次登记的猜想 id。**一份真证据不能给另一个猜想背书** |
| 方向 | `refuted` 要见证求值记录（`witness_eval`）、`no_counterexample_in_range` 要证书（`cert`）、`proved` 要 Lean 审计（`lean_audit`）。**见证求值说不了「没有反例」**，反过来也一样 |
| 范围 | `--verified-range` 必须与证据里记的范围**完全一致**。不一致时「该范围内没有反例」无法核对——只把范围改大而不换证据，就是在这里被拒 |
| 输入 | 每类证据必须带自己的文件与哈希（证书要 `certificate`+`formula`、见证要 `witness`+`spec`、Lean 要 `file`）。缺了它们，记录没有绑定到任何输入 |

**记录里存的只是这份证据的摘要，不是证据本身。** 每次写入都会按记录里的路径
**重新加载**那份证据：核对它自己的哈希、它引用的输入文件（见证、公式、Lean 文件）
的哈希是否仍然对得上，以及种类、判决、对象、范围是否仍与结论相符。**路径一致不等于
对象没变**——把被验证的见证文件换掉、路径不动，记录不会继续挂着 `exact_certificate`，
那一笔会被拒（退出码 `2`）。

生成证据时就把这些写进去：

```bash
$OPL/opl-certcheck --formula … --cert … --evidence-out lab/evidence/C-0001.json \
  --subject C-0001 --range 1..1000000
$OPL/opl-encode --spec … --eval-witness … --evidence-out lab/evidence/C-0001.json \
  --subject C-0001
```

**把反例追加进记录**用 `--add-counterexample`——它记的是「这一份见证推翻了猜想」，
与改结论是两件事，可以各自发生：

```bash
# 给的那串要与证据里记的 `witness` 逐字相同：`--eval-witness` 记的是绝对路径
$OPL/opl-conj set C-0001 --add-counterexample "$PWD/lab/runs/C-0001/witness.json" \
  --evidence lab/evidence/C-0001.json
```

复核章只盖在**证据里记着的那份见证**上，四道闸缺一不可：证据要能读出、种类必须是
`witness_eval`、判决必须是 `VERIFIED`、证据的 `subject` 必须是本猜想，追加的见证名还要
与证据里记的 `witness` 逐字相同（见证名不是路径时照样比对——留一个「不是路径所以没法
比」的豁免，等于换个写法就能把章挪走）。判决那道闸看着像走过场，其实是「复核过」三个字
的落点：一份 `verdict: NOT VERIFIED` 的见证（比如全零赋值违反规格、`opl-encode` 退出码
`1`）说的是「这份见证没通过复核」，它**不是**复核过的反例——**证据读得出来不等于证据
说它成立**。四道全过才写 `verified_by=independent`，并记下 `evidence_sha256` 与
`verified_witness`；缺任何一道只写 `verified_by=UNVERIFIED` 加一句警告——**降级而不
拒收**：台账的价值之一是留住「试过但没成」，把这种追加拒之门外，事后就看不到搜索做过
什么。对象那一道在读证据时就核对——所以「改结论必须带合格证据」那条硬纪律，就是它
和其余几道一起执行的。

**复核章不是盖上就完事。** 每次写入记录都会把已盖章的条目重新核一遍：按条目里的
`certificate` 路径**重新加载**证书，核它自己的哈希、判决、对象、见证，以及它引用的输入
文件的哈希是否还立得住。核不过就**整笔拒绝**（退出码 `2`）——盖章那一刻算得出来、
事后却核不了的章，只是一串字符串。旧记录里的章若引用不到证书文件，也照样在这一步被拦
下，而且拦的是**任何一次**写入，不只是这个反例本身。

追加反例不顶掉已有结论的依据：记录里的 `evidence` 只在改结论或升档时更新，反例的
依据记在它自己那条条目里。

**改结论会重新定档位**，不继承旧的：结论换成 `open` 就是 `empirical`，换成 `refuted`
而证据是见证记录就是 `exact_certificate`。档位说的是「这条结论的依据有多硬」——换了
结论就是换了依据，继承旧档位等于让新结论搭旧证据的便车；而且它不能高于这个结论加
这份证据支持到的档位。

`verification_level` 只填你实际拿到的档，而且**升档要证据支撑**：
`exact_certificate` 要求证据记录的 `verdict` 是 `VERIFIED`（`lean_checked` 要求
`proved`），证据的 `kind` 还得是已知种类（`cert` / `lean_audit` / `witness_eval`），
记录里引用的文件还必须与哈希对得上。只有 `{"schema": …, "verdict": …}` 的最小 JSON
定不了它该要求哪些绑定字段，**不足以升档**。指针非空 ≠ 复核过。

`human_peer_reviewed` 与 `faithfulness_checked` 是**人的判断**，要 `--confirmed-by`：

```bash
$OPL/opl-conj set C-0001 --verification-level human_peer_reviewed \
  --confirmed-by "谁" --confirmation-note "看了什么、为什么认可"
```

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

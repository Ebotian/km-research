# open-problem-lab —— 包内说明

这是 Kimi Code 插件的**可安装压缩包**解压后的内容。本文只说「这个包是什么、装在哪、
里头有什么、缺什么」，细节（设计取舍、24 篇调研、实现与计划的差异）在 `doc/` 里。

## 装

把整个目录作为插件装入宿主（本项目的用法是 `kimi.plugin.json` 所在目录即插件根）。
装好后 `skills/opl-entry` 会由清单的 `sessionStart.skill` 自动注入到会话，它把
「问题术语 → 本插件命令」的映射与退出码契约一次说清；其余四个技能按任务触发。

**装完第一件事是生成签名密钥**：

```bash
./bin/opl-sign init
```

写台账（`opl-conj`）与产出证据（`opl-certcheck` / `opl-encode --eval-witness` /
`opl-leancheck`）都要求它；没有密钥时这些命令以 `4 MISSING` 拒绝，并且**不留下半个
文件**。密钥生成在本机（`~/.config/open-problem-lab/`，`OPL_SIGNING_KEY` 可覆盖），
不进包、也不进沙箱。

## 包内有什么

```
bin/                 十二个命令（opl-capabilities / conj / encode / search / certcheck /
                     leancheck / run / evolve-init / evolve-suggest / evolve-eval /
                     evolve-show / sign）+ bin/third-party/
lib/                 全部逻辑（命令是薄壳，逻辑在 lib/，可类型检查）
skills/              五个技能：opl-entry / opl-refute / opl-formalize / opl-prove / opl-evolve
tests/fixtures/      运行时夹具（不只是测试用：能力探测要读 tiny.clrat 才能判定
                     decompress 坏了）
scripts/             typecheck.sh / regress.sh / build-zip.sh / verify-zip.sh / setup-third-party.sh
hooks/pre-commit     提交前跑类型检查 + 回归
doc/                 设计文档（Typst 源；本包不带编译好的 PDF）
THIRD-PARTY-NOTICES.md  随包分发的第三方许可声明
README.md            本文件
```

## 缺什么（如实说）

- **不含 Lean 项目**：证明侧链路（`opl-leancheck`）需要一个**定点**的 Lean 项目
  （目录里有 `lean-toolchain`）。缺它时报 `2` 或 `4` 并降级，**不伪造结论**；把
  `OPL_LEAN_PROJECT` 指向你自己的项目即可。
- **不含 `carcara`（约 30 MB）与 `decompress`**：它们只服务 Alethe 格式与部分压缩
  证书。缺它们时 `opl-certcheck` 在能力探测里如实报缺失并降级——这是设计行为，不是
  故障。随包的是 drat-trim / lrat-check / compress / gapless / cake_lpr。
- **不含本机 Python 环境**：`opl-capabilities` 会报告各解释器缺哪些模块
  （`missing_by_interpreter`），`split_brain` 字段检测「没有任何单一解释器同时满足一组
  依赖」的情况——缺依赖时报 `4`，不回退到估算。
- **不含运行过的东西**：没有 lab、没有台账、没有程序库、没有签名密钥。

## 自检

```bash
./scripts/typecheck.sh      # mypy + pyright + ty 三个检查器
./scripts/regress.sh        # 166 项退出码契约回归（夹具自包含）
```

要跑打包那条链（`verify-zip.sh`）需要的是**仓库**而不是这个包——它就是打包加解压验证。

## 文档

`doc/` 是设计文档的 Typst 源：

```bash
typst compile doc/main.typ 输出.pdf
```

它分两部分：第一部分是设计方案（架构、工具链、技能、数据模型、验证纪律、路线图、风险），
第二部分是支撑决策的 24 篇专题调研。**第九章「实现与计划的差异」是刻意放在最后的诚实
清单**：哪些计划项没有实现、哪些做成了另一个样子，逐条列在那里。

一处口径差异要提前说：文档里引用的路径写的是**仓库布局**（`plugin/scripts/...`、根
`README.md`），而这个包里少了 `plugin/` 这一层——同一个文件在包内是 `./scripts/...`。

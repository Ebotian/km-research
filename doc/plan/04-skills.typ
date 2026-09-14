= 技能集

== 组织原则

技能是「判据与流程」的载体，不是文档仓库。调研给出三条硬约束：

- *description 只写触发条件与症状，绝不写步骤摘要*。否则模型照描述走而不读正文——这是「技能描述太泛导致不触发」与「描述即流程导致正文被跳过」两种失效的共同根源。
- *三层渐进披露加硬预算*。系统提示只放技能名、描述与路径（实测插件技能归入 `Extra` 段）；正文按需注入，单文件正文压在 500 行以内；深材料（定理库索引、基准套件参数、反例构造手册）放同级 `references/`，可执行脚本放同级 `scripts/`。*资源不被正文显式引用等于不存在*。
- *确定性逻辑不进技能*。凡是脚本能做的（形式化检查、跑分、结果解析）都放 `bin/` 下的命令或同级 `scripts/`，技能只写判据。

技能名一律带 `opl-` 前缀。原因是实测优先级为 内置 0 小于 插件 5 小于 `Extra` 10 小于 用户 20 小于 项目 30，即插件技能会被同名项目或用户技能静默覆盖。

== 技能清单

#table(
  columns: (auto, 1fr),
  table.header([*技能*], [*触发条件（写进 description 的内容）*]),
  [`opl-entry`], [会话开始即注入的总纲与路由：哪类研究任务必须先查哪个技能、工具的映射、以及不可协商的验证纪律],
  [`opl-formalize`], [当需要把一个自然语言猜想转成可编译的 Lean 陈述时；当需要评估一个已有陈述的忠实度时],
  [`opl-refute`], [当需要为猜想寻找反例时；当需要排除某个有限域时；当拿到一个疑似反例需要独立复核时],
  [`opl-prove`], [当需要在 Lean 中搜索证明时；当证明中出现 `sorry` 或非白名单公理时],
  [`opl-evolve`], [当需要为一个算法问题寻找更好的实现或上界，且存在确定性评估器时],
  [`opl-benchmark`], [当需要比较两个算法或两组配置时；当需要对含超时实例的运行时间做统计时],
  [`opl-report`], [当需要把一次或多次运行整理成可读报告时；当需要更新猜想台账状态时],
)

七个技能覆盖一条完整往返：`opl-entry` 路由，`opl-formalize` 与 `opl-refute` / `opl-prove` 构成攻防两侧，`opl-evolve` 负责算法上界改进，`opl-benchmark` 负责实证评估，`opl-report` 负责沉淀。`opl-entry` 通过清单的 `sessionStart.skill` 挂载，作用是把「问题术语到本插件工具调用」的映射一次性注入，而不是每次对话重复解释。

== 各技能正文要点

`opl-entry` 是最短也最硬的一个。它只做三件事：声明验证器否决权、声明三态逻辑、给出任务到技能的映射表。它不描述任何问题的解法。

`opl-formalize` 的正文必须包含忠实度检查清单，因为这是自动化最薄弱的环节。清单至少覆盖：量词顺序与作用域、是否隐含了「非空」「有限」「非退化」等前提、`ℕ` 与 `ℤ` 的边界、以及收敛/极限的表述方式。技能须明确要求：形式化状态在人工确认前停在 `compiles`。

`opl-refute` 是使用频率最高的技能。它要求反例搜索必须满足四项：显式有限域、可命名假设、三态输出、证书落盘。同时在正文里写明*禁止事项*：不得把 `unknown` 报为 `unsat`，不得把「未在测试范围内找到反例」表述为「无反例」。

`opl-prove` 复述证明循环：`Plan → Work → Checkpoint → Review → Replan → Stop`。它把 `lake env lean <file>` 用于文件级门、`lake build` 只在检查点使用，并强制每次验证输出 `#print axioms` 结果。

`opl-evolve` 要求研究者写死骨架、模型只填一个函数，可进化区域用 `EVOLVE-BLOCK-START/END` 标记框死；同时要求评估器的确定性、纯函数、可在无网络沙箱重跑。

`opl-benchmark` 固化统计路径而不是暴露「自己挑一个检验」的开关：校正后正态性检验，再 Bartlett 或 Levene 方差齐性，再配对 t 或 Wilcoxon 符号秩，再多组 rmANOVA 加 Tukey 或 Friedman 加 Nemenyi；校正方法与随机种子写入记录的分析字段。

`opl-report` 约束报告的生成方式：报告只读 `CSV` / `JSON` / `YAML`，不内嵌计算；台账视图是生成物，不是人工维护的第二份真源。

== 入口技能与清单字段

清单中需要显式列出的字段：

#table(
  columns: (auto, 1fr),
  table.header([*字段*], [*取值与理由*]),
  [`skills`], [`["./skills/opl-entry/", "./skills/opl-formalize/", ...]`。必须显式列出：省略该字段会进入 root-skill-only 模式，只认根 `SKILL.md`],
  [`sessionStart`], [`{skill: "opl-entry"}`。参照 `superpowers` 的真实用法],
  [`mcpServers`], [*本项目不声明*。能力以 `bin/` 下的可执行文件提供，不注册 `MCP` 服务器；仅当某些环境确需 `MCP` 入口时才加一个 0 到 2 个工具的薄适配层],
)

清单不声明 `mcpServers`，因此 `bin/` 下的命令靠 `KIMI_PLUGIN_ROOT` 定位（插件自身用 `OPL_BINDIR` 覆盖，便于测试）。权限上不需要 `MCP` 工具名，直接用 `ToolName(arg-pattern)` 形式的规则约束命令行，例如按前缀 allow 或 deny `Bash(opl-*)`。

调研确认清单内*没有任何* `${PLUGIN_ROOT}` 类占位符，运行期只注入环境变量 `KIMI_PLUGIN_ROOT` 与 `KIMI_CODE_HOME`。也不存在官方 JSON Schema 校验（`$schema` 指向的地址实测返回官网页面而非 schema），`name` 字段是唯一必填且唯一致命项，其余字段问题一律降级为诊断。

因此本项目不使用 Claude 生态的 `hooks/hooks.json` 形态。Kimi 的 hooks 是扁平数组 `{event, matcher, command, timeout}`，且为 fail-open（非零退出、超时、崩溃均放行），只能用于告警，不能充当安全边界。真实约束应写进权限规则的静态拒绝项。

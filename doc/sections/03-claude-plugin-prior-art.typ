== Claude Code 插件与技能生态：前车之鉴

本节结论分两类：附 URL 的为一手事实（官方文档与 GitHub 目录，核对日期 2026-09-14）；标注「推断」的为本次调研的判断。条目数、字段名与 token 预算均来自实时读取原始 catalog / 文档（本机 `gh api` / `curl` 只读核实），未做二手转述。

=== 官方市场：仓库结构与 marketplace.json

Claude Code 维护两个官方市场，都以 GitHub 仓库形式公开：#link("https://github.com/anthropics/claude-plugins-official")[claude-plugins-official]（Anthropic 策展，首次交互式启动时自动注册，也可 `claude plugin marketplace add anthropics/claude-plugins-official`）与 #link("https://github.com/anthropics/claude-plugins-community")[claude-community]（第三方提交经审核后进入，`/plugin marketplace add anthropics/claude-plugins-community`）。#link("https://docs.claude.com/en/docs/claude-code/plugins")[plugins 文档]

- 目录仓库骨架：`.claude-plugin/marketplace.json` 是唯一的索引文件；`plugins/` 放 Anthropic 自研插件（实测 39 个目录），`external_plugins/` 放合作方插件（实测 14 个目录）。插件代码本身不在索引文件里。
- 插件名是*不可变 slug*：官方 README 明确 `name` 一旦发布不得更改，UI 改名用 `displayName`；确要改名则写顶层 `renames` 映射，让老安装自动迁移。
- 市场级必填字段：`name`（kebab-case，每个用户同名市场只能注册一个）、`owner`、`plugins`；可选 `$schema`、`description`、`version`、`metadata.pluginRoot`、`allowCrossMarketplaceDependenciesOn`、`renames`。#link("https://docs.claude.com/en/docs/claude-code/plugin-marketplaces")[marketplaces 文档]
- 插件条目：必填 `name` + `source`，可叠加插件清单字段（`description`、`version`、`author`、`homepage`、`repository`、`license`、`keywords`、`metadata`）与仅市场可用字段 `category`、`tags`、`strict`、`relevance`、`headers`、`headersHelper`、`defaultEnabled`、`displayName`。相对路径 source 的条目在安装前即可读到 `plugin.json`，其它 source 类型只有条目自身字段可见。

`source` 的七种形态（同一文档列出，含各自代价）：

#table(
  columns: 3,
  [*类型*], [*字段*], [*用途与代价*],
  [`路径`], [`"./plugins/x"`], [市场仓库内的相对路径，禁止 `../`；可用 `metadata.pluginRoot` 写裸名],
  [`github`], [`repo`, `ref?`, `sha?`], [`owner/repo`，GitHub 缩写默认走 SSH],
  [`url`], [`url`, `ref?`, `sha?`], [任意 git 主机；`ref` 与 `sha` 同时存在时 `sha` 生效],
  [`git-subdir`], [`url`, `path`, `ref?`, `sha?`], [monorepo 稀疏克隆，官方目录的主力形态],
  [`npm`], [`package`, `version?`, `registry?`], [走 `npm install` 到插件缓存],
  [`archive`], [`url`, `sha256?`], [HTTPS zip，无需 git/npm；超过 256 MiB 拒绝],
  [`command`], [`command`, `timeout?`, `mode?`], [本地工具现场产出插件目录，每会话重跑一次],
)

- 实测规模：官方目录 296 条；社区目录 `claude-community` 2282 条，其中 1876 条用 `url`、401 条用 `git-subdir`，几乎每条都带 40 位 `sha` 钉死 commit；分类字段大面积缺省（2125 条无 `category`）。社区索引单文件 1,565,989 字节，已超过 GitHub Contents API 的 1 MB 返回上限，只能走 raw URL 读取。
- 安装后插件被复制进 `~/.claude/plugins/cache`（`command` source 的 link 模式除外）；更新语义由版本决定：显式 `version` / 解析出的 commit sha / `sha256` 摘要三选一。
- `strict: false` 时市场条目即插件的完整定义。官方用它收录"源码仓库只有 `SKILL.md`、没有 `plugin.json`"的技能包：条目里列 `skills: ["./skill-a", "./skill-b"]`，路径相对 `source.path`，每个技能注册为 `<plugin-name>:<skill-name>`。

官方目录第一条条目的真实形态（节选，2026-09-14 读取）：

```json
{
  "$schema": "https://json.schemastore.org/claude-code-marketplace.json",
  "name": "claude-plugins-official",
  "owner": { "name": "Anthropic", "email": "support@anthropic.com" },
  "plugins": [
    {
      "name": "42crunch-api-security-testing",
      "description": "Automate API security directly in Claude Code ...",
      "author": { "name": "42Crunch" },
      "category": "security",
      "source": {
        "source": "git-subdir",
        "url": "https://github.com/42Crunch-AI/claude-plugins.git",
        "path": "plugins/api-security-testing",
        "ref": "v1.5.5",
        "sha": "30287f5e3f122a646d1ac5ca3ab96e130c52a3ad"
      },
      "homepage": "https://42crunch.com"
    }
  ]
}
```

- 治理与质量门：提交前本地跑 `claude plugin validate ./your-plugin`（`--strict` 把警告升级为错误），审核流水线跑同一检查加自动安全筛查；被收录的插件在市场目录里钉到具体 commit SHA，CI 在你推新 commit 后自动更新钉点；社区目录每晚从审核流水线同步，因此批准到出现有延迟。官方目录另行策展，没有申请入口。
- 目录自身的告警值得抄：官方 README 顶部声明 Anthropic 不控制插件内的 MCP server 与文件、无法验证其行为或后续变化，安装前需自行判断 —— 这是市场作为分发渠道的责任边界写法。

=== 社区市场：组织方式与成功模式

两种仓库形态：插件仓库加独立策展目录仓库（obra/superpowers 与 obra/superpowers-marketplace）；或单仓同时承载插件与目录（wshobson/agents、anthropics/claude-code）。

- superpowers 本体只有 `skills/` 与 `hooks/`，没有 `commands/`、`agents/`、`.mcp.json`（本机安装副本核对）。它靠 SessionStart hook 注入 `using-superpowers` 技能，强制"任何回答前先查技能"，把"技能存在"变成"技能被用"。
- superpowers 单仓携带 9 个 harness 清单目录：`.claude-plugin`、`.codex-plugin`、`.cursor-plugin`、`.devin-plugin`、`.hermes-plugin`、`.kimi-plugin`、`.opencode`、`.pi`、`.agents`。同一套 skills，按 harness 各写一份 manifest；`.kimi-plugin/plugin.json` 里用 `sessionStart.skill` 指定启动技能，另有 `skillInstructions` 做工具名映射。
- 其 `.claude-plugin/marketplace.json` 只列一条插件、`"source": "./"`：市场文件可以零成本长在插件仓库里，不必单开仓库。#link("https://github.com/obra/superpowers")[obra/superpowers]
- wshobson/agents 自称 94 plugins / 202 agents / 183 skills / 105 commands，卖点是 "granular installation and minimal token usage"；实现上是单一 `plugins/` 源加每 harness 清单（实测 92 个 `.claude-plugin/plugin.json`、92 个 `.codex-plugin/plugin.json`、183 个 `SKILL.md`、6 个 `hooks/` 目录，而 `.mcp.json` 只有 1 个）。#link("https://github.com/wshobson/agents")[wshobson/agents]
- 「推断」可复制的成功模式有三条：(1) 技能只写流程知识与判据，不写 API 手册；(2) 一个会话启动钩子把技能发现变成硬约束；(3) 同一内容按 harness 各出原生清单，而不是做最低公分母翻译。
- 「推断」另一个信号：社区侧的 `gh skill` / `npx skills` 安装器可直接从 `plugins/*/skills/` 装技能，绕过市场与安装步骤 —— 技能是生态里最可移植的单元。

=== SKILL.md 规范与最佳实践

- 开放标准（Agent Skills）要求：技能是含 `SKILL.md` 的目录；frontmatter 必填 `name`（≤64 字符，小写字母数字与连字符，必须与父目录同名）与 `description`（≤1024 字符，写"做什么 + 何时用"并含关键词）；可选 `license`、`compatibility`（≤500 字符）、`metadata`（字符串映射）、`allowed-tools`（空格分隔，标准里标注为实验性）。推荐目录 `scripts/`、`references/`、`assets/`。#link("https://agentskills.io/specification")[Agent Skills specification]
- 渐进披露三层，附官方给的 token 量级：metadata 常驻上下文（约 100 tokens）→ 触发时加载 SKILL.md 正文（建议少于 5000 tokens，文件保持在 500 行以内）→ `references/`、`scripts/`、`assets/` 按需读取。脚本可以执行而不进上下文，所以"资源层"实质不设上限。#link("https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills")[Anthropic 工程博客]
- Claude Code 的 frontmatter 是标准的超集，多出 `when_to_use`、`disable-model-invocation`、`user-invocable`、`allowed-tools`、`disallowed-tools`、`context: fork`、`agent`、`background`、`hooks`、`paths`、`model`、`effort`、`shell` 等。标准六字段之外的字段在 claude.ai 上传与 Skills API 路径会报 unexpected-key，同一份技能要跨产品复用就必须只用六字段。#link("https://docs.claude.com/en/docs/claude-code/skills")[skills 文档]
- 列表预算（最容易被忽略的数字）：所有技能的名字与描述常驻上下文，预算按模型上下文窗口的 *1%* 计算（`skillListingBudgetFraction`，或固定字符数的 `SLASH_COMMAND_TOOL_CHAR_BUDGET`）；单条 description 加 when_to_use 有 *1,536 字符*硬上限（`skillListingMaxDescChars`）；预算溢出时从调用最少的技能开始丢描述，最坏情况是关键词被截掉后永不触发。
- 压缩代价：会话自动压缩时，每个技能最近一次调用会被重新挂载，各取前 5,000 tokens，共享 25,000 tokens 总预算，按最近调用优先；一次会话触发的技能一多，早先的技能会被整体丢弃。
- 描述写法（官方 plugin-dev 插件的 Skill Development 技能）：用第三人称，给出用户原话式的触发短语（如 "create a hook"、"add a PreToolUse hook"）；正文用祈使句；正文目标 1,500–2,000 词，超出部分移入 `references/`；技能内必须显式列出资源文件路径，否则等于不存在。该技能还列了四类反例：描述含糊、`SKILL.md` 过大、第二人称、资源未被引用。#link("https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/skill-development/SKILL.md")[plugin-dev: skill-development]
- `allowed-tools` 的真实语义：只在"调用该技能的那一轮"内预批准列出的工具，用户下一条消息后授权即失效；它*不*收窄可用工具集合（要收窄得用 `disallowed-tools`）。把"技能内容常驻、权限一轮一清"当作默认假设。

字段清单对应的最小骨架（字段名取自上述规范，取值仅示范格式）：

```yaml
name: counterexample-search        # 必须与父目录同名，且只含小写字母数字与连字符
description: 当需要为一个数学猜想寻找反例、或需要验证候选反例是否成立时使用
allowed-tools: Bash Read Write     # 只在本轮预批准，不限制可用工具集合
compatibility: 需要 python3 与本地求解器二进制
```

技能的目录约定（三层披露的物理对应）：

```text
skill-name/
├── SKILL.md          # 常驻上下文的只有 name + description；正文在触发时才读
├── references/       # 大块参考，按需读：定理库索引、基准参数与判据
├── scripts/          # 可执行代码：执行而不进上下文，最省 token 的一层
└── assets/           # 输出用模板与数据，通常完全不进上下文
```

=== 五类扩展的分工

#table(
  columns: 4,
  [*扩展*], [*位置与格式*], [*触发方*], [*该放什么*],
  [`skills/`], [`<name>/SKILL.md`], [模型按 description 自动调用], [多步流程、领域判断、需要渐进披露的参考],
  [`commands/`], [扁平 `.md`], [用户输入 `/name`], [用户手动触发的固定工作流；文档已建议新插件改用 `skills/`],
  [`agents/`], [`agents/*.md`], [模型自动调用或 `@` 提及], [需要独立上下文窗口、独立模型与工具集的子任务],
  [`hooks/`], [`hooks/hooks.json`], [生命周期事件确定性触发], [必须发生的注入与拦截：SessionStart 注入、PreToolUse 校验],
  [`.mcp.json`], [标准 MCP 配置], [模型调用其中的工具], [访问外部系统；工具必须按服务与资源命名空间化],
)

- 组件必须位于插件根目录，`.claude-plugin/` 只放 `plugin.json`；组件路径必须相对且不能越出插件目录（越界报 `path escapes plugin directory`，插件仍加载但该组件缺失）。
- 插件自带 MCP 工具的调用名是 `mcp__plugin_<plugin-name>_<server-name>__<tool>`；针对它的 hook 匹配器若写裸 server key 将永不命中。
- 实测分工倾向：wshobson/agents 里 183 个技能、284 个 agent 文件、158 个 command 文件，而 `.mcp.json` 只有 1 个 —— 价值集中在 skills / agents / commands，MCP 只在必须触达外部系统时出现。「推断」本项目的算法研究插件应保持同一比例：求解器与基准调用放 MCP 或 `scripts/`，方法论、判据与失败模式解读放技能。
- 插件技能的命令名带前缀 `/plugin-name:skill-name`，frontmatter 的 `name` 决定最后一段；不设 `name` 时回落到目录名。
- 官方还有几类未在标题列出的扩展：`.lsp.json`（语言智能）、`monitors/monitors.json`（后台监视，进程 stdout 逐行变成通知，仅交互式会话可用）、`output-styles/`、`bin/`（目录内可执行文件加入 Bash 的 PATH）。

`plugin.json` 里声明这五类的写法（字段名取自 #link("https://docs.claude.com/en/docs/claude-code/plugins-reference")[plugins reference]）：

```json
{
  "name": "open-problem-lab",
  "version": "0.1.0",
  "skills": ["./skills/"],
  "commands": ["./commands/"],
  "agents": ["./agents/"],
  "hooks": "./hooks/hooks.json",
  "mcpServers": {
    "solvers": { "command": "node", "args": ["./bin/solvers.mjs"] }
  },
  "dependencies": [{ "name": "secrets-vault", "version": "~2.1.0" }]
}
```

- 组件路径字段的语义不统一，是踩坑点：`skills` 是*追加*到默认 `skills/` 扫描，而 `commands`、`agents`、`outputStyles`、`experimental.monitors` 是*替换*对应默认目录（写了 `commands` 就不再扫默认 `commands/`，要保留须显式列 `"./commands/"`）；`hooks`、`mcpServers`、`lspServers` 各自有合并规则。默认目录与清单键同时存在时 `claude plugin list` 会告警。
- 需要密钥或路径参数时用 `userConfig`：值可在 MCP/LSP 配置与 hook 命令里以 `${user_config.KEY}` 替换，并以 `CLAUDE_PLUGIN_OPTION_<KEY>` 环境变量导出给 hook 进程；shell 形式的命令拒绝 `${user_config.*}` 替换（防注入），须改用 exec 形式或从环境变量读。

=== 常见失败模式

- *描述太泛导致不触发*：官方排障清单第一条即"检查 description 是否包含用户会自然说出的关键词"，并建议用 `claude plugin validate` 检查 frontmatter。
- *frontmatter YAML 解析失败是静默降级*：正文照常加载、`/name` 照常可用，但 metadata 为空，模型永远匹配不上描述。#link("https://docs.claude.com/en/docs/claude-code/skills")[skills 文档排障]
- *描述里写了流程，模型就照描述执行而不读正文*：superpowers 的 `writing-skills` 记录了对照实验 —— 描述写成 "code review between tasks" 时模型只做了一次评审，而技能正文的流程图要求两阶段评审（规格合规 + 代码质量）；描述改成只写触发条件后行为恢复正确。这是社区一手证据（本机安装副本），不是 Anthropic 官方陈述。
- *描述太细或技能过多导致触发过多与预算溢出*：官方对策是收紧 description、对只需手动的技能设 `disable-model-invocation: true`，以及用 `skillOverrides` 把低优先级技能降为 "name-only" 或 "off"。
- *上下文爆炸有四个可量化入口*：技能列预算占上下文 1%、单条描述 1,536 字符、压缩后每技能 5,000 与合计 25,000 tokens、正文建议少于 5,000 tokens。任一被忽略，症状都是"关键词被截断"或"技能被整体丢弃"，而不是报错。
- *工具过多或功能重叠导致选择错误*：Anthropic 的工具写作指南指出工具数量多、职责重叠会让 agent 困惑于该用哪个，主张按服务与资源命名空间化、把常见链路合并成单个工具、响应分页并设默认截断（Claude Code 默认单次工具响应上限 25,000 tokens）。#link("https://www.anthropic.com/engineering/writing-tools-for-agents")[writing tools for agents]
- *把工具做成 API 镜像*：同一篇文章明确反对把现有 API 与函数逐个包成工具，主张只做少量面向高价值工作流的工具；`list_*` 这类"返回全部再让模型筛"的形态是典型反模式。
- *部署期坑*：插件被复制进缓存，引用插件目录之外的文件（`../shared.md`）不生效，要用 `${CLAUDE_PLUGIN_ROOT}`（跨更新持久状态用 `${CLAUDE_PLUGIN_DATA}`）；hook 脚本必须可执行（`chmod +x`）；会话中更新插件后 hooks 与 MCP 仍指向旧路径，需 `/reload-plugins`。
- *安全面*：技能可以给自己授予宽泛的工具权限，且项目技能的 `allowed-tools` 在未信任的工作区也会生效 —— 安装第三方技能前应审计正文与 `allowed-tools`。

症状到机制的速查（用于自查而不是猜测）：

#table(
  columns: 3,
  [*症状*], [*机制*], [*对策*],
  [该触发却不触发], [description 缺关键词，或 YAML 解析失败导致 metadata 为空], [写用户原话式触发短语；`claude plugin validate` 查解析错误],
  [到处触发], [description 过泛，或技能过多互相竞争], [收紧描述；只需手动的技能设 `disable-model-invocation: true`],
  [描述被截断、关键词丢失], [列表预算为上下文的 1%，溢出时先丢低频技能的描述], [关键用例放在描述开头；`skillOverrides` 把低频技能设为 name-only],
  [会话变长后技能失效], [压缩只重挂最近调用，每技能 5,000、合计 25,000 tokens], [技能少而精；纪律性内容放进常驻的索引技能],
  [agent 选错工具], [工具数量多、职责重叠、命名无边界], [命名空间化；合并常见调用链；只做少量高价值工具],
  [插件装了但组件缺失], [组件放进了 `.claude-plugin/`，或用了绝对路径与越界路径], [组件放插件根；路径以 `./` 开头；脚本用 `${CLAUDE_PLUGIN_ROOT}` 引用],
)

=== 评估

- *抄「三层渐进披露加硬预算」*：本插件每个技能的 SKILL.md 正文压在 500 行 / 5,000 tokens 以内，把 Lean 定理库索引与命名约定、基准套件参数与判据、反例构造手册放进 `references/`，把可执行脚本放进 `scripts/`，并在技能正文里显式列出这些路径 —— 资源不被引用等于不存在。
- *抄「启动即索引」机制*：用 `.kimi-plugin/plugin.json` 的 `sessionStart.skill`（superpowers 已给出真实样例）挂一个总纲技能，写清"哪类研究任务必须先查哪个技能"，把技能发现变成纪律而不是模型自觉。
- *抄「可度量的触发率」*：借鉴 `claude plugin eval` 的 with/without 护栏（每个 prompt 多轮、与不带插件的基线对比），本插件自建一组真实研究 prompt 用于测"技能是否在该触发时触发"，每次改描述后重跑，而不是凭手感调 description。
- *避免「描述即流程」*：开放问题类技能的 description 只写触发条件与症状（例如"当需要把一个猜想形式化时""当需要搜索反例时"），绝不写步骤摘要，否则模型会照描述走而不读正文。
- *避免「一个求解器一个工具」*：本机 z3、cvc5、sage、gap、pari/gp 均未安装，把工具面铺成每个求解器一个工具会同时踩"未安装即不可用"与"工具重叠导致选择错误"两个坑；应做 3–5 个按任务切分的工具（如定理检索、反例搜索、基准运行），统一前缀命名空间、响应分页并设默认截断（对齐 25,000 tokens 量级），把"如何用"留在技能里。
- *避免「技能与工具职责重叠」*：凡是确定性脚本能做的（形式化检查、跑分、结果解析）都放 `scripts/` 或 MCP 由代码执行，技能只描述判据与流程；同一知识只在 SKILL.md 或 `references/` 之一处存在，禁止两处重复。

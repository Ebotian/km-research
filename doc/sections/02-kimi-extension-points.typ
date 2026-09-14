== Kimi Code 的扩展点全景

本节覆盖六个可编程扩展面：agent profile、skills 目录、hooks、MCP、权限模式、子代理。所有机制以本机实测的 Kimi Code `0.42.0`（`kimi --version`）为准；`kimi --help` 已实机确认 `--agent`、`--agent-file`、`--skills-dir`、`--plan`、`-y/--yolo`、`--auto`、`--add-dir`、`--output-format` 这些开关存在。文中每条标 `一手事实`（官方文档原文所述）或 `推断`（本项目据此作的判断），二者不混用。

=== (a) Agent profile：`--agent` 与 `--agent-file`

*开关语义*（`一手事实`）：

- `--agent <name>`：新会话以该 agent 作为主 agent，名字可以是内置的或任何被发现的自定义 agent；未知名字直接报错并列出可用项。
- `--agent-file <path>`：本次启动加载*恰好一个* agent 文件并置于最高优先级；不可重复、不可与 `--agent` 同用。
- 两者都只作用于*新建*会话，不能与 `--session` / `--continue` 组合。agent 在会话首次绑定时固定，之后不可切换；恢复会话时自动沿用已绑定的 agent。
- 在 `kimi -p` 打印模式下同样可用。

*文件格式*：纯 Markdown，顶部 YAML frontmatter。frontmatter 声明元数据，正文即 system prompt。

```markdown
---
name: reviewer
description: Strict code reviewer that reports severity-ranked findings
whenToUse: Code reviews and PR checks
override: false
tools:
  - Read
  - Grep
  - Glob
  - mcp__github__*
disallowedTools:
  - Bash
subagents:
  - explore
---

You are a strict code reviewer. ${cwd} 是你的工作目录。最后一条消息必须是完整自足的交接结果。
```

#table(columns: 2,
  [*字段*], [*语义（`一手事实`）*],
  [`name`], [可选，kebab-case；缺省回退为文件名。文档另有一处说明「非 kebab-case 名称会被警告并跳过」，两处表述不完全一致，以本机实测为准],
  [`description`], [必填。主 agent 据此决定是否委派，应当写成能指导委派的描述],
  [`whenToUse`], [可选，补充「何时该用」的提示],
  [`override`], [默认 `false`。目录发现的文件只有显式写 `override: true` 才能顶替同名*内置* agent；`--agent-file` 不需要它],
  [`tools`], [工具白名单。YAML 列表或逗号分隔字符串；省略或写单个 `*` 表示全部允许，`tools: []` 表示全部禁用],
  [`disallowedTools`], [黑名单，同样的语法与匹配规则，在 `tools` 之后生效],
  [`subagents`], [子代理白名单，语法同 `tools`。省略则继承内置默认（`coder`、`explore`、`plan`）；单个 `*` 表示允许所有类型],
)

*匹配规则的坑*（`一手事实`）：内置与用户工具按精确、区分大小写匹配；以 `mcp__` 开头的条目按 glob 匹配 MCP 工具。三种写法永远匹配不到东西且会告警：`mcp__` 模式之外的裸 `*`（`disallowedTools: ["*"]` 什么都不禁）、缺工具段的 `mcp__github`（整台服务器要写 `mcp__github__*`）、拼错的工具名（如 `read` 而非 `Read`）。`tools` / `disallowedTools` 既塑造模型可见的工具列表，又在执行前二次强制；`subagents` 同样被 `Agent` 与 `AgentSwarm` 在派发前复查，*恢复*已有子代理是唯一豁免。

*正文模板变量*（`一手事实`）：正文每次构建 prompt 时按模板渲染，`${var}` 替换为实时上下文，未知变量原样保留，孤立 `$` 不特殊，无值的变量渲染为空串。可用变量：`${base_prompt}`（生效中的默认 system prompt）、`${plugin_sections}`（插件贡献的指令块）、`${skills}`、`${agents_md}`、`${cwd}`、`${cwd_listing}`、`${os}`、`${shell}`、`${now}`、`${additional_dirs_info}`。想让自定义主 agent 保留环境/技能/插件注入，正文里引用 `${base_prompt}`；只保留插件指令则用 `${plugin_sections}`；两者都不写就*完全拥有*整个 prompt（自足型子代理适用）。

*发现顺序与优先级*（`一手事实`）：`--agent-file`（显式） > 项目级 > Extra > 用户级 > 插件级 > 内置。项目根 = 从工作目录向上最近的含 `.git` 的目录。

作用域目录（`一手事实`）：用户级为 `$KIMI_CODE_HOME/agents/`（默认 `~/.kimi-code/agents/`）与 `~/.agents/agents/`；项目级为 `.kimi-code/agents/` 与 `.agents/agents/`；Extra 由 `config.toml` 顶层 `extra_agent_dirs = ["~/team-agents", ".agents/team-agents"]` 声明；插件级取清单 `agents` 字段，省略时自动拾取插件根下的 `agents/`（插件 agent 只高于内置 agent）。每个目录递归扫描 `.md`。

*信任模型值得单独强调*（`一手事实`）：项目级 agent 文件来自仓库本身，命名 `agent.md` 并写 `override: true` 会整体替换默认主 agent 的 system prompt，且不带 `tools` 列表的文件保留全部工具——这与 `AGENTS.md`（作为参考资料注入）性质完全不同。克隆陌生仓库后先看 `.kimi-code/agents/` 再运行，是必要的操作纪律。

*SYSTEM.md 旁路*（`一手事实`）：`$KIMI_CODE_HOME/SYSTEM.md`（默认 `~/.kimi-code/SYSTEM.md`）非空时永久替换默认主 agent 的 system prompt（只替换 prompt，description / 工具集 / 委派白名单仍继承内置默认）；不需要 frontmatter；被项目级 `override: true` 文件和 `--agent-file` 压过；用 `--agent` 选别的 agent 则完全绕过它。用户作用域内 SYSTEM.md 胜出同名 agent 文件。

*一个易漏的差异*（`一手事实`）：自定义 agent 被当作子代理委派时，*不*带内置子代理的收尾框架（内置框架会说「你的最后一条消息就是全部交接」）。所以给委派用的 agent 必须在正文里自己写明「最后一条消息须是完整、自足的结果」。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/agents.html")[customization/agents]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html")[reference/kimi-command]。

=== (b) `--skills-dir` 的语义

`一手事实`：`--skills-dir <dir>` 是*替换*而非叠加——它「替换本次启动自动发现的用户级与项目级目录」，可重复以堆叠多个目录。与 `config.toml` 顶层 `extra_skill_dirs` 的语义正好相反：后者是在自动发现的目录*之上*追加，且永久生效，适合团队共享技能。`merge_all_available_skills`（默认 `true`）控制是否合并所有可用目录的技能。

```sh
kimi --skills-dir /path/to/team-skills --skills-dir ./local-skills
kimi -p --skills-dir ./skills "……"     # 打印模式下同样生效
```

`推断`：文档只说明替换「用户级与项目级」，未提 Extra、内置与插件技能根，因此后三者应当仍然保留——但这属于推断，落地前需实测。对本项目的含义是：插件的技能走插件清单的 `skills` 字段，与 `--skills-dir` 互不干扰，不必担心被替换掉；而做隔离复现实验时，`--skills-dir` 是唯一能一次性排除用户/项目级污染技能的开关。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html")[reference/kimi-command]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files.html")[configuration/config-files]。

=== (c) 技能发现顺序与优先级

`一手事实`：按作用域分四层，越具体越优先：*项目级 > 用户级 > Extra > 内置*。用户级为 `$KIMI_CODE_HOME/skills/`（默认 `~/.kimi-code/skills/`）与 `~/.agents/skills/`；项目级为 `.kimi-code/skills/` 与 `.agents/skills/`；Extra 由 `config.toml` 的 `extra_skill_dirs` 声明；内置技能随 CLI 分发、优先级最低，由顶层布尔 `builtin_product_skills`（默认 `true`）或 `KIMI_CODE_BUILTIN_PRODUCT_SKILLS` 控制是否提供给模型。

*两种文件结构*：目录形式 `<name>/SKILL.md`（推荐，可在同目录放脚本与参考资料）；扁平形式 `<name>.md`（技能名取文件名）。同一目录下两者同名时子目录优先。

*SKILL.md frontmatter*（`一手事实`）：

#table(columns: 2,
  [*字段*], [*语义*],
  [`name`], [目录形式必填，大小写不敏感；扁平形式取文件名。目录形式缺 `name` 或 `description` 会解析失败],
  [`description`], [目录形式必填；模型据此判断何时自动调用。扁平形式回退为正文首个非空行（截断到 240 字符）],
  [`type`], [`prompt`（默认）、`inline`（同 prompt）、`flow`（仅手动调用）。其他取值会被跳过],
  [`whenToUse`], [触发时机描述，另接受 `when-to-use` / `when_to_used`],
  [`disableModelInvocation`], [为 `true` 时禁止模型自动调用，另接受下划线/连字符变体],
  [`arguments`], [具名参数，字符串数组或空格分隔字符串；声明后正文里以 `$名字` 读取],
)

正文占位符：`$ARGUMENTS`（完整原始参数字符串）、`$ARGUMENTS[0]`、`$0` / `$1`（按空白切分，支持单双引号，因此 `/skill:commit "fix login" patch` 里 `$0` 展开为 `fix login`）、`$<name>`、`${KIMI_SKILL_DIR}`（当前技能所在目录）。正文若不含任何参数占位符，调用时传入的文本会以 `\n\nARGUMENTS: <text>` 追加到末尾。技能调用最多嵌套 3 层。

*调用面*（`一手事实`）：模型通过 `Skill` 工具只能调用 `type = "inline"` 的技能，且 `disableModelInvocation: true` 会被拒绝；用户侧统一走斜杠命令 `/skill:<name>`，子技能显示为 `/<parent-skill>.<sub-skill>`（例如 `code-style.review`），外部技能还支持省掉 `skill:` 前缀的简写 `/<name>`（前提是没被系统命令占用）；内置技能直接以 `/<name>` 出现。

*插件技能*（`一手事实`）：格式与普通技能相同；清单 `skills` 字段接受一个或多个插件根内 `./` 路径，省略时插件根的 `SKILL.md` 作为唯一技能根。`skillInstructions` 在该插件任一技能被加载时（无论 `sessionStart.skill`、斜杠命令还是模型自动调用）都会附加。`sessionStart.skill` 在新建或恢复会话时把指定插件技能注入主 agent——只注入文本，不执行代码。

`UNVERIFIED`：插件技能相对项目/用户/Extra 层的优先级，官方文档未给出（agent 侧明确写了「插件 agent 只高于内置 agent」，技能侧没有对应表述），不能按类比当事实用。落地前用同名技能在两个作用域各放一份实测。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/skills.html")[customization/skills]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/plugins.html")[customization/plugins]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/reference/slash-commands.html")[reference/slash-commands]。

=== (d) Hooks：触发时机与 stdin/stdout 协议

*配置*（`一手事实`）：写在 `~/.kimi-code/config.toml` 的 `[[hooks]]` 数组里，每条规则*只允许四个字段*，多写会导致配置文件加载失败：

```toml
[[hooks]]
event = "PreToolUse"          # 触发事件，必须是事件表中的名字
matcher = "Bash"              # 正则，过滤事件目标；省略即匹配全部
command = "node ~/.kimi-code/hooks/check-bash.mjs"
timeout = 5                   # 秒，范围 1–600，默认 30
```

同一事件的多条匹配规则*并行*执行；`command` 值完全相同的多条规则只跑一次。hook 进程的工作目录是当前会话的项目目录。非 Windows 平台下 hook 运行在独立进程组，超时先发终止信号给清理机会，再强杀。

*stdin 协议*（`一手事实`）：每次触发都把事件详情以 JSON 经 stdin 传给脚本。基础字段为 `hook_event_name`、`session_id`、`session_title`、`client_type`、`cwd`，例如 `{"hook_event_name": "PreToolUse", "session_id": "session_abc", "session_title": "Fix the login page", "client_type": "kimi_code_cli", "cwd": "/path/to/project"}`。特定事件再附带额外字段（如工具名、命令内容）；*所有字段名统一 snake_case*。

*返回协议*（`一手事实`）：由退出码与 stdout 共同决定。

#table(columns: 2,
  [*退出码 / 输出*], [*CLI 行为*],
  [`0`], [放行，继续执行；stdout 内容（若有）可被追加进上下文],
  [`2`], [有意的阻断：停止当前操作，stderr（`console.error` 的内容）作为阻断原因],
  [其他非零 / 超时 / 崩溃], [默认放行（fail-open）],
  [stdout JSON], [`{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "请改用 rg"}}` 亦可阻断],
)

*能否阻断*（`一手事实`）：只有 `PreToolUse`、`Stop`、`UserPromptSubmit` 三个事件支持阻断；其余都是「观察型」事件，脚本返回什么都不影响主流程。`PreToolUse` 触发在权限检查*之前*。

*事件表*（`一手事实`）：

#table(columns: 3,
  [*事件*], [*matcher 匹配对象*], [*触发时机 / 可阻断性*],
  [`UserPromptSubmit`], [用户提交的文本], [发消息时；返回文本追加进上下文；阻断则本轮跳过模型调用。*可阻断*],
  [`PreToolUse`], [工具名], [工具调用前（权限检查*之前*）。*可阻断*],
  [`Stop`], [空串], [模型即将结束本轮时；阻断可追加消息让模型继续。*可阻断*],
  [`UserPromptQueued`], [排队中的提示文本], [一轮进行中又有消息排队；载荷含 `prompt_id`、`prompt`、`queue_length`],
  [`TurnStarted`], [轮次来源类型], [新轮次开始；载荷含 `turn_id`、`origin_kind`、`origin_name`、`prompt`],
  [`PostToolUse` / `PostToolUseFailure`], [工具名], [工具成功执行后 / 工具失败或被阻断后],
  [`PermissionRequest` / `PermissionResult`], [工具名], [即将等待用户批准时 / 批准流程结束后],
  [`SessionStart` / `SessionEnd`], [`startup`、`resume`；`exit`、`archive`], [会话开始或恢复后（载荷含 `source`、`model`、`profile`）；会话关闭后],
  [`SessionHeartbeat`], [空串], [会话存活期间每 60 秒一次；只在配置了该事件时才启动计时器；载荷含 `uptime_ms`],
  [`SubagentStart` / `SubagentStop`], [子代理名], [子代理开始运行前 / 子代理成功完成后],
  [`TaskStarted`], [`agent`、`process`、`question`], [后台任务启动；载荷含 `task_id`、`description`、`detached`],
  [`StopFailure` / `Interrupt`], [错误类型；空串], [本轮因错误失败后；用户打断本轮（按 Esc；超时或程序化中止不触发，代替 `Stop` 触发，载荷含 `reason`）],
  [`PreCompact` / `PostCompact`], [`manual` 或 `auto`], [压缩开始前（返回值被完全忽略）/ 压缩完成后],
  [`Notification`], [通知类型，如 `task.completed`], [后台任务状态变化时],
)

*插件里的 hooks*（`一手事实`）：清单 `hooks` 数组用同样的四个字段；仅当插件启用时生效；工作目录为插件根（所以 `command` 可以写插件内 `./` 路径）；hook 进程额外收到 `KIMI_CODE_HOME` 与 `KIMI_PLUGIN_ROOT` 两个环境变量。*安装插件本身永远不会触发它的 hook*。

*必须记住的边界*（`一手事实`）：因为 fail-open，hooks 适合告警与轻量拦截，*不能*当作唯一的安全屏障；文档明确建议高危操作依赖权限审批与人工确认。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html")[customization/hooks]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/plugins.html")[customization/plugins]。

=== (e) MCP 的两种配置路径

先纠正一个常见误解（`一手事实`）：*MCP 服务器声明并不写在 `config.toml` 里*。`config.toml` 只有 `[mcp]` 表，用来设全局超时 `startup_timeout_ms`（默认 30000）与 `tool_timeout_ms`（默认 60000）；文档在「MCP」条目处明确写了服务器声明应放在 `mcp.json` 或插件清单。

*路径一：`mcp.json`*（`一手事实`）。用户级 `~/.kimi-code/mcp.json`（或 `$KIMI_CODE_HOME/mcp.json`），项目级工作目录下 `.kimi-code/mcp.json`；同名条目项目级覆盖用户级。交互入口是 `/mcp-config`（也是一个内置技能），状态查看是 `/mcp`。

```json
{ "mcpServers": {
  "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] },
  "linear":     { "url": "https://mcp.linear.app/mcp" },
  "legacy":     { "transport": "sse", "url": "https://mcp.example.com/sse" } } }
```

有 `command` 字段即 stdio 服务器；有 `url` 且无 `transport` 即 HTTP；旧的 SSE 需显式写 `transport: "sse"`。可选字段：`env`、`cwd`（仅 stdio）、`headers`、`bearerTokenEnvVar`（HTTP/SSE）、`enabled`、`startupTimeoutMs`、`toolTimeoutMs`、`enabledTools`、`disabledTools`。OAuth 走 `/mcp-config login <server-name>`。

*路径二：插件清单 `mcpServers`*（`一手事实`）。复用同一套 schema，默认启用；清单形如：

```json
{ "name": "kimi-finance", "version": "1.0.0",
  "mcpServers": { "finance": { "command": "node", "args": ["./bin/server.mjs"], "cwd": "./" } } }
```

对 stdio，`command` 必须是 PATH 上的命令，或插件根内以 `./` 开头的路径；`cwd` 同样必须以 `./` 开头且落在插件根内，否则该服务器被忽略。插件的 MCP 在 `/reload` 或新会话后启动，用 `/plugins mcp disable <id> <server>` 关闭。

*权限与命名*（`一手事实`）：MCP 工具名为 `mcp__<server>__<tool>`；权限规则支持 `*` / `**` 通配。两个关键限制：*MCP 工具的参数不参与权限匹配*，且 `AgentSwarm`、MCP 工具、自定义工具都只能按工具名匹配，不支持 `AgentSwarm(swarm)` 这类参数模式。未命中任何规则的调用会触发批准；Ask When Needed 模式下 MCP 调用被*自动批准*——因此把能写文件或执行任意代码的 MCP 服务器配上该模式需要格外谨慎。

*可信度提醒*（`一手事实`）：项目级 `.kimi-code/mcp.json` 的 stdio 条目会在会话启动时执行本地命令；不可信目录下 CLI 会在工作区信任提示里逐条展示 transport 与启动目标，默认选项是「Trust this folder」。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html")[customization/mcp]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/plugins.html")[customization/plugins]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files.html")[configuration/config-files]。

=== (f) 权限模式对自动化研究流程的影响

*三种模式*（`一手事实`，`config.toml` 顶层 `default_permission_mode` 取值 `manual` / `yolo` / `auto`）：

#table(columns: 2,
  [*模式*], [*行为*],
  [Always Ask（`manual`，默认）], [只读操作自动放行，其余（编辑文件、执行命令）逐个询问。适合想全程掌控每一次改动],
  [Ask When Needed（`/yolo`、`-y`）], [常规工具调用自动批准；仍在敏感文件（`.env`、SSH 私钥）、危险命令（`shutdown`、`rm -rf`）、退出 Plan 模式前询问；agent 仍可能向你提问],
  [Never Ask（`/auto`）], [全部自动，含敏感文件与 plan 退出；agent 永不提问，一切自行决定。危险命令守卫在该模式下也不生效],
)

*开关冲突*（`一手事实`）：`--yolo` 与 `--auto` 互斥；`--prompt` 不能与 `--yolo`、`--auto`、`--plan` 组合——*打印模式本身就按 auto 权限策略处理常规工具调用，静态 deny 规则仍然生效*。恢复会话时可用 `--auto` / `--yolo` / `--plan` 覆盖已保存的模式。

*Plan 模式*（`一手事实`）：`--plan`、`Shift-Tab`、`/plan` 进入。进入后 `Write` / `Edit` 被限制为只能写当前 plan 文件，`TaskStop` 完全禁用，`CronDelete` 也被禁用（文档明确列出）；其余工具（含 `Bash`）仍受当前权限规则约束。`ExitPlanMode` 需要用户确认；`--yolo` *不*绕过 plan 退出审批，而 Never Ask 会自动批准并标记为 Auto-approved。

*规则系统*（`一手事实`）：`[[permission.rules]]` 按顺序匹配，*第一条命中即生效*；字段 `decision`（`allow` / `deny` / `ask`）、`scope`（`turn-override` / `session-runtime` / `project` / `user`，默认 `user`）、`pattern`（`ToolName` 或 `ToolName(arg-pattern)`）、`reason`。危险命令守卫可用 `[permission] dangerous_command_guard = false` 整体关闭（或 `KIMI_CODE_DANGEROUS_COMMAND_GUARD=false`）。

*对「无人值守研究循环」的直接影响*（`一手事实` + `推断`）：`kimi -p` 是最适合脚本化的一档——无人工批准、按 auto 策略跑、静态 deny 规则兜底，且 `--output-format stream-json` 让每行 stdout 成为一个 JSON 对象（思考内容不写入 JSONL，工具进度与「恢复会话」提示写到 stderr），便于流水线解析。`一手事实` 还给出打印模式下后台任务的收口语义：`print_background_mode` 默认 `steer`，主 agent 一轮结束后若仍有后台任务未完成，每次完成都会以合成 user 消息把 agent 重新拉进新一轮，直到某轮结束时没有待处理任务才退出；循环受 `print_wait_ceiling_s`（默认 2147483）与 `print_max_turns`（默认 100000）约束；后台 Bash 任务在打印模式下默认*无*超时。`推断`：长跑的证明搜索/反例搜索很依赖这套 steer 语义，但同时意味着卡死的后台任务不会自然终止，必须自己写 deny 规则或用 hook 做超时兜底。

*Goal 模式*是另一条自动化路径（`一手事实`）：`/goal <objective>` 保存目标（上限 4000 字符）并跨轮次推进，停止态为 complete / paused / blocked；非交互模式只支持创建形式 `kimi -p "/goal ..."`，退出码 0 = 完成、3 = 受阻、6 = 暂停。文档明确提醒：目标必须写清「终点与可验证证据」，反例是 `/goal Find all bugs in this codebase` 这类没有成功判据的目标；对数学开放问题，「证明某猜想」这种目标会被 agent 判定为 blocked 而不是死磕。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/guides/interaction.html")[guides/interaction]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/reference/tools.html")[reference/tools]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files.html")[configuration/config-files]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/guides/goals.html")[guides/goals]。

=== (g) 子代理与 AgentSwarm 的并行度上限

*两种派发工具*（`一手事实`）：`Agent` 派发单个子代理，参数 `prompt`（完整任务描述）、`description`（3–5 词摘要）、`subagent_type`（默认 `coder`）、`resume`（复用已有子代理，与 `subagent_type` 互斥）、`run_in_background`、`model`；`Agent` 默认*自动放行*。`AgentSwarm` 从一份 `prompt_template` 加 `items` 数组批量派发，模板必须含占位符，每个 item 替换它并启动一个新子代理。

*并行度*（`一手事实`）：

- `AgentSwarm` 支持*最多 128 个*子代理，等待全部结束并返回聚合报告；
- 并发按爬坡方式启动：*立即起 5 个，之后每 700 ms 再起 1 个*，默认*无上限*；
- 用环境变量 `KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY` 设正整数可给爬坡过程设并发上限；设为非正整数会让该次调用直接失败；
- 不使用 `resume_agent_ids` 时至少需要 2 个 item；
- 单次模型回复里 `AgentSwarm` 必须是*唯一*的工具调用；要跑多个 swarm 得等结果回来再发起下一个。

*超时*（`一手事实`）：`Agent` 子代理默认 2 小时（`[subagent] timeout_ms = 7200000`，或 `KIMI_SUBAGENT_TIMEOUT_MS`，`0` 表示不限时）；`AgentSwarm` 独立地由 `[swarm] timeout_ms` 控制（同样默认 2 小时，或 `KIMI_CODE_SWARM_TIMEOUT_MS`）。*打印模式下两者都默认为不限时*。超时的子代理会被中止并在聚合报告里标记为失败。

*权限与继承*（`一手事实`）：子代理权限规则继承自主 agent——主 agent 通过 `/permission` 或批准弹窗接受的「始终允许」会自动传播到它派发的所有子代理；`Agent` 工具本身默认允许。手动权限模式下，非 swarm 激活状态的 `AgentSwarm` 调用需要批准（除非有规则允许）；swarm 模式激活时 `AgentSwarm` 自动批准。swarm 模式用 `/swarm on|off` 或 `/swarm <task>` 开关，后一种在一轮正常结束后自动关闭。

*委派深度*（`一手事实`）：三个内置子代理（`coder` 读写执行、`explore` 只读、`plan` 连 shell 都没有）*不能再派发子代理*；自定义 agent 默认继承内置委派白名单（`coder`、`explore`、`plan`），因此委派链总是终止；要更深的链必须在 frontmatter 显式声明 `subagents` 白名单。子代理是独立上下文窗口，只能看到主 agent 显式传入的任务描述，中间推理与工具记录不回传，只有最终结果进入主 agent 上下文。

*模型池*（`一手事实`）：`[secondary_model]` 为子代理提供候选模型池与默认绑定（`default_model`、`models`、`force`、`default_effort`）；`primary` 是保留别名，指调用者自己正在跑的模型。配置了池之后 `Agent` / `AgentSwarm` 才多出 `model` 参数。注意一个不对称：主 agent 上全局 `[thinking].effort` 会压过变体的 `default_effort`，而子代理侧相反，变体的 `default_effort` 胜出，只有 `[secondary_model].default_effort` 能再压它。

`推断`：本机 12 核、30 GB 内存（本机实测）。128 路并发子代理的瓶颈几乎必然是模型 API 而非本地 CPU，但对*本地*重负载（Lean 编译、Julia 数值搜索）而言，swarm 的真实并行度应当按核数与内存自己定，设 `KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY` 比放任爬坡更稳。

来源：#link("https://www.kimi.com/code/docs/en/kimi-code-cli/reference/tools.html")[reference/tools]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/customization/agents.html")[customization/agents]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files.html")[configuration/config-files]、#link("https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/env-vars.html")[configuration/env-vars]。

=== 结论：哪些能力必须做成 MCP 工具，哪些该做成技能

*必须做成 MCP 工具*（`推断`，依据上面的机制约束）：

- *需要结构化、可判定返回值的本地计算*。技能的产物是提示文本，模型得自己解析 stdout；凡是要「返回 `sat` / `unsat` / `unknown` 或一个反例见证」这类判断的，用 MCP 工具返回 JSON 才有稳定的下游。例如 Lean 编译+检查、Julia 数值搜索、有限域穷举。
- *需要保持常驻状态的能力*。stdio MCP 服务器是长驻子进程，适合把昂贵初始化（Lean 仓库 `lake build` 的预热、Julia 包的 JIT）只做一次；技能每次都要重新付这笔成本。
- *必须一次装好、所有 agent 都能用到的能力*。插件 MCP 默认启用，工具名固定为 `mcp__<server>__*`，于是 agent 文件的 `tools: [mcp__research__*]` 可以精确落到这一组工具上——这是技能做不到的粒度控制。
- *参数复杂、易被 shell 转义破坏的调用*。MCP 走 JSON schema，绕开引号、`$`、多行脚本的转义问题；本项目恰好大量涉及把数学表达式、LaTeX、证明脚本作为参数传递。

*该做成技能*（`推断`）：

- *流程与判据*：猜想的规范化写法、反例搜索该先扫哪个参数空间、基准评测的公平性检查清单、结果表格的字段口径。这些是判断，不是计算。
- *对已装 CLI 的编排*：本机已有 `typst`、`julia`、`lean`/`lake`、`pdflatex`、`pandoc`、`git`，纯编排型操作直接用 `Bash` 即可，不必绕 MCP。反过来，本机*没有* `z3`、`cvc5`、`sage`、`gap`、`pari/gp`、`cargo`（本机实测），任何依赖它们的流程在技能里必须写成「先探测存在性，缺失则走替代路径」，而不是假定可用。
- *大体量参考资料*：用目录形式 `<name>/SKILL.md` 加同目录 `references/`，按需读取，避免一次性灌满上下文。
- *需要在会话启动时就生效的规则*：`sessionStart.skill` 只注入文本、不执行代码，正适合放项目的证明规范与命名约定。

*三个边界必须写进设计*（`推断`，依据 `一手事实`）：一是 MCP 工具在权限规则里*只能按工具名匹配*，所以「一个万能工具」会让权限粒度退化——宁可拆成多个窄工具；二是 hooks 是 fail-open，不能作为唯一护栏，关键约束同时要有静态 deny 规则；三是 `kimi -p` 已经运行在 auto 权限策略下、且不能再叠 `--yolo` / `--auto` / `--plan`，脚本化研究循环的权限控制只能靠 `config.toml` 的静态规则，而不是靠命令行开关。

=== 评估

- *抄 `plugin.json` + `skills/` + `mcpServers` 的三件套结构，把 MCP 服务器写成单文件 Node stdio server*：本机已装的 `kimi-datasource` 就是 `{"command": "node", "args": ["./bin/kimi-datasource.mjs"], "cwd": "./"}` 这一形态，且其 server 文件自带 `initialize` / `tools/list` / `tools/call` / `ping` 的最小实现，不依赖 workspace 包——可以整体照搬为「证明/反例搜索 harness」的骨架。
- *抄 `sessionStart.skill` + `skillInstructions` 两条注入点，但不要拿它们当配置通道*：前者只在会话开始注入文本，后者只在插件技能加载时附加；都只影响 prompt。真正需要「装上就生效」的策略行为应落到 MCP 工具与 hook 上，否则改了 prompt 也不会改变工具的副作用面。
- *避免把危险能力做成 hook 拦截*：hooks 是 fail-open（退出码非 0/2、超时、崩溃都放行），文档也明说它不能充当唯一安全屏障。本插件的写盘、外部命令这类约束应同时写进 `[[permission.rules]]` 的静态 `deny`，hook 只做告警与提示。
- *避免用裸 `*` 通配或单个万能 MCP 工具*：`mcp__` 之外的裸 `*` 什么都不禁（`disallowedTools: ["*"]` 是空操作），`mcp__github` 这种缺工具段的写法同样匹配不到任何东西；反过来 MCP 工具只能按工具名做权限匹配，所以工具要拆窄，让 `deny` 能落在具体工具上。
- *该避免假设 `--skills-dir` 能隔离一切*：它替换的是用户级与项目级技能目录，Extra、内置与插件技能不受其约束（后三者属推断，需实测）；要复现「干净环境」跑基准，还得配合 `builtin_product_skills` 与禁用插件。
- *抄 `tools`/`subagents` 白名单做权限裁剪，别靠 prompt 劝说*：`tools`、`disallowedTools`、`subagents` 既塑造模型可见的工具列表，又在执行前二次强制，`Agent` 与 `AgentSwarm` 也会复查 `subagents` 白名单。给「只做只读验证」的子代理写 `disallowedTools: [Bash]` 比在 prompt 里写「不要执行命令」可靠得多；同时记得自定义 agent 被委派时不带内置收尾框架，正文里必须自己声明「最后一条消息即完整交接」。

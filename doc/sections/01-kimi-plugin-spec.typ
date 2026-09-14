== Kimi Code 插件规范（清单 / 技能 / hooks / MCP / 本地安装）

本节结论以三类一手来源交叉验证：官方文档站、官方 npm 包 `@moonshot-ai/kimi-code@0.42.0` 的
`dist/main.mjs` 中的 `plugin/manifest.ts`、`plugin/manager.ts`、`skill/catalog/parser.ts` 源码，以及本机已安装插件的真实清单文件。
凡属代码级推导而非文档明文者，均在下文标注。

*各小节对应的官方来源*（文档站语言前缀可取 `/en/` 或 `/zh/`）：
(a)(b)(d)(g) → #link("https://moonshotai.github.io/kimi-code/en/customization/plugins")[Plugins]；
(c) → #link("https://moonshotai.github.io/kimi-code/en/customization/skills")[Agent Skills]；
(e) → #link("https://moonshotai.github.io/kimi-code/en/customization/hooks")[Hooks]；
(f) 见该小节表格。清单解析与路径校验的逐行依据见
#link("https://github.com/MoonshotAI/kimi-code/tree/main/packages/agent-core-v2/src/app/plugin")[packages/agent-core-v2/src/app/plugin]。

*本机环境实测*（只读命令）：`kimi --version` → `0.42.0`；`kimi doctor` → `config.toml`、`tui.toml` 两项 OK（doctor 不检查插件）；
`kimi plugins list` → `unknown command 'plugins'. See 'kimi --help'.`，即*当前版本没有插件 CLI 子命令*，插件管理只在 TUI 内。

=== (a) 清单文件名、优先级与 `$schema`

`===` 官方文档明确支持*两种*位置，二者都存在时根文件胜出：

#table(columns: 3,
  [清单路径], [优先级], [含义],
  [`<plugin_root>/kimi.plugin.json`], [高], [`manifestKind = "kimi-plugin-root"`，官方推荐写法],
  [`<plugin_root>/.kimi-plugin/plugin.json`], [低], [兼容布局；被遮蔽时在诊断里记为 `shadowedManifestPath`],
)

- 两者都不存在时诊断信息为 `No manifest at kimi.plugin.json or .kimi-plugin/plugin.json`（源码明文）。
- 本机佐证：`kimi-datasource`、`kimi-webbridge`、`modern-web-guidance` 用根 `kimi.plugin.json`；`superpowers` 用 `.kimi-plugin/plugin.json`。两种都能被加载。
- *`$schema` 不被校验*：CLI 源码里没有任何 schema 文件或 `$schema` 处理逻辑，清单是逐字段手写解析。官方 `kimi-webbridge` 清单声明
  `"$schema": "https://kimi.com/schemas/kimi.plugin.schema.json"`，但本机 `curl -sL` 该 URL 返回 `200` + `text/html`（Kimi 官网 SPA，约 477 KB），并*不是* JSON Schema；`code.kimi.com/schemas/...` 只是重定向到安装脚本。结论：`$schema` 纯属装饰，可写可不写。
- *易混淆的同名体系*：`MoonshotAI/kimi-cli`（另一个仓库，11k star，最后推送 2026-09）有一套完全不同的插件系统——插件是根目录 `plugin.json`、
  用 `tools` 声明可执行工具、通过 `kimi plugin install` 安装。`kimi-code` 的迁移文档明说「kimi-cli plugins are also out of scope」。
  两者字段集不相交，本项目只针对 `kimi-code`。

清单最小可用形态（官方文档示例，节选）：

```json
{
  "name": "kimi-finance",
  "version": "1.0.0",
  "description": "Finance data and analysis workflows for Kimi Code CLI",
  "skills": "./skills/",
  "sessionStart": { "skill": "using-finance" },
  "interface": { "displayName": "Kimi Finance", "shortDescription": "Market data workflows" }
}
```

=== (b) manifest 全部受支持字段

*只有 `name` 是必填*，且只有 `name` 非法会让插件加载失败（`severity: "error"`）；其余字段的任何问题都降级为 `warn` / `info` 诊断，插件仍加载。
`name` 必须匹配 `^[a-z0-9][a-z0-9_-]{0,63}$`，内部 id 为其小写形式。

#table(columns: 4,
  [字段], [类型], [必填], [语义与代码级细节],
  [`name`], [string], [是], [插件 id，正则如上；空串/缺失即 error 并中止解析],
  [`version`], [string], [否], [展示元数据；市场用 semver 比较新旧版本],
  [`description`], [string], [否], [展示元数据；空白串等同未设置],
  [`keywords`], [string[]], [否], [非 string[] 时*整体忽略*，不报错],
  [`author`], [字符串或对象], [否], [字符串会归一化为 `{name}`；对象可含 `name`、`email`],
  [`homepage`], [string], [否], [展示元数据],
  [`license`], [string], [否], [展示元数据，不做 SPDX 校验],
  [`interface`], [object], [否], [`displayName`、`shortDescription`、`longDescription`、`developerName`、`websiteURL`；全部缺失则丢弃整个对象],
  [`skills`], [字符串或字符串数组], [否], [见 (c)；省略时若根目录有 `SKILL.md` 则以插件根为唯一技能根],
  [`agents`], [字符串或字符串数组], [否], [`./` 目录或 agent `.md`；省略时自动探测 `agents/` 目录],
  [`commands`], [字符串或字符串数组], [否], [`./` 目录或 `.md` 文件，注册为 `/<plugin>:<command>`],
  [`sessionStart`], [object], [否], [`{ "skill": "<skill-name>" }`；存在时 `skill` 必填，否则整个字段被忽略],
  [`skillInstructions`], [string], [否], [该插件的技能被加载时附加的指令文本],
  [`systemPrompt`], [string], [否], [计入系统提示；单字段上限 32 KB，超限忽略并告警],
  [`systemPromptPath`], [string], [否], [`./` UTF-8 文本，拼在 `systemPrompt` 之后；同样 32 KB 上限],
  [`mcpServers`], [object], [否], [见 (d)],
  [`hooks`], [array], [否], [见 (e)],
)

- *已知但不受支持*的运行时字段（出现即产生 `info` 诊断并忽略，源码常量 `UNSUPPORTED_RUNTIME_FIELDS`）：
  `tools`、`apps`、`inject`、`configFile`、`config_file`、`bootstrap`。
- 清单顶层*不做*严格校验：未列出的字段（例如 Claude 格式残留的 `capabilities`、`repository`）被静默忽略。
  本机 `superpowers` 清单中的 `interface.capabilities` 就属于这类死字段。
- 官方文档页：#link("https://moonshotai.github.io/kimi-code/en/customization/plugins")[Plugins]。本机 0.42.0 的 `plugin.json` 解析实现在安装包的 `dist/main.mjs` 中（`packages/agent-core-v2/src/app/plugin/manifest.ts` 段），字段行为以该处为准。

=== (c) `skills` 字段与 SKILL.md 加载规则

`skills` 接受*字符串或字符串数组*（本机 `modern-web-guidance` 用数组、`superpowers` 用单串，均有效）。每个条目必须满足：

- 必须以 `./` 开头，否则 `error`；解析后用 `realpath` 检查必须仍在插件根内（符号链接不能逃逸），且必须是*目录*，否则 `warn`。
- 目录内递归扫描 `SKILL.md`，深度上限 8 层；跳过名字以 `.` 开头的目录与 `node_modules`。
- 省略 `skills` 且插件根存在 `SKILL.md` 时，插件根成为技能根并进入 `root-skill-only` 模式——*只认根目录那一个 `SKILL.md`，不再向下扫描*。
  本机 `kimi-datasource`（根 `SKILL.md` + `bin/`）正是这个模式。

SKILL.md frontmatter 字段（目录形态 `SKILL.md` 与扁平 `<name>.md` 同格式）：

#table(columns: 3,
  [字段], [必填], [规则],
  [`name`], [目录形态必填], [目录形态缺 `name` 或 `description` → *解析失败*，该技能被丢弃；扁平 `.md` 回退为文件名],
  [`description`], [目录形态必填], [模型判断是否调用的唯一依据；扁平形态回退为正文首个非空行（超 240 字符截断）],
  [`type`], [否], [仅 `prompt`（默认）、`inline`（等同 prompt）、`flow`（只能手动调用）；其他值直接跳过],
  [`whenToUse`], [否], [别名 `when-to-use`、`when_to_use`；与 description 一起决定自动调用],
  [`disableModelInvocation`], [否], [别名 `disable-model-invocation`、`disable_model_invocation`；为真则禁止模型自动调用],
  [`arguments`], [否], [字符串数组或空格分隔字符串；声明后正文可用 `$<name>` 引用],
)

*渐进披露的实际机制*（代码 + 本机实测）：系统提示里只注入技能目录，每条仅 `name` + `description` + `SKILL.md` 路径，
并按来源分组为 `Project` / `User` / `Extra` / `Built-in`；正文在被调用时才注入，包在 `<skill-loaded name=… trigger=… source=… dir=… args=…>` 中。
提示文本原文为「read the skill file for its instructions; only read further skill details when needed, to conserve the context window」。
调用入口：`/skill:<name>`（带参如 `/skill:review-pr #1234`）或模型自动调用；技能嵌套调用最多 3 层。

正文占位符：`$ARGUMENTS`（整串）、`$ARGUMENTS[0]` 与简写 `$0`（引号可分组，`"fix login"` 视作一个参数）、`$<name>`、
`${KIMI_SKILL_DIR}`（当前技能所在目录）。若正文没有任何参数占位符，调用时传入的文本会被追加为 `\n\nARGUMENTS: <text>`。

*同名冲突优先级*（源码 `SKILL_SOURCE_PRIORITY`，数值大者胜）：`builtin` 0 < `plugin` 5 < `extra` 10 < `user` 20 < `workspace` 30。
即*插件技能会被同名用户级/项目级技能覆盖，但压过内置技能*；插件技能在提示目录里被归入 `Extra` 段（本机实测）。

=== (d) `mcpServers`：格式、路径解析与占位符

`mcpServers` 是*对象映射*（不是数组），键为服务器名（本机 `kimi-datasource` 用 `data`）；值是复用的 MCP 配置 schema，按 `transport` 判别联合：

#table(columns: 2,
  [传输], [字段],
  [`stdio`], [`command`（PATH 命令，或以 `./` 开头的插件内路径）+ `args`、`env`、`cwd`、`executor`、`runtime_id`],
  [`http` / `sse`], [`url`（必须是合法 URL）+ `headers`、`auth`、`bearerTokenEnvVar`],
  [三种共有], [`enabled`、`startupTimeoutMs`、`toolTimeoutMs`、`enabledTools`、`disabledTools`],
)

- *路径规则*（文档与源码一致）：`command` 含 `/` 但又不以 `./` 开头，或为绝对路径 → 告警并*丢弃该服务器*；`cwd` 必须以 `./` 开头且解析后仍在插件根内，否则丢弃。省略 `transport` 时若存在 `command` 则推断为 `stdio`（本机 `kimi-datasource` 就省了 `transport`）。
- *没有 `${PLUGIN_ROOT}` 这类占位符替换*。源码中不存在任何清单占位符展开逻辑；相对路径的解析完全靠「`./` + `path.resolve(pluginRoot)`」，运行期则改为注入环境变量：

```json
{
  "mcpServers": {
    "data": { "command": "node", "args": ["./bin/kimi-datasource.mjs"], "cwd": "./" }
  }
}
```

- 运行期行为（源码 `withPluginMcpRuntime`）：stdio 服务器的 `cwd` 默认为插件根；`env` 中强制注入 `KIMI_CODE_HOME` 与 `KIMI_PLUGIN_ROOT`；
  Electron 下把 `node` 换成 `process.execPath` + `ELECTRON_RUN_AS_NODE=1`；原生二进制下改用内置的 `kimi node` 回退子命令。服务器对外名为 `plugin-<id>:<server>`。
- 服务器默认启用，可用 `/plugins mcp disable <id> <server>` 关闭；插件 MCP 服务器在 `/reload` 或新会话后启动。
- HTTP/SSE 服务器不走上面的 `command`/`cwd` 归一化，也不注入这两个环境变量。

=== (e) hooks：事件、结构与企业约束

*插件清单里的 `hooks` 是数组*，每个元素形如 `{ "event": …, "matcher": …, "command": …, "timeout": … }`，schema 为严格模式（多余字段导致该条校验失败并被丢弃）。
这与 Claude/Codex 生态常见的 `hooks/hooks.json`「按事件名分组的对象」*不兼容*——本机 `superpowers/hooks/hooks.json` 就是那种格式，
而且它引用 `${CLAUDE_PLUGIN_ROOT}`；`CLAUDE_PLUGIN_ROOT` 在整个 CLI 包中*零次出现*，所以那份文件对 Kimi 无效（该插件的 Kimi 入口改用 `sessionStart`）。

- 字段：`event` 必填且须为下表事件名；`matcher` 选填，正则字符串，省略即匹配全部；`command` 必填、非空；`timeout` 选填，整数 1–600 秒，默认 30 秒。
- `[[hooks]]` 与插件 hook 共用一套机制：多个规则命中同一事件时*并行执行*，`command` 完全相同的规则只跑一次；失败/超时按 *fail-open* 放行。
- 插件 hook 的两个额外差异：工作目录固定为*插件根*（所以可写 `node ./hooks/x.mjs`），且进程环境变量中额外带 `KIMI_CODE_HOME` 与 `KIMI_PLUGIN_ROOT`。
- 安装插件本身*不会*执行任何 hook；只有插件启用且事件命中时才触发。

#table(columns: 3,
  [事件], [matcher 匹配对象], [可阻断],
  [`UserPromptSubmit`], [用户提交的文本], [是],
  [`UserPromptQueued`], [排队中的提示文本], [否],
  [`PreToolUse`], [工具名（权限检查*之前*）], [是],
  [`PostToolUse` / `PostToolUseFailure`], [工具名], [否],
  [`PermissionRequest` / `PermissionResult`], [工具名], [否],
  [`Stop`], [空字符串], [是],
  [`StopFailure`], [错误类型], [否],
  [`TurnStarted`], [回合来源类型（user/task/…）], [否],
  [`Interrupt`], [空字符串], [否],
  [`SessionStart`], [`startup` 或 `resume`], [否],
  [`SessionEnd`], [`exit` 或 `archive`], [否],
  [`SessionHeartbeat`], [空字符串（每 60 秒）], [否],
  [`SubagentStart` / `SubagentStop`], [子代理名], [否],
  [`TaskStarted`], [后台任务类型], [否],
  [`PreCompact` / `PostCompact`], [`manual` 或 `auto`], [否],
  [`Notification`], [通知类型，如 `task.completed`], [否],
)

脚本通过 stdin 收到 JSON，基础字段全部为 snake_case：

```json
{ "hook_event_name": "PreToolUse", "session_id": "session_abc", "session_title": "Fix the login page",
  "client_type": "kimi_code_cli", "cwd": "/path/to/project" }
```

返回语义：退出码 `0` 放行（stdout 可能并入上下文）；`2` 阻断（stderr 作为阻断理由写回上下文）；其他非零、超时、崩溃一律放行。
只有可阻断事件允许用 stdout JSON 改变主流程：

```json
{ "hookSpecificOutput": { "permissionDecision": "deny", "permissionDecisionReason": "Please use rg instead of grep" } }
```

*注意*：源码中另有一处只列 16 个事件的市场/config-patch 版 schema（不含 `UserPromptQueued`、`TurnStarted`、`SessionHeartbeat`、`TaskStarted`）；
上述 20 事件表与官方 Hooks 文档一致，是插件清单实际使用的枚举（推断：前者用于会话级配置覆盖，非文件清单）。

=== (f) 官方文档站中与插件/技能相关的页面

文档站是 VitePress，语言前缀 `/en/` 与 `/zh/`，页面内容一一对应；另有侧栏未列出的 `datasource` 页（在 hash map 中存在但不在导航里）。

#table(columns: 2,
  [页面], [与本主题的关系],
  [`/en/customization/plugins`], [*主页面*：清单字段全表、`/plugins` 面板与子命令、GitHub 安装四种 URL、市场 JSON、systemPrompt 上限、commands、agents、MCP、hooks、安全模型],
  [`/en/customization/skills`], [SKILL.md frontmatter 字段、四种技能目录层级、占位符、嵌套层数、内置技能],
  [`/en/customization/hooks`], [20 个事件的 matcher 语义、stdin JSON、退出码与阻断、fail-open],
  [`/en/customization/mcp`], [插件 `mcpServers` 复用的 MCP schema 原文],
  [`/en/customization/agents`], [插件 `agents/` 所用 agent 文件格式（`name`/`description`/`tools`/`disallowedTools`/`override`）],
  [`/en/customization/datasource`], [官方 datasource 插件说明（侧栏外页面）],
  [`/en/configuration/config-files` / `data-locations` / `env-vars` / `overrides`], [`$KIMI_CODE_HOME` 目录树、`plugins/installed.json`、`skills/`、`KIMI_CODE_PLUGIN_MARKETPLACE_URL`],
  [`/en/reference/slash-commands`], [`/plugins`、`/skill:<name>`、`/reload` 的权威列表],
  [`/en/reference/kimi-command` / `tools`], [CLI 子命令与内置工具（`Skill`、`Agent`、`Bash` 等）],
  [`/en/release-notes/changelog`], [插件能力的引入时间线（可据此确认某个字段从哪个版本才有）],
)

主要页面直链（其余页面把上表路径接在 `https://moonshotai.github.io/kimi-code` 之后即可）：
`#link("https://moonshotai.github.io/kimi-code/en/customization/plugins")[plugins]`、
`#link("https://moonshotai.github.io/kimi-code/en/customization/skills")[skills]`、
`#link("https://moonshotai.github.io/kimi-code/en/customization/hooks")[hooks]`、
`#link("https://moonshotai.github.io/kimi-code/en/customization/mcp")[mcp]`、
`#link("https://moonshotai.github.io/kimi-code/en/customization/agents")[agents]`、
`#link("https://moonshotai.github.io/kimi-code/en/reference/slash-commands")[slash commands]`。
站点源码与侧栏定义见 `#link("https://github.com/MoonshotAI/kimi-code/tree/main/docs")[MoonshotAI/kimi-code docs]`。

=== (g) 安装、管理与模板仓库

TUI 内 `/plugins` 是唯一官方管理入口，子命令（官方文档与源码 `tui/commands/plugins.ts` 一致）：
`list`、`install <path-or-url>`、`marketplace [source]`、`info <id>`、`enable|disable <id>`、`remove <id>`、`reload`、`mcp enable|disable <id> <server>`。
插件自带的 `commands/*.md` 注册为 `/<plugin>:<command>`，文件内 `$ARGUMENTS` 被替换，正文无占位符时参数追加到末尾。

- 安装来源：本地目录、zip URL、GitHub 仓库 URL（四种形式：仓库根、`/tree/<ref>`、`/releases/tag/<tag>`、`/commit/<sha>`）；仅走 `github.com` 重定向与 `codeload.github.com`，*不调用* `api.github.com`。zip 安装要求清单在压缩包根或唯一一层包裹目录内。
- 本地安装会被*复制*到 `$KIMI_CODE_HOME/plugins/managed/<id>/`（默认 `~/.kimi-code/...`），CLI 只跑这份副本，改动原始目录无效，必须重装；`remove` 只删记录，托管副本与源目录都留在磁盘。
- 安装状态记在 `$KIMI_CODE_HOME/plugins/installed.json`（本机实测字段：`version`、`plugins[].{id,root,source,enabled,installedAt,updatedAt,originalSource,github{owner,repo,ref,installedSha}}`）。
- 信任级别按来源 URL 判定：`official`（Kimi CDN `/kimi-code/plugins/official/`）、`curated`（`/kimi-code/plugins/curated/`）、其余 `third-party`；第三方安装前有确认提示。
- 市场 JSON 形如 `{ "version": "1", "plugins": [{ "id", "displayName", "version", "description", "keywords", "homepage", "tier", "source" }] }`，
  官方默认目录为 #link("https://github.com/MoonshotAI/kimi-code/blob/main/plugins/marketplace.json")[plugins/marketplace.json]（`tier` 取 `official` / `curated`），可用环境变量 `KIMI_CODE_PLUGIN_MARKETPLACE_URL` 覆盖。
- 生效时机：安装/启用/禁用/移除后需 `/reload` 或新建会话；`/reload` 会刷新插件技能列表并请求重建系统提示。

模板/生成器现状：*官方没有插件脚手架或生成器仓库*（在 `MoonshotAI/kimi-code` 内检索 "plugin template" 无结果）。
可参照的是官方仓库里两个真实插件目录（`plugins/official/kimi-datasource`、`kimi-webbridge`，含 MCP 与根 `SKILL.md` 范式），
以及第三方极简模板 #link("https://github.com/yuanhang45127/kimi-plugin-template")[yuanhang45127/kimi-plugin-template]（仅 manifest + 一个示例技能）。
另外 GoogleChrome 的 `modern-web-guidance-src` 把 `kimi.plugin.json` 放在 `serving/skills-cli/template/` 下，由构建脚本生成，
可视为「跨平台技能包 → 多格式清单」的生成器做法。`superpowers` 的做法是同一仓库并列 `.claude-plugin/`、`.codex-plugin/`、`.cursor-plugin/`、`.kimi-plugin/` 多份清单。

*UNVERIFIED / 已知错误*：上述第三方模板 README 声称可用 `kimi plugins install <path-or-git-url>`，但本机 0.42.0 实测为
`unknown command 'plugins'`——命令行安装不存在，只能用 `/plugins install`。凡引用该 README 的写法都需按此修正。

=== 评估

- *该抄*：把清单路径做成「`kimi.plugin.json` 优先 + `.kimi-plugin/plugin.json` 兼容」的双位置探测，并且*只有 `name` 非法才致命*、其余问题降级为诊断，
  配一个 `/plugins info <id>` 式的诊断面板——本项目要长期迭代 manifest 字段，这种「永不因小错拒绝加载」的设计能避免研究流程被打断。
- *该抄*：技能采用「frontmatter 只进目录、正文按需注入」的渐进披露，并在 `sessionStart.skill` 里挂一个入口技能（如同 `superpowers` 挂 `using-superpowers`），
  用来把「代数几何术语 → 本插件工具调用」的映射一次性注入，而不是每次对话重复解释。
- *该抄*：把 MCP 服务器路径限制在插件根内（`./` 前缀 + `realpath` 校验）并改为运行期注入 `KIMI_PLUGIN_ROOT` / `KIMI_CODE_HOME`，
  而不是发明清单内占位符语法——本项目要内置 Sage/z3 类外部求解器封装脚本，这种约束既安全又免去自造模板引擎。
- *该避免*：不要照搬 Claude 生态的 `hooks/hooks.json`（按事件名分组的对象 + `${CLAUDE_PLUGIN_ROOT}`）与 `interface.capabilities`；
  Kimi 的 hooks 是扁平数组、没有任何 `*_PLUGIN_ROOT` 占位符替换，抄错会得到一份静默失效的清单（`superpowers` 正是这种残留）。
- *该避免*：不要指望 `$schema` 或任何官方 JSON Schema 做校验；也不要依赖 `kimi plugins` CLI 子命令做自动化安装，
  应把「`/plugins install` + `/reload`」写进技能文档，并把版本探测留给 `kimi --version`。
- *该避免*：不要用省略 `skills` 字段的写法来指代多个技能目录——那会进入 `root-skill-only` 模式，只认根 `SKILL.md`；
  多技能必须显式列出 `"skills": ["./skills/a/", "./skills/b/"]`，且记住插件技能优先级低于同名项目/用户技能，名称需带前缀避免被覆盖。

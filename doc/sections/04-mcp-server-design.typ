== MCP Server 设计：协议、原语与工程模式

给「开放问题攻击插件」写本地 stdio MCP server 时，哪些决定必须做对。标 *一手事实* 的有 URL 或本机文件
为证；标 *推断* 的是据此给出的工程判断；无法核实的一律写 `UNVERIFIED`，不猜 API 名与版本号。

=== 协议版本：对齐宿主，而不是对齐规范最新版

*一手事实*：MCP 版本号形如 `YYYY-MM-DD`，标记最后一次破坏性变更；current protocol version 是
`2026-07-28`（#link("https://modelcontextprotocol.io/specification/versioning")[MCP Versioning]）。

*一手事实*：`2026-07-28` 相对 `2025-11-25` 是破坏性重启——删除 `initialize` /
`notifications/initialized` 握手、删除 `ping`、删除协议级会话与 `Mcp-Session-Id`，改为每个请求在
`_meta` 里携带 `io.modelcontextprotocol/protocolVersion` 与 `clientCapabilities`，并新增必实现的
`server/discover`（#link("https://modelcontextprotocol.io/specification/2026-07-28/changelog")[2026-07-28 Key Changes]）。

*一手事实（本机）*：随 Kimi Code 安装的参照实现
`~/.kimi-code/plugins/managed/kimi-datasource/bin/kimi-datasource.mjs`（插件 3.4.0，mtime 2026-08-25）
实现的是*握手式*最小面：`initialize`、`notifications/initialized`、`tools/list`、`tools/call`、`ping`，
并把 `PROTOCOL_VERSION` 硬编码为 `'2025-06-18'`（同文件第 26、131–149、517–540 行）。

*推断*：宿主目前走 `2025-06-18` 血统的握手式协议，不是无状态协议。第一阶段就实现握手式 server；
`server/discover`、`_meta` 版本键、tasks 扩展都别碰，宿主是否调用它们 `UNVERIFIED`。唯一要改进的是
*不要硬编码版本号*，按规范「支持客户端请求版本就回显，否则回自己支持的最高版本」协商
（#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")[Lifecycle: Version Negotiation]）。

=== stdio JSON-RPC 最小实现要点

*一手事实*：stdio 下客户端把 server 拉起为子进程，消息是按行分隔的 UTF-8 JSON-RPC 2.0，单条消息内
不得含换行；「server MUST NOT write anything to its stdout that is not a valid MCP message」，日志只能
写 stderr（#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/transports")[Transports: stdio]）。
这是整个实现里最容易踩、后果最严重的一条约束。

#table(
  columns: 2,
  [*方法*], [*响应*],
  [`initialize`], [返回 `protocolVersion` / `capabilities` / `serverInfo`（+ 可选 `instructions`）],
  [`notifications/initialized`], [无 `id`，绝不回包],
  [`tools/list`], [返回 `{ tools: [...] }`；工具名与顺序保持确定，利于 prompt cache],
  [`tools/call`], [返回 `{ content: [...] }`；业务失败用 `isError: true`],
  [`ping`], [返回 `{}`（`2025-06-18` 有；`2026-07-28` 已删）],
  [未知方法], [JSON-RPC 错误 `-32601`],
)

*一手事实*：`capabilities` 只声明真正实现的能力；参照实现只声明 `{ tools: {} }`，不声明 `resources`、
`prompts`、`logging`、`listChanged`、`subscribe`（同文件第 137 行）。`InitializeResult` 另支持可选
`instructions`，用于在系统提示层写「先验证再声称证明」这类硬约束，是零成本提升工具选择准确率的位置
（#link("https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2025-06-18/schema.ts")[schema.ts, InitializeResult]）。

可直接复用的骨架（零依赖，照参照实现结构重写）：

```js
import readline from 'node:readline';
const send = (m) => process.stdout.write(`${JSON.stringify(m)}\n`);

async function dispatch(msg) {
  if (msg?.jsonrpc !== '2.0') return;
  if (msg.id === undefined || msg.id === null) return;   // 通知，永不回包
  try {
    send({ jsonrpc: '2.0', id: msg.id, result: await handle(msg) });
  } catch (err) {
    send({ jsonrpc: '2.0', id: msg.id,
           error: err.jsonRpc ?? { code: -32603, message: String(err.message ?? err) } });
  }
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); }
  catch { return send({ jsonrpc: '2.0', id: null, code: -32700, message: 'Parse error' }); }
  void dispatch(msg);                                    // 并发处理，勿 await
}).on('close', () => process.exit(0));
```

细节：解析失败按 JSON-RPC 约定回 `id: null` 的 `-32700`（参照实现第 549–556 行即如此）；日志一律走
`console.error`；`dispatch` 不要串行 `await`，否则一个长任务会阻塞后续 `ping` 与取消通知。

=== tools / resources / prompts 如何取舍

*一手事实*：三者交互模型不同——tools 是 *model-controlled*（模型自动发现与调用），resources 是
*application-driven*（宿主决定是否放进上下文、是否给列表 UI），prompts 是 *user-controlled*（通常做成
斜杠命令）（#link("https://modelcontextprotocol.io/specification/2025-06-18/server/tools")[Tools]、
#link("https://modelcontextprotocol.io/specification/2025-06-18/server/resources")[Resources]、
#link("https://modelcontextprotocol.io/specification/2025-06-18/server/prompts")[Prompts]）。

*一手事实*：resource 按 URI 寻址，可带 `mimeType` / `size` / `annotations`（`audience`、`priority`、
`lastModified`），支持参数化模板与可选 `resources/subscribe`；tool 结果里可嵌 `resource_link` 或内嵌
resource 作为「更大上下文的指针」；resource 找不到的错误码在 `2025-06-18` 是 `-32002`，`2026-07-28`
改为 `-32602`（#link("https://modelcontextprotocol.io/specification/2026-07-28/changelog")[2026-07-28 Key Changes]）。

- *推断* 用 *tool* 覆盖「会计算、会起进程、有副作用、需要分页/过滤参数」的一切：跑 `lake build`、
  试 tactic、搜反例、跑基准、开长时证明搜索。tool 是宿主一定支持的通道。
- *推断* 用 *resource* 表示「大、只读、可寻址」的产物：Mathlib 声明索引、goal 快照、solver 完整日志、
  基准结果集。用自定义 URI 方案而非 `https://`，因为内容由本机 server 提供。
- *一手事实* 但 *高风险*：本地参照实现只声明了 `tools`。*宿主是否消费 `resources/list` /
  `resources/read` 完全 `UNVERIFIED`*。所以第一阶段 resource 只能是锦上添花：每个 tool 必须自给自足，
  既能回有界摘要，也能回可被宿主 `Read` 工具直接读取的落盘路径。
- *推断* prompts 价值最低：它由用户显式触发，而大部分动作由模型自主决定。最多做 1～2 条人触发入口。

=== 工具命名与 inputSchema 设计

*一手事实*：工具名限 1–128 字符，只允许 ASCII 字母、数字、`_`、`-`、`.`，同 server 内唯一
（#link("https://modelcontextprotocol.io/specification/2025-06-18/server/tools")[Tools: Tool Names]）。

*一手事实*：Anthropic 的官方建议是不要按底层 API 一对一包装，要合并成面向工作流的工具（用
`schedule_event` 替代 `list_users` + `list_events` + `create_event`，用 `search_logs` 替代 `read_logs`）；
用命名空间前缀划清边界；参数名无歧义（写 `user_id` 而非 `user`）
（#link("https://www.anthropic.com/engineering/writing-tools-for-agents")[Writing effective tools for agents]）。

*一手事实*：真实世界的定理证明 MCP server 正是这么做的。`oOo0oOo/lean-lsp-mcp`（504 stars）暴露 23 个
工具，全部 `lean_` 前缀，按工作流而非 CLI 子命令切分：`lean_goal`、`lean_file_outline`、
`lean_multi_attempt`、`lean_local_search`、`lean_loogle`、`lean_verify`、`lean_minimal_hypotheses`、
`lean_build`（#link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/master/docs/tools.md")[lean-lsp-mcp docs/tools.md]）。

*推断* 该照抄的措辞级模式：

- 前缀用插件名（如 `attack_`），与宿主其他 MCP server 隔离。
- 封闭集合放 `enum`，不要放散文。参照实现的 `get_data_source_desc` 把 25 个数据源与几十行能力说明塞进
  单个 `enum` 的 `description`，并把路由规则写进 tool description（`kimi-datasource.mjs` 第 54–109 行）。
- 校验在 server 侧做，错误文本要能指导自我修正。参照实现的 `requiredString` / `requiredObject` 抛出
  `Missing required argument: params.` 这类可直接执行的信息（同文件第 464–484 行）。
- 批量化：`lean_multi_attempt` 一次接受多个 tactic 并返回各自的 goal 与诊断，而不是让模型发 N 次调用。
  *推断* 这对「候选 tactic 筛选」是决定性的——单次往返成本远高于多算几秒。

返回体积与输出形状：

- *一手事实*：Claude Code 默认把 tool 响应限制在 25k tokens；Anthropic 建议对可能吃上下文的工具一律
  实现分页 / 范围选择 / 过滤 / 截断，并给合理默认值
  （#link("https://www.anthropic.com/engineering/writing-tools-for-agents")[同前]）。
- *一手事实*：Anthropic 建议暴露 `response_format` 枚举（`concise` / `detailed`）让模型自选详细度，实测
  `concise` 只花约三分之一 token；并回报语义名称而非 `uuid`、`mime_type` 这类低层标识符。
- *一手事实*：结构化输出走 `outputSchema` + `structuredContent`，且为向后兼容，返回结构化内容的 tool
  应同时在 `TextContent` 里放序列化 JSON
  （#link("https://modelcontextprotocol.io/specification/2025-06-18/server/tools")[Tools: Structured Content]）。
  *UNVERIFIED*：宿主是否解析 `structuredContent`；本地参照实现只回纯文本，故第一阶段以紧凑文本（必要时
  内含 JSON）为主通道，`structuredContent` 仅作附加字段。
- *推断* 证明搜索结果应回 `{ok, tactic, goal_before, goal_after, diagnostics[]}` 这类字段化结果，而非
  一大段原始输出。

幂等性与破坏性标注：

- *一手事实*：`ToolAnnotations` 四个布尔提示——`readOnlyHint`（默认 `false`）、`destructiveHint`
  （默认 `true`，仅在 `readOnlyHint == false` 时有意义）、`idempotentHint`（默认 `false`）、
  `openWorldHint`（默认 `true`）
  （#link("https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2025-06-18/schema.ts")[schema.ts, ToolAnnotations]）。
  默认值全在「危险」一侧——不标注等于声明「会破坏环境且可能连外网」。
- *一手事实*：`lean_build` 显式标注 `read_only_hint=False, destructive_hint=True, idempotent_hint=True,
  open_world_hint=False`，描述里写「Use only if needed」
  （#link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/master/src/lean_lsp_mcp/tools/build.py")[tools/build.py]）。
- *推断*：「跑固定 seed 的 `lake build`」可标 `idempotentHint: true`；「跑 300 秒反例搜索」在效果上幂等
  但会重复烧算力——解法不是标 non-idempotent，而是用「内容哈希 → 结果」缓存目录把重试变廉价。
- *推断* 抄 `LEAN_MCP_DISABLED_TOOLS` / `LEAN_MCP_TOOL_DESCRIPTIONS` 启动期覆盖机制
  （#link("https://github.com/oOo0oOo/lean-lsp-mcp#disabling-tools")[README]）：重工具的上下文成本是持续的。

=== 大输出：截断与落盘的双层策略

solver 日志、`lake build` 输出、LSP 诊断是主要失败点：一次调用就能吃掉整个上下文窗口。

第一层，结果里只放有界摘要：

- *一手事实*：`lean_build` 有显式参数 `output_lines: int = 20`，描述是「Return last N lines of build log
  (0=none)」——默认回尾部 20 行，且允许模型设为 0 完全静音；截断量是模型可控的参数，而非不可见的副作用
  （#link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/master/src/lean_lsp_mcp/tools/build.py")[tools/build.py]）。
- *一手事实*：同 repo 的 `BuildResult` 只回 `{success, output, errors[]}`，`DiagnosticMessage` 只回
  `{severity, message, line, column, lean_tags}`，不回传 LSP 原始响应
  （#link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/master/src/lean_lsp_mcp/models.py")[models.py]）。
- *一手事实*：Anthropic 要求截断信息本身带指令，引导模型改用更省 token 的策略（过滤、分页、更小查询）
  （#link("https://www.anthropic.com/engineering/writing-tools-for-agents")[同前]）。*推断* 截断尾部应是
  「已截断至末 200 行，共 48123 行；完整日志见 `<path>`；用 `pattern=` 参数过滤」，而不是 `[truncated]`。

第二层，全量产物落盘，只回路径：

- *一手事实（本机）*：参照实现给出了可照抄的*路径白名单*。后端返回的 `files[]` 只在通过
  `allowedResponseFilePath` 校验后才写盘：`path.resolve` 后要么与请求声明的输出路径完全相同，要么满足
  「同目录 + 同扩展名 + basename 以 `expected_` 前缀开头」，否则丢弃并追加 warning
  （`kimi-datasource.mjs` 第 178–243 行）。这同时挡住路径穿越与「后端往任意位置写文件」。
- *推断*：把这条规则反过来用——所有 solver 日志、模型文件、基准输出都写进插件 workspace 下的受控目录，
  工具结果只回绝对路径 + 摘要。宿主已有 `Read` / `Grep`，模型可按需取用；「按需加载」不需要靠 resources。
- *推断*：`stderr` 与 `stdout` 分两个文件存。solver 的进度在 stderr、结果在 stdout，混在一个文件里会让
  grep 失效。

=== 超时、进程管理与可取消执行

- *一手事实*：「Implementations SHOULD establish timeouts for all sent requests」；超时后应发取消通知并
  停止等待；收到 progress 可重置计时器，但「SHOULD always enforce a maximum timeout」
  （#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")[Lifecycle: Timeouts]）。
- *一手事实*：取消走 `notifications/cancelled`，参数为 `requestId` 加可选 `reason`。收到方 SHOULD 停止
  处理、释放资源、*且不发送响应*；请求未知、已完成或不可取消时 MAY 忽略。`initialize` MUST NOT 被取消；
  取消方应忽略迟到的响应
  （#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation")[Cancellation]）。
- *一手事实*：进度走请求 `_meta` 里的 `progressToken`，服务端发 `notifications/progress`（`progress`
  必须单调递增，`total` / `message` 可选），完成后必须停止
  （#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress")[Progress]）。
- *一手事实*：stdio 关机流程是客户端先关 stdin，等进程退出，超时则 SIGTERM，再 SIGKILL
  （#link("https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")[Lifecycle: Shutdown]）。
- *一手事实（本机）*：参照实现收到 `notifications/cancelled` 直接 `return`，即*忽略*
  （`kimi-datasource.mjs` 第 521 行）。它单次调用是 30 秒超时的 HTTP 请求，这样做没问题。

*推断*，这是本项目最需要偏离参照实现的地方——我们的单次调用可能是分钟到小时级：

- 每个 tool 调用携带自己的预算（`time_limit_s`、`max_output_bytes`、`max_nodes`），并设不可协商的硬上限。
- 子进程必须*按进程组*管理。`lake build`、`julia`、`lean` 都会 fork 子进程，只杀直接子进程会留下孤儿
  进程继续吃 CPU。本机核验：12 核 / 30 GB 内存 / `/usr/bin/timeout` 存在 / cgroup v2（`cgroup2fs`）；
  `timeout(1)` 只约束直接子进程，因此优先用 spawn 时的进程组 + 组信号。
- 用 `Map<requestId, ChildProcess | AbortController>` 记录在途任务。收到 `notifications/cancelled` 时杀
  进程组并立即写「已取消，未产生结果」，避免旧结果污染后续推理。
- 发送 progress 要包在 `try/catch` 里。*一手事实*：lean-lsp-mcp 专门写了 `safe_report_progress` 吞掉
  `ctx.report_progress` 的异常；进度报告失败绝不能杀死正在跑的证明搜索
  （#link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/master/src/lean_lsp_mcp/tool_utils.py")[tool_utils.py]）。
- 共享昂贵资源要有显式并发策略。*一手事实*：lean-lsp-mcp 为 `lean_build` 提供 `LEAN_BUILD_CONCURRENCY`
  （`allow` / `cancel` / `share` 三档），用一个 coordinator 串行化共享 LSP 的重建；另有
  `LEAN_MCP_SCRATCH_SLOTS` 控制并行 scratch 文档数，默认 1，并注明只在该并行度值得额外内存时才提高
  （#link("https://github.com/oOo0oOo/lean-lsp-mcp#environment-variables")[README: Environment Variables]）。
  *推断*：本项目的每个重型求解器槽位都该有同样语义；并行度 $p$ 与单进程内存上界 $M$ 决定内存天花板
  $p times M$，必须小于可用内存。
- 长任务不要绑在连接上。*一手事实*：`2026-07-28` 已把跨调用状态定义为「创建型工具返回不透明 handle，
  后续调用把它当普通参数传回」，并要求在创建工具描述里写明保留期、对过期 handle 返回明确错误
  （#link("https://modelcontextprotocol.io/specification/2026-07-28/server/tools")[2026-07-28 Tools: Stateful Tools]）。
  官方 tasks 扩展进一步给出 `resultType: "task"`、`tasks/get`、`tasks/update`、`tasks/cancel` 与
  `working` / `input_required` / `completed` / `failed` / `cancelled` 状态机，且需客户端显式 opt-in
  （#link("https://modelcontextprotocol.io/specification/2026-07-28/basic/utilities/tasks")[Tasks]）。
  *推断*：宿主是否支持该扩展 `UNVERIFIED`，第一阶段手工实现等价物——`start_*` 返回 `job_id`，加
  `poll_job` / `job_result`，状态落 workspace 的 JSON 文件，使超时重发变成续跑而非重跑。

=== 常见反模式

1. *往 stdout 写非协议内容*。规范是 MUST NOT；一条 `console.log` 就能让整个 session 失效。日志一律 stderr。
2. *把 CLI 子命令一对一包成工具*。Anthropic 明确点名；工具数量还会挤压模型选择正确工具的准确率。
3. *用 JSON-RPC error 报业务错误*。规范 schema 注释写明：工具自身错误 SHOULD 放在结果里配 `isError: true`，
   否则模型看不到、无法自纠
   （#link("https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2025-06-18/schema.ts")[schema.ts, CallToolResult]）。
4. *无界返回*。把 solver stdout 全量塞进 `content` 是上下文杀手。默认必须有界，全量落盘。
5. *返回低层标识符而非语义名称*。Anthropic 的结论是把 UUID 解析成语义名称能显著提升检索精度、减少幻觉；
   对我们即回 fully-qualified 名字与位置，而不是内部 `_meta` blob。
6. *把跨调用状态藏在连接里*。协议已明确不支持隐式会话状态，宿主一重连状态就丢。用显式 handle。
7. *长任务没有取消路径*。参照实现忽略 `notifications/cancelled` 对 30 秒 HTTP 可接受，对本项目不可接受。
8. *未声明破坏性*。`destructiveHint` 与 `openWorldHint` 默认都是 `true`，不标注等于默认最危险的语义。
9. *把外部文本原样回传给模型*。规范要求 server「MUST sanitize tool outputs」，反例搜索天然引入外部文本
   （#link("https://modelcontextprotocol.io/specification/2025-06-18/server/tools")[Tools: Security Considerations]）。
10. *文档与实现不符*。*UNVERIFIED*：lean-lsp-mcp README 称 `LEAN_LOG_LEVEL` 未设置时 logs are printed to
    stdout；若 stdio 下当真如此就违反第 1 条（#link("https://github.com/oOo0oOo/lean-lsp-mcp#environment-variables")[README]）。

=== 评估

1. *抄*：以 `kimi-datasource.mjs` 为骨架写 `bin/<plugin>.mjs`——564 行、零运行时依赖、`readline` + 方法
   switch + `notifications/*` 永不回包的短路 + 解析错误回 `id: null` 的 `-32700`。只改一处：协议版本回显
   客户端请求值，不硬编码 `2025-06-18`。
2. *抄*：照搬 lean-lsp-mcp 的「命名 + 切分」组合——`attack_` 前缀、按工作流而非 CLI 切分、批量化工具
   （`lean_multi_attempt` 一次试多个 tactic）、`LEAN_MCP_DISABLED_TOOLS` 式重工具开关。尤其照搬它把
   *验证独立成工具*：`lean_verify` 返回 `axioms` 并检测 `sorryAx`，证明搜索插件必须自带 soundness 门禁。
3. *抄*：`lean_build` 的 `output_lines: int = 20`（尾部 N 行，0 表示不回）与
   `BuildResult{success, output, errors[]}` 字段化返回。所有跑外部 solver 的工具都该有等价的「尾部行数、
   静音」参数，默认值小、由模型调节。
4. *抄*：`allowedResponseFilePath` 的路径白名单（resolve 后必须与请求路径相同，或同目录同扩展名且
   basename 带预期前缀），把 solver 日志与模型文件写进受控 workspace 目录，结果只回路径 + 摘要。
5. *避*：第一阶段不要依赖 `resources` 与 `prompts`。本地参照实现只声明 `{ tools: {} }`，宿主对 resources
   的支持 `UNVERIFIED`。每个工具必须自给自足：既有有界摘要，也有可被 `Read` 直接读取的落盘路径。
6. *避*：不要沿用参照实现对 `notifications/cancelled` 的忽略。实现 `Map<requestId, 进程组句柄>` + 组杀 +
   硬超时 + `safe_report_progress`，并把长任务做成 `start_*` 返回 `job_id`、`poll_job` 轮询的显式 handle
   模式（tasks 扩展在宿主端的支持同样 `UNVERIFIED`）；状态落 JSON 文件，使超时重发变成续跑而非重跑。

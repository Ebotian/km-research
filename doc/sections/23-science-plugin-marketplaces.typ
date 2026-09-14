== 科研/数学类 agent 插件与 MCP 的先例

本节只记录*一手可核验*的成品：能打开官方文档、插件清单或仓库 README 的项目。文中【一手】= 来源页面/仓库直接写明；【推断】= 本调研的解读。所有 URL 于 2026-09-14 抓取。本机环境实测：`uv`/`uvx`/`npx`/`docker`/`node`/`python3`/`julia`/`lean`+`lake`/`typst` 均在 PATH；`sympy`、`pandas`、`z3` 未安装（`numpy 2.5.2`、`matplotlib 3.11.1` 已装），`sage`/`gap`/`pari` 无。

=== (a) Claude Code 插件市场里的科研类插件

- *官方领域市场 `anthropics/life-sciences`*：这是目前最接近「科研插件市场」的成品。市场清单文件为仓库根的 `.claude-plugin/marketplace.json`，共 *21 个插件条目*：远程 MCP 服务器（`pubmed`、`biorxiv`、`clinical-trials`、`chembl`、`consensus`、`wiley-scholar-gateway`、`cortellis`、`adisinsight`、`open-targets`、`owkin`、`medidata`、`synapse`、`biorender`）＋ 本地 MCP（`10x-genomics`，MCPB 打包）＋ 技能型插件（`single-cell-rna-qc`、`scvi-tools`、`nextflow-development`、`instrument-data-to-allotrope`、`clinical-trial-protocol`、`scientific-problem-selection`、`tooluniverse`）。安装菜单形如 `/plugin install pubmed@life-sciences`。#link("https://github.com/anthropics/life-sciences")[github.com/anthropics/life-sciences]
- 同一模式已被复制到其它领域市场：`anthropics/healthcare`（8 条，含 `pubmed`、`cms-coverage`、`npi-registry`，旧条目以 `Deprecated — install healthcare@healthcare instead` 标记迁移）、`anthropics/financial-services`。说明「领域市场 + 多插件」已是官方稳定做法。#link("https://github.com/anthropics/healthcare")[anthropics/healthcare] #link("https://github.com/anthropics/financial-services")[anthropics/financial-services]
- *数学方向的唯一成熟插件：`cameronfreer/lean4-skills`*。它同时包含「技能 + 命令 + 钩子 + 子代理 + 辅助运行时」，命令一行安装：`/plugin marketplace add cameronfreer/lean4-skills`、`/plugin install lean4`；`plugin.json` 只有 `name`/`version`/`description`/`author` 四个字段，其余组件由目录约定发现。#link("https://github.com/cameronfreer/lean4-skills")[github.com/cameronfreer/lean4-skills]
- 该插件的核心是 12 个工作流：`draft`、`formalize`、`autoformalize`、`prove`、`autoprove`、`disprove`（反例搜索 + 认证反驳）、`checkpoint`、`review`、`refactor`、`golf`、`learn`、`diagnose`；证明类工作流共享一个显式状态机 *Plan → Work → Checkpoint → Review → Replan → Continue/Stop*，卡死时强制回退到 review+replan。README 明确它「可独立使用，但最好配 `lean-lsp-mcp`」。【一手】
- *社区大市场里科研是空档*：`wshobson/agents` 的 `marketplace.json` 有 94 个插件，分类为 `ai-ml`/`data`/`language`/`security`… 完全没有数学、证明、物理、生物类目（最接近的是 `quantitative-trading`、`machine-learning-ops`）。【一手】#link("https://github.com/wshobson/agents")[github.com/wshobson/agents]
- *市场文件格式（可直接照抄的字段布局）*：`.claude-plugin/marketplace.json` 需要 `name`（kebab-case，全局唯一）、`owner`、`plugins[]`；每个条目至少 `name` + `source`，可选 `description`/`version`/`category`/`tags`/`strict`/`defaultEnabled`，以及组件路径 `skills`/`commands`/`agents`/`hooks`/`mcpServers`/`lspServers`。`source` 支持相对路径、`github`、`url`、`git-subdir`、`npm`、`archive`（须 HTTPS + `sha256`）、`command`（本地命令生成插件目录，`timeout` ≤ 600s，`mode: copy|link`）；插件被复制到 `~/.claude/plugins/cache`，配置里用 `${CLAUDE_PLUGIN_ROOT}` 引用插件内文件；`strict: false` 表示市场条目即完整定义、不需要插件自带 `plugin.json`；`version` 一旦设置即被钉住，改动才触发更新；还有 `renames` 字段做改名迁移。#link("https://code.claude.com/docs/en/plugin-marketplaces")[code.claude.com/docs/en/plugin-marketplaces]
- 跨厂商的技能标准与目录：技能格式被抽象为 Agent Skills 标准（#link("https://agentskills.io")[agentskills.io]），Anthropic 自家技能集在 #link("https://github.com/anthropics/skills")[anthropics/skills]，社区索引站如 #link("https://skills.sh")[skills.sh]、#link("https://claudemarketplaces.com")[claudemarketplaces.com]（后两者的收录口径与质量未逐条核验，`UNVERIFIED`）。
- 结论【推断】：科研/数学插件生态的真实重心在 *MCP 数据源*（文献、库、数据库）与 *单一形式化工具链*（Lean）两端；「开放问题攻击」这一整条流水线（猜想形式化 → 证明搜索 → 反例搜索 → 上界改进 → 基准评测）目前没有任何成品覆盖，`lean4-skills` 只覆盖了其中「形式化 + 证明 + 反驳」段。

=== (a') 四份真实清单：本项目的 `plugin.json` 可逐字段对照

`cameronfreer/lean4-skills` 的 `plugins/lean4/.claude-plugin/plugin.json` 是最小可用形态，只有身份信息，组件全部靠目录约定发现（仓库中该文件 307 字节，逐字如下）：

```json
{
  "name": "lean4",
  "version": "4.9.0",
  "description": "Unified Lean 4 plugin (draft, formalize, autoformalize, prove, autoprove, disprove, checkpoint, review, refactor, golf, learn, diagnose) — LSP-first, scripts fallback",
  "author": {"name": "Cameron Freer", "email": "cameronfreer@gmail.com"}
}
```

同一仓库的市场清单用 `source` 指向插件目录，`metadata` 里放市场级描述与版本：

```json
{
  "name": "lean4-skills",
  "owner": {"name": "Cameron Freer", "email": "lean4skills@gmail.com"},
  "metadata": {"description": "Lean 4 theorem proving with guided + autonomous proving, LSP-first workflows, guardrails, and contribution helpers", "version": "4.9.0"},
  "plugins": [
    {"name": "lean4", "description": "Unified Lean 4 plugin (draft, formalize, ...)", "source": "./plugins/lean4"},
    {"name": "lean4-contribute", "description": "Draft and submit bug reports ...", "source": "./plugins/lean4-contribute"}
  ]
}
```

官方市场 `anthropics/life-sciences` 的条目把分类与标签显式写在市场文件里（不依赖插件自身）：

```json
{
  "name": "pubmed",
  "source": "./pubmed",
  "description": "PubMed MCP server for searching biomedical literature and research articles",
  "category": "life-sciences",
  "tags": ["research", "literature", "biomedical"]
}
```

MCP 服务器在宿主侧的统一形状（Daytona 官方由 `daytona mcp config` 打印，字段名与 Claude 系客户端一致；我们用 `${HOME}` 一类的环境变量而非硬编码路径）：

```json
{
  "mcpServers": {
    "daytona-mcp": {
      "command": "daytona",
      "args": ["mcp", "start"],
      "env": {"HOME": "${HOME}", "PATH": "${HOME}:/usr/local/bin:/usr/bin:/bin"}
    }
  }
}
```

【推断】对我们的三点直接含义：其一，`plugin.json` 应当只放身份与版本，技能/命令/钩子/MCP 用目录约定（`skills/<name>/SKILL.md`、可选 `mcpServers`）声明，这样清单文件才稳定；其二，把「本插件提供哪些工具」写进技能正文而不是清单，符合 `zotero-mcp` 的上下文预算结论；其三，来源路径一律用相对路径 + 宿主提供的根变量，避免安装时被复制到缓存目录后路径失效。

=== (b) 数学 MCP

*Wolfram：唯一的商业级数学 MCP 家族。* 官方把入口分成三种部署：#link("https://www.wolfram.com/artificial-intelligence/mcp/")[Wolfram MCP 总览]。
- *Local MCP*（会话式、可读本地文件、可写 notebook、可自建自定义 server）随 Wolfram Engine / Wolfram|One / Mathematica 提供，官方写明「Version 15 起随桌面产品附带」，并列出 Claude Code、Codex、Cursor 等客户端；*Cloud MCP* 免费但无会话、无文件、不能自建 server。#link("https://www.wolfram.com/artificial-intelligence/mcp/local/")[Local MCP] #link("https://www.wolfram.com/artificial-intelligence/mcp/cloud/")[Cloud MCP]
- 实现是 Wolfram 语言 paclet `Wolfram/MCPServer`（`PacletInstall["Wolfram/MCPServer"]`），提供 `CreateMCPServer`、`InstallMCPServer`、`MCPServerObject`、`$DefaultMCPTools`、`$DefaultMCPToolOptions`、`$SupportedMCPClients` 等符号；自定义工具用 `LLMTool["PrimeFinder", {"n" -> "Integer"}, Prime[#n] &]` 这类形式声明，再按名字组装进 server。#link("https://resources.wolframcloud.com/PacletRepository/resources/Wolfram/MCPServer/")[Wolfram/MCPServer paclet]
- 默认工具（文档逐条给出 Name/Description）：`WolframLanguageEvaluator`（在 WL 内核里执行代码并返回结果）、`WolframAlphaContext`、`WolframContext`、`WolframLanguageContext`（三者都是「语义检索 + 当话题变化时先调用」的上下文工具）、`ReadNotebook`（把 `.nb` 读成 Markdown）、`WriteNotebook`（Markdown 写回 notebook）、`CodeInspector`、`CreateSymbolDoc`。#link("https://resources.wolframcloud.com/PacletRepository/resources/Wolfram/MCPServer/tutorial/DefaultTools.html")[Default Tools]
- 本机不可用【一手实测】：无 Mathematica/Wolfram Engine，也没有 LLM Tools 的本地包；因此在没有许可证的机器上这条路线只能作为设计参照，不能作为依赖。

*SymPy MCP（`sdiehl/sympy-mcp`）*：31 个工具，走「有状态会话」模型——`intro`/`intro_many` 引入带假设的符号、`introduce_expression` 解析并存入会话、`print_latex_expression` 输出 LaTeX，然后是 `solve_algebraically`、`solve_linear_system`、`solve_nonlinear_system`、`dsolve_ode`、`pdsolve_pde`、`simplify_expression`、`substitute_expression`、`integrate_expression`、`differentiate_expression`、`create_matrix`/`matrix_determinant`/`matrix_inverse`/`matrix_eigenvalues`/`matrix_eigenvectors`，以及一整组广义相对论/张量与矢量微积分工具（`create_predefined_metric`、`calculate_tensor`、`calculate_curl`、`calculate_divergence`、`calculate_gradient`）。#link("https://github.com/sdiehl/sympy-mcp")[github.com/sdiehl/sympy-mcp]

*SageMath MCP（`XBP-Europe/sagemath-mcp`）*：约 40 个工具按类别组织，含 `evaluate_sage`/`evaluate_sage_streaming`、`verify_claim`（验证声明）、`solve_ode`、`number_theory_operation`、`graph_operation`、`group_operation`、`elliptic_curve_operation`、`coding_theory_operation`、`polynomial_ring_operation`、`plot_expression`，以及会话控制 `start_sage_session`/`reset_sage_session`/`interrupt_sage_session`。要有 Sage 环境才能用；本机未安装 Sage/GAP/PARI，*不可直接复用*。#link("https://github.com/XBP-Europe/sagemath-mcp")[github.com/XBP-Europe/sagemath-mcp]

*Lean 的 LSP 桥 `lean-lsp-mcp`*：23 个工具，是本项目最该照抄的数学工具面（详细清单见 (e)）。除静态查询外有三件「研究专用」工具值得注意：`lean_multi_attempt`（在同一位置批量试 tactic 并回传每个目标态）、`lean_minimal_hypotheses`（逐个删去显式假设重新 elaboration，报告哪些假设真正承重、以及删除后每条新错误的位置）、`lean_verify`（检查公理使用与 `unsafe`/`sorryAx` 等不健全标记）。它还提供 `LEAN_MCP_DISABLED_TOOLS`/`LEAN_MCP_INSTRUCTIONS`/`LEAN_MCP_TOOL_DESCRIPTIONS` 三个环境变量做工具裁剪与提示覆盖、路径白名单、可自托管 loogle、并在 README 里给出容器化隔离建议。#link("https://github.com/oOo0oOo/lean-lsp-mcp")[github.com/oOo0oOo/lean-lsp-mcp] #link("https://github.com/oOo0oOo/lean-lsp-mcp/blob/main/docs/tools.md")[docs/tools.md]

*其它 Lean 侧线索*：`KrystianYCSilva/lean-mcp`（PyPI `lean-mcp`）存在，但 README 抓取 404，能力 `UNVERIFIED`；Mathematica 的 MCP 能力即上文 Wolfram Local MCP，没有独立第三方实现。

=== (c) 通用科研 MCP

- *`blazickjp/arxiv-mcp-server`（arXiv 全文 + 引文）*：18 个工具 + 7 个内置 prompts。亮点是*有界读取*：`download_paper` 默认只留 12,000 字符，`read_paper` 同样有界，并拆成 `get_paper_outline` → `read_paper_section` → `search_paper_text` 三级检索；`citation_graph` 走 Semantic Scholar；`watch_topic`/`list_watches`/`check_alerts`/`unwatch_topic` 提供「主题订阅 → 新论文提醒」；`export_citations` 输出 BibTeX。prompts 里有 `research-discovery`、`literature_review`、`research-question`。它同时打包成 Claude Code（`.claude-plugin/plugin.json` + `marketplace.json`）、Codex（`.codex-plugin/`）与 Kiro Power，并共用同一份 `skills/arxiv-mcp-server/SKILL.md`。#link("https://github.com/blazickjp/arxiv-mcp-server")[github.com/blazickjp/arxiv-mcp-server]
- *`openags/paper-search-mcp`（多源联邦检索）*：两层架构——Layer 1 为 `search_papers`（多源并发 + 去重）与 `download_with_fallback`（源站 → OpenAIRE/CORE/Europe PMC/PMC → Unpaywall DOI → 可选 Sci-Hub），Layer 2 是各平台连接器（`search_arxiv`/`search_pubmed`/`search_biorxiv`/`search_medrxiv`/`search_google_scholar`/`search_iacr`/`search_semantic`，以及 IEEE/ACM 需 key 才注册）；`server.py` 中 `@mcp.tool` 装饰器共 63 处。它*同时*提供 Claude Code Skill 安装路径（`uv tool install paper-search-mcp` + 一份 `SKILL.md` 到 `~/.claude/skills/paper-search/`），并明确推荐 Claude Code 用户优先用 skill 而非 MCP。#link("https://github.com/openags/paper-search-mcp")[github.com/openags/paper-search-mcp]
- *`54yyyu/zotero-mcp`（本地文献库）*：默认面 38 个工具，工具名统一 `zotero_*` 前缀，例如 `zotero_search_items`、`zotero_advanced_search`、`zotero_semantic_search`、`zotero_get_item_metadata`、`zotero_get_item_fulltext`、`zotero_get_pdf_outline`、`zotero_get_annotations`、`zotero_create_annotation`、`zotero_add_by_doi`/`_bibtex`/`_csl_json`。它有两个对插件设计极有价值的一手事实：其一，README 自测「MCP 默认 38 工具 = 每次请求 13,448 tokens；同一份能力的 CLI skill 只有 98 tokens，正文加载后 1,368 tokens」，并附 `scripts/measure_context_cost.py` 与回归测试；其二，工具按组开关（`ZOTERO_MCP_TOOLSETS=none|all|scite,duplicates|all,-scite`，`discovery` 组含 `find_related_papers`、`library_coverage`），被关闭的工具是*真正不注册*而非隐藏；其三，`zotero-mcp install-skill` 会探测 8 类宿主并写入各自格式（`.claude/skills/`、`.cursor/rules/`、`AGENTS.md` 标记块等）。#link("https://github.com/54yyyu/zotero-mcp")[github.com/54yyyu/zotero-mcp]
- *`datalayer/jupyter-mcp-server`（可执行代码的 notebook 面）*：18 个工具 + 4 个资源（notebook / cell / cell-output / capabilities）+ 1 个 prompt（`jupyter_cite`）。工具分四组——文件与内核（`list_files`、`list_kernels`、`connect_to_jupyter`）、notebook（`use_notebook`、`list_notebooks`、`read_notebook`、`restart_notebook`、`unuse_notebook`）、单元格（`insert_cell`、`read_cell`、`edit_cell_source`、`overwrite_cell_source`、`delete_cell`、`move_cell`、`clear_cell_output`、`insert_execute_code_cell`）、执行（`execute_cell`、`execute_code`）。另可挂 4 种沙箱后端并暴露 `launch_sandbox`/`list_sandboxes`/`use_sandbox`/`terminate_sandbox`（需 `jupyter_mcp_sandboxes` 扩展）。工具 schema 不写在 README 里，而是发布在 `jupyter-mcp-server.datalayer.tech/mcp` 的运行时快照上。【一手】#link("https://github.com/datalayer/jupyter-mcp-server")[github.com/datalayer/jupyter-mcp-server]
- *仓库/数据归档*：`MSKazemi/mcp-zenodo` 11 个工具（`search_records`、`get_metadata`、`get_citation`、`detect_data_type`、`compare_records`、`list_files`、`download_file`、`generate_embed_link`、`extract_keywords`、`get_related_records`、`summarize_record`）；`SourceShift/osf-mcp-server` 11 个工具（`search_projects`、`search_registrations`、`search_preprints`、`get_project`、`create_project`、`update_project`、`list_files`、`download_file`、`read_file`、`get_wiki`、`resolve_doi`，支持 `OSF_TOKEN` 与 PDF→Markdown）。两者体量小、单作者，属于「够用即止」。#link("https://github.com/MSKazemi/mcp-zenodo")[MSKazemi/mcp-zenodo] #link("https://github.com/SourceShift/osf-mcp-server")[SourceShift/osf-mcp-server]

=== (d) 计算与沙箱 MCP

- *DuckDB / MotherDuck MCP*：5 个工具 `execute_query`（DuckDB 方言 SQL）、`list_databases`、`list_tables`、`list_columns`、`switch_database_connection`（需 `--allow-switch-databases`）；结果默认截断 1024 行 / 50,000 字符；支持只读模式。README 明确警告「只读模式不足以给第三方用，它仍能访问本地文件系统」。这是目前最成熟的本地表格分析 MCP，比 pandas 类实现更值得依赖。#link("https://github.com/motherduckdb/mcp-server-motherduck")[github.com/motherduckdb/mcp-server-motherduck]
- *Pandas MCP 生态*：`marlonluo2018/pandas-mcp-server` 只有 4 个工具（`read_metadata_tool`、`interpret_column_data`、`run_pandas_code_tool`、`generate_chartjs_tool`），属个人项目体量；本机 `pandas` 也未安装。【一手】#link("https://github.com/marlonluo2018/pandas-mcp-server")[github.com/marlonluo2018/pandas-mcp-server] *推断*：不要指望「pandas MCP」这一层，表格计算应当走 DuckDB/Jupyter 或我们自己的薄封装。
- *SQLite MCP*：官方参考实现 `modelcontextprotocol/servers-archived` 里的 SQLite server，6 个工具 `read_query`、`write_query`、`create_table`、`list_tables`、`describe_table`、`append_insight`。仓库已归档，*不宜作为新项目的依赖*，只适合当最小 schema 范例。#link("https://github.com/modelcontextprotocol/servers-archived/tree/main/src/sqlite")[modelcontextprotocol/servers-archived]
- *Docker MCP Gateway / Catalog*：官方目录收录 *300+ 个 MCP 服务器*，每个以隔离容器运行、由 Docker 签名并附 SBOM 与 provenance；gateway 提供统一入口、secrets 管理、OAuth 流程与「动态发现」（Dynamic MCP，agent 在对话中按需发现并启用服务器，检索工具叫 `mcp-find`）；支持自定义 catalog（把 300+ 收窄到团队允许的 20 个）与导出 CLI 配置。这是「工具爆炸」问题在基础设施层的官方答案。【一手】#link("https://docs.docker.com/ai/mcp-catalog-and-toolkit/catalog/")[Docker MCP Catalog] #link("https://github.com/docker/mcp-gateway")[docker/mcp-gateway]
- *Daytona 沙箱 MCP*：随 Daytona CLI 提供，`daytona mcp init claude|cursor|windsurf` 写入配置、`daytona mcp start` 启动、`daytona mcp config` 打印 `mcpServers` JSON；工具覆盖沙箱管理、文件系统、Git、进程与代码执行、computer use、preview——*README 只给分类不给工具名*，逐个 tool 名 `UNVERIFIED`。#link("https://www.daytona.io/docs/en/mcp")[daytona.io/docs/en/mcp]
- *Modal 与 E2B*：Modal 官方没有自己的 MCP 服务器文档页（`modal.com/docs/guide/mcp` 404），而是发了一篇《Best Code Execution Sandboxes for MCP Servers in 2026》横评（文中引用的「97M+ 月下载」为第三方转述数字）；社区实现如 `amichae2/modal-sandbox-mcp` 是个人项目。E2B 官方有 `e2b-dev/mcp-server`（把代码执行交给 E2B 沙箱）。#link("https://modal.com/resources/best-code-execution-sandboxes-mcp-servers")[modal.com/resources] #link("https://github.com/amichae2/modal-sandbox-mcp")[modal-sandbox-mcp] #link("https://github.com/e2b-dev/mcp-server")[e2b-dev/mcp-server]
- 官方注册表已上线：`https://registry.modelcontextprotocol.io/v0/servers` 返回带 `_meta.io.modelcontextprotocol.registry/official`（status/publishedAt/updatedAt/isLatest）的分页 JSON，可编程发现服务器。【一手实测】#link("https://registry.modelcontextprotocol.io/v0/servers")[MCP Registry API]

=== (e) 工具清单：可直接照抄的命名与粒度

数学/形式化（`lean-lsp-mcp`，23 个工具，全部可核验）：

#table(columns: 3,
  [*工具*], [*作用*], [*备注*],
  [`lean_goal`], [取某位置的证明目标态], [最常用，证明循环的心跳],
  [`lean_term_goal`], [取某位置的 term goal], [],
  [`lean_diagnostic_messages`], [文件级诊断（info/warn/error/hint）], [`interactive` 返回 widget],
  [`lean_file_outline`], [文件声明与类型签名的提纲], [先看结构再读正文],
  [`lean_multi_attempt`], [同一位置批量试 tactic 并回传目标态], [搜索空间展开的关键],
  [`lean_code_actions`], [LSP code action，解析 `simp?`/`exact?`/`apply?` 的 Try-This 编辑], [由 agent 自己落盘],
  [`lean_run_code`], [独立片段编译并回传结果], [不污染主文件],
  [`lean_verify`], [检查公理使用与 `unsafe`/`sorryAx` 等不健全标记], [证明可信度的守门工具],
  [`lean_minimal_hypotheses`], [逐个删假设重编译，报告承重假设与随之而来的错误], [锐化定理],
  [`lean_profile_proof`], [对定理跑 `lean --profile`，给逐行耗时], [性能上界改进可用],
  [`lean_local_search`], [本地工程与 stdlib 内检索定义/定理], [],
  [`lean_leansearch`], [自然语言检索 Mathlib（leansearch.net）], [外部服务],
  [`lean_loogle`], [按类型签名检索 Mathlib（loogle）], [可自托管],
  [`lean_leanfinder`], [语义检索 Mathlib（Lean Finder）], [外部服务],
  [`lean_state_search`], [针对当前证明目标检索可用定理（premise-search.com）], [],
  [`lean_hammer_premise`], [基于证明状态的 premise search], [],
  [`lean_build`], [跑 `lake build` 并重启 LSP], [重工具，可禁用],
  [`lean_hover_info` / `lean_references` / `lean_completions` / `lean_declaration_file`], [悬停文档 / 引用 / 补全 / 声明所在文件], [常规 IDE 面],
  [`lean_get_widgets` / `lean_get_widget_source`], [取面板 widget 及其 JS 源码], [易冗长]
)

文献与数据（跨项目汇总）：

#table(columns: 3,
  [*服务器*], [*代表性工具*], [*作用*],
  [`arxiv-mcp-server`], [`search_papers` / `download_paper` / `get_paper_outline` / `read_paper_section` / `search_paper_text`], [检索、下载、提纲级有界阅读（默认 12k 字符）],
  [`arxiv-mcp-server`], [`citation_graph` / `export_citations` / `watch_topic` / `check_alerts`], [引文图、BibTeX、主题订阅提醒],
  [`paper-search-mcp`], [`search_papers` / `download_with_fallback` / `search_arxiv` … `search_semantic`], [多源并发检索 + OA 回退下载],
  [`zotero-mcp`], [`zotero_search_items` / `zotero_advanced_search` / `zotero_semantic_search`], [本地文献库检索（默认 38 工具，13,448 tokens/请求）],
  [`zotero-mcp`], [`zotero_get_pdf_outline` / `zotero_get_item_fulltext` / `zotero_get_annotations`], [按提纲/页范围读 PDF，抽批注],
  [`jupyter-mcp-server`], [`use_notebook` / `insert_cell` / `execute_cell` / `execute_code`], [notebook 与内核上的可复现执行],
  [`mcp-zenodo`], [`search_records` / `get_citation` / `download_file`], [归档检索与引用],
  [`osf-mcp-server`], [`search_projects` / `search_registrations` / `resolve_doi`], [预注册研究与 DOI 解析],
  [`duckdb MCP`], [`execute_query` / `list_tables` / `list_columns`], [本地 SQL 分析，1024 行 / 50k 字符截断]
)

=== (f) 哪些已经足够好，可直接复用

#table(columns: 4,
  [*本项目需求*], [*现成方案*], [*本机可跑?*], [*结论*],
  [论文检索与全文有界阅读], [`arxiv-mcp-server`（`uvx` 即可）], [是（`uv`/`uvx` 已装）], [直接复用，不自研],
  [多源文献检索与 OA 回退], [`paper-search-mcp`（也提供 skill 路线）], [是], [直接复用，仅做工具名前缀与 SKILL.md 适配],
  [个人文献库/批注], [`zotero-mcp`], [需本地 Zotero + 建索引], [可选复用],
  [Lean 证明状态与 Mathlib 检索], [`lean-lsp-mcp` + `cameronfreer/lean4-skills`], [是（`lean`/`lake` 已装）], [直接复用 + 抄插件结构],
  [符号计算], [`sympy-mcp`], [需 `uv tool install`（本次禁止安装）], [复用，但注意其有状态会话模型],
  [Sage/GAP/PARI 级数论与群论], [`sagemath-mcp`], [否（无 Sage）], [暂不作为依赖，写成可选后端],
  [Wolfram 计算与知识库], [Wolfram Local/Cloud MCP], [否（无许可证）], [仅作设计参照],
  [表格数据分析], [DuckDB MCP / Jupyter MCP], [是（`docker` 可选）], [复用，放弃 pandas 类 MCP],
  [结构化查询], [SQLite 官方参考实现], [是], [*不*复用（仓库已归档），需要时自写薄封装],
  [远程/隔离沙箱], [Docker MCP Gateway、Daytona、E2B、Modal], [`docker` 有，远程需账号], [先本地 Docker，远程留可选]
)

=== 生态空缺与已暴露的坑

- *缺口一：没有端到端成品*。检索（GitHub 仓库搜索 + 官方文档）未发现任何插件/marketplace 覆盖「猜想形式化 → 证明搜索 → 反例搜索 → 上界改进 → 基准评测」全链路；覆盖最深的 `lean4-skills` 也止于形式化与证明/反驳，反例搜索仅作为 `disprove` 工作流内的一个动作。【一手（检索证据）+ 推断】
- *缺口二：可用数学后端很窄*。能查到的数学类 MCP 集中在 Wolfram、SymPy、SageMath、Lean 四家；GAP、PARI/GP、Maxima、Magma 未见可用 MCP（本次检索范围内，标注为「未发现」而非不存在）。本机同时缺 Sage 与 SMT 求解器，进一步收窄了可依赖范围。
- *缺口三：表格/数据层薄弱*。量级最大的「pandas MCP」只有 4 个工具、个人维护；成熟的对照物是 DuckDB MCP（5 个工具 + 行/字符截断 + 只读模式）与 Jupyter MCP（18 个工具，直接跑内核）。*推断*：本项目不要自研 dataframe 工具，把表格计算交给这两个之一。
- *缺口四：官方 SQLite 参考实现已归档*。`modelcontextprotocol/servers-archived` 下的 SQLite server（6 个工具）不再维护；新项目不宜依赖，只能当最小 schema 范例。
- *坑一：工具面 = 每请求固定开销*。`zotero-mcp` 实测 38 工具 13,448 tokens/请求，50 工具 17,414，32 工具 11,761；它的对策是环境变量分组裁剪 + 同时提供 CLI skill（98 tokens）。Docker 侧的对策是动态发现（`mcp-find` + 自定义 catalog 把 300+ 收窄到 20）。两者都指向同一结论：默认面要小。
- *坑二：插件会被复制进缓存目录*。Claude Code 把安装后的插件复制到 `~/.claude/plugins/cache`，插件内引用目录之外的相对路径（如 `../shared-utils`）会失效，必须用 `${CLAUDE_PLUGIN_ROOT}` 或重构目录；`version` 一旦在市场条目或 `plugin.json` 中设置即被钉住，用户只在版本号变化时收到更新；`strict: false` 时市场条目即完整定义、插件自带 `plugin.json` 反而导致加载失败，二者不可混用。#link("https://code.claude.com/docs/en/plugin-marketplaces")[plugin-marketplaces]
- *坑三：多宿主维护成本*。`arxiv-mcp-server` 为同一份能力维护 Claude Code、Codex、Kiro 三套清单；而 `paper-search-mcp`、`zotero-mcp` 选择「一份 SKILL.md + 一个 CLI」，由安装器按宿主探测写入各自格式（`.claude/skills/`、`.cursor/rules/`、`AGENTS.md` 标记块）。*推断*：当能力不需要常驻会话时，skill+CLI 的维护面积明显更小。

=== 评估

- *抄 lean4-skills 的「证明循环即技能」*：把 Plan → Work → Checkpoint → Review → Replan → Stop 这套状态机写进 `<plugin>/skills/<name>/SKILL.md`，用 `/命令` 暴露 `formalize`/`prove`/`disprove`/`golf` 这些*工作流动词*，把 `lean_goal`/`lean_multi_attempt` 之类的原子工具留给 MCP。我们的「攻击开放问题」是同一形状，直接沿用这个分层即可，不必自创命令体系。
- *抄 arxiv-mcp-server 的「有界默认值」*：任何会吐大块文本的工具都必须有默认字符上限与两段式读取（提纲 → 指定小节），而不是把整篇论文/整份证明日志塞进一次返回。把它写成我们 MCP 的硬约定：所有 `read_*` 类工具默认 ≤ 12k 字符，超出必须分页。
- *抄 zotero-mcp 的上下文预算纪律*：默认工具面保持小（它 38 工具 = 13,448 tokens/请求，这是可实测的浪费），用环境变量分组裁剪（`ZOTERO_MCP_TOOLSETS` 那种 `all,-scite` 语法），并同时提供「skill + 本地 CLI」这条 ~98 tokens 的廉价入口。本项目建议 MCP 工具控制在 15 个以内，其余能力下沉到 SKILL.md 与 `scripts/`。
- *抄 lean-lsp-mcp 的可配置与安全默认*：提供 `*_DISABLED_TOOLS`、`*_INSTRUCTIONS`、`*_TOOL_DESCRIPTIONS` 三个环境变量（含「用 JSON 覆盖单个工具描述」），加路径白名单与容器化指引；我们还应照做「重工具（如整库 build、全量搜索）默认禁、按需开」。
- *避免重复造文献轮子*：`arxiv-mcp-server` 与 `paper-search-mcp` 已覆盖 arXiv/PubMed/bioRxiv/Semantic Scholar/Crossref/OpenAlex 等约 20 个源以及 OA 回退链，且本机 `uvx` 可用。我们只写「与证明/猜想状态耦合」的那一层（如 `conjecture_*`、`counterexample_*`、`bench_*`），检索能力外挂。
- *避免把未安装引擎当作前提*：Sage/GAP/PARI/Wolfram 在本机不可用，`z3`/`cvc5` 也未安装，而 `lean`+`lake`、`julia`、`python3(uv)`、`docker` 可用。因此反例搜索与 SMT 求解应设计成*可选后端*（存在即启用、缺失则降级为随机/启发式搜索 + Lean 内核检查），而不是插件启动的硬依赖；同理不要复用已归档的 SQLite 参考实现，需要本地结构化数据时直接给 DuckDB MCP 或自写只读封装。

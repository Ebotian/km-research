== 文献检索 API 与科研知识获取

本节回答：哪些开放接口可以支撑"猜想的文献定位、引用追踪、相关工作生成"，各自的免费额度、字段语义与合规边界是什么，以及 agent 应以什么工具签名访问它们。

*2026 年的关键变化*：OpenAlex 于 2026-02 改为按用量计费并要求 API key；Semantic Scholar 的未认证共享池实测极易返回 429。纯"免费无限调用"的时代已经结束，插件必须把配额核算、磁盘缓存与节流内建为工具契约，而不是寄望于提示词约束。

#table(columns: 4,
  [来源], [免费额度], [跨库主键], [数据许可],
  [arXiv], [1 请求 / 3 秒], [`arXiv id`], [元数据 CC0，正文非 CC0],
  [S2 Graph], [共享池 1000 RPS；key 1 RPS], [`CorpusId` 等 6 种], [API License Agreement],
  [OpenAlex], [\$1 / 天（按调用计费）], [`openalex_id` `doi` `pmid`], [数据 CC0],
  [Crossref], [3 请求 / 1 秒（polite pool）], [`DOI`], [元数据无所有权主张],
  [DBLP], [FAQ 未给出数值；站点已启用反爬], [`DBLP key`], [CC0],
  [zbMATH], [UNVERIFIED], [`Zbl id` + `MSC`], [受其 ToS 约束],
  [PubMed], [3 req/s；带 key 10 req/s], [`PMID`], [摘要可能受限],
)

=== arXiv：Atom API 是元数据主干，不是全文源

- 查询端点 `https://export.arxiv.org/api/query`，响应为 Atom 1.0（XML）。参数：`search_query`、`id_list`、`start`、`max_results`、`sortBy`（`relevance` / `lastUpdatedDate` / `submittedDate`）、`sortOrder`。#link("https://info.arxiv.org/help/api/user-manual.html")[arXiv API 手册]
- 字段前缀：`ti` `au` `abs` `co` `jr` `cat` `rn` `all`；操作符 `AND` `OR` `ANDNOT`；短语需 URL 转义为 `%22...%22`；日期过滤 `submittedDate:[202401010600+TO+202501010600]`（GMT，精确到分钟）。
- 分页硬限：单次 `max_results` 上限 2000，总量上限 30000；超过则返回 HTTP 400。单次命中超过 1000 条时应改写查询，而不是硬翻页。
- 速率：官方 ToU 明确要求"每 3 秒最多 1 个请求，且同时只允许一条连接"，并且这是*同一控制方名下所有机器合计*的上限，不允许靠加机器绕过。#link("https://info.arxiv.org/help/api/tou.html")[arXiv API 使用条款]
- 缓存是强制的：Atom 里的 `<updated>` 只在每日午夜随新论文刷新，同一天重复调用同一查询毫无收益，手册直接写 "Please cache your results"。
- *该 API 不含全文检索*，只有元数据字段。全文与源码另有通道：
  - `https://rss.arxiv.org/rss/cs.CC`（`cs.DM`、`math.CO` 同构；实测三者均返回 200 与 `application/rss+xml`），用于每日增量监控。
  - OAI-PMH（元数据批量）与 S3 requester-pays 桶 `arxiv`：PDF 与 TeX 源码，2025-04 全集约 9.2 TB，以约 100 GB / 月增长。#link("https://info.arxiv.org/help/bulk_data_s3.html")[arXiv Bulk Data via S3]
  - 单篇作者提交的 LaTeX 源码包可作结构化阅读，`arxiv-mcp-server` 走的正是这条路。
- *arXiv 不提供引用图*，只有描述性元数据；引用必须外接 Semantic Scholar 或 OpenAlex。

=== arxiv-mcp-server：现成的 MCP 形态参考

`blazickjp/arxiv-mcp-server`（PyPI `arxiv-mcp-server==0.7.2`，Apache-2.0，GitHub 约 3.1k stars）暴露 19 个工具，是最接近本项目需求的现成实现。#link("https://github.com/blazickjp/arxiv-mcp-server")[README]

- 读取模型（可直接照抄）：论文落盘到 `~/.arxiv-mcp-server/papers`；`download_paper` → `get_paper_outline` → `read_paper_section` 的"先大纲、后单节"读取；*每次工具调用默认上限 12,000 字符*，用返回的 `next_start` 续读；`get_paper_latex_section` 直接按节读作者提交的 LaTeX。
- 引用图是独立工具 `citation_graph`，后端 Semantic Scholar，*每篇论文 1 次调用并落盘缓存*，可用 `SEMANTIC_SCHOLAR_API_KEY` 提升稳定性。
- BibTeX 走 `export_citations`，来源明确写为 arXiv 元数据（"authoritative arXiv metadata"），而非第三方推断。
- 搜索默认 `max_results=5`，摘要默认截断到约 280 字符，`abstract_mode` 取 `snippet` / `full` / `none`；服务端自己实现 arXiv 的 3 秒节流，命中限速时等待约 60 秒。
- 安全态度值得抄：明确把论文正文与 LaTeX 当作*不可信外部内容*（提示注入面），建议对 shell / 文件 / 网络类工具保留人工审批。#link("https://github.com/blazickjp/arxiv-mcp-server/blob/main/SECURITY.md")[SECURITY.md]
- 可对照的同类项目（均为社区实现，非官方）：`openags/paper-search-mcp`（arXiv / PubMed / bioRxiv 多源聚合，GitHub 约 2.6k stars）、`zongmin-yu/semantic-scholar-fastmcp-mcp-server`（FastMCP + S2 全端点）。它们的共同短板是只做"搜索加摘要"，没有本节的配额核算与缓存层。

=== Semantic Scholar Graph API

- 基址 `https://api.semanticscholar.org/graph/v1`。
- 额度（一手）：未认证请求共享同一池，上限 1000 RPS，高峰期会被进一步限流；带 API key 为 1 RPS，可申请提高。官方推荐"每个请求都带 key"。#link("https://www.semanticscholar.org/product/api")[Semantic Scholar API]
- 语料规模（官方自述）：2.14 亿论文、24.9 亿引用、7900 万作者。
- 关键端点：
  - `GET /paper/{id}?fields=...`，`{id}` 支持 `DOI:` `ARXIV:` `CorpusId:` `DBLP:` `MAG:` `PMID:` 前缀。
  - `GET /paper/search?query=&limit=&offset=`（相关度排序）与 `GET /paper/search/bulk?query=&fields=&year=&token=`（token 游标分页，官方推荐批量场景）。bulk 的 query 语法支持 `|` `+` `-` 布尔、`"短语"`、前缀通配 `fish*`、编辑距离 `bugs~3`、邻近匹配。
  - `POST /paper/batch`、`POST /author/batch` 批量取详情，避免逐条往返。
  - `GET /paper/{id}/citations` 与 `GET /paper/{id}/references`：分别返回 `data[].citingPaper` 与 `data[].citedPaper`；可选字段 `contexts`（引用所在原句）、`intents`、`isInfluential`。#link("https://www.semanticscholar.org/product/api/tutorial")[S2 API Tutorial]
  - `POST /recommendations/v1/papers`，请求体 `positivePaperIds` / `negativePaperIds`，`limit` 上限 500。
  - Datasets API：`GET /datasets/v1/release/latest`（实测当前 `release_id` 为 `2026-09-09`），可下载全量 JSON 快照，并用 diffs 端点做增量更新。
- *去重利器*：`GET /paper/search/match?query=<论文标题>` 返回唯一最佳匹配并附 `matchScore`；实测对 "Attention is all you need" 直接给出 `CorpusId` 与 `DBLP` 键。
- `externalIds` 字段是跨库主键的枢纽：`DOI`、`ArXiv`、`DBLP`、`PubMed`、`CorpusId`、`MAG`。
- *没有 BibTeX 端点*：实测 `GET /paper/{id}/bibtex` 返回 404，BibTeX 必须自行从元数据生成。
- 许可：受 API License Agreement（2023-05-17 版）约束，key 不得转借他人。#link("https://www.semanticscholar.org/product/api/license")[API License Agreement]

=== OpenAlex：2026 起按用量计费，先算钱再发请求

- 2026-02-24 起*所有请求都需要 API key*（无 key 仅剩少量演示额度）；每个 key 每天 \$1 免费额度，超出需预付按量付费或购买年费计划。#link("https://blog.openalex.org/openalex-api-new-features-and-usage-based-pricing/")[OpenAlex 官方公告]
- 单价（每 1000 次调用）：按 ID / DOI 取单篇 \$0（无限）；list 与 filter \$0.10；search \$1.00；PDF 或 XML 下载 \$10.00。按每天 \$1 折算约等于：list/filter 10,000 次、search 1,000 次、全文下载 100 次。#link("https://help.openalex.org/access/pricing.md")[OpenAlex Pricing]
- 响应头实时反馈花费与余额，实测出现 `x-ratelimit-limit-usd`、`x-ratelimit-remaining-usd`、`x-ratelimit-cost-usd`、`x-ratelimit-credits-used`、`x-ratelimit-reset`。插件应在每次调用后读这些头做预算熔断。
- 查询面：`filter=` `search=` `sort=` `group_by=`；`search` 覆盖 works 的 title / abstract / fulltext，支持 `AND` `OR` `NOT` 与 `"短语"`，默认做词干还原与停用词剔除，`search.exact` 关闭词干，`search.semantic`（beta）走向量检索。请求 URL 硬限约 4094 字节，超长布尔查询需自行切块后在客户端合并。#link("https://help.openalex.org/api/searching.md")[OpenAlex Searching]
- 分页：`per_page` 默认 25、取值 1–100（`200` 已废弃）；基础分页最多取到 10,000 条，更深必须用 `cursor=*` 配合 `next_cursor`。#link("https://help.openalex.org/api/paging.md")[OpenAlex Paging]
- 数据本身为 *CC0*，官方原话是"released under a CC0 public-domain license with no 'personal use only' carve-out"，是所有来源里最宽松的一条，适合做本地镜像。#link("https://help.openalex.org/access/pricing.md")[OpenAlex Pricing]
- 引用图字段实测可用：`referenced_works`（出边，OpenAlex ID 列表）、`related_works`（算法推荐的相关论文，含"引用同一批文献"的邻居）、`cited_by_count`。全文方面官方托管数千万篇 OA works 的 PDF 与 TEI XML（公告称 6,000 万，定价页写 5,000 万以上），可先 `filter=...has_content.pdf:true` 再批量下载，按 \$0.01 / 次计费。

=== Crossref：DOI 元数据与 BibTeX 的标准出口

- 无 key、无注册；把联系方式放进 `mailto` 参数或 User-Agent 的 `mailto:`，就会被路由到 "polite pool" 专属机器池。#link("https://github.com/CrossRef/rest-api-doc")[Crossref REST API 文档]
- 实测 polite pool 限速头为 `x-rate-limit-limit: 3` 与 `x-rate-limit-interval: 1s`；官方声明限速会随时调整，客户端应读头自适应。深度分页用 `cursor`，`offset` 上限 10,000，`rows` 最大 1000。
- 检索字段：`query.bibliographic`（覆盖标题、作者、ISSN 与年份，最适合"用引文反查 DOI"）、`query.author`、`query.container-title`；`query.title` 已废弃。
- 过滤器对本项目很有用：`has-full-text:true`、`license.url:...`、`has-references:true`、`reference-visibility:open`、`type:proceedings-article`、`from-pub-date:`。
- *BibTeX 的正确路径是内容协商*：`https://api.crossref.org/works/{doi}/transform/application/x-bibtex`（实测直接返回 `@inproceedings{...}`）；对 `https://doi.org/{doi}` 发 `Accept: application/x-bibtex` 同样有效。注意直接请求 `https://api.crossref.org/works/{doi}` 并带该 Accept 头会返回 "No acceptable resource available"。
- 元数据版权："Crossref asserts no claims of ownership to individual items of bibliographic metadata"，明确允许缓存并并入自有系统。

=== DBLP / zbMATH Open / PubMed

- *DBLP*：三个只读接口 `https://dblp.org/search/{publ,author,venue}/api`，参数 `q`、`format`（`xml` / `json` / `jsonp`）、`h`（命中数，上限 1000，默认 30）、`f`（起始偏移）、`c`（补全词，上限 1000）。官方 FAQ 未给出数值速率上限，但站点已对非浏览器流量启用 Anubis 反爬（本次调研中 curl 与官方 FetchURL 均被拦截），因此*不应把 DBLP 当在线依赖*，改用其 XML / RDF 全量 dump 或 SPARQL 端点。全库元数据为 CC0。#link("https://web.archive.org/web/2025/https://dblp.org/faq/How+to+use+the+dblp+search+API.html")[DBLP Search API FAQ（存档）]
- *zbMATH Open*：REST API 基址 `https://api.zbmath.org/v1`，OpenAPI 规范版本 `1.9.28`（`https://api.zbmath.org/openapi.json`）。资源包括 `/document` `/author` `/serial` `/classification` `/software`，每种都有 `_search` 与 `_structured_search`；`/document/_search` 参数仅有 `search_string`、`page`、`results_per_page`。文档对象直接给出 `msc`（MSC2020 分类码）、`references`、`links`（DOI 等）与 `keywords`——这是把数学猜想锚定到标准学科码的最佳免费来源。使用前须接受其 Terms and Conditions。#link("https://api.zbmath.org/v1/document/_search")[zbMATH Open API]
- *PubMed E-utilities*：基址 `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/`，九个接口（`esearch` `efetch` `esummary` `elink` `epost` 等）。无 key 每 IP 3 请求 / 秒，带 key 默认 10 请求 / 秒；官方要求在 `tool` 与 `email` 参数中登记工具名与真实邮箱，并建议大批量任务放在周末或东部时间 21:00–05:00。批量场景应使用 History Server（`WebEnv` + `query_key`）而非逐条请求。注意 PubMed 摘要可能受版权保护。#link("https://www.ncbi.nlm.nih.gov/books/NBK25497/")[NCBI E-utilities]

=== 数学与理论计算机科学的专门来源

- *ECCC*（Electronic Colloquium on Computational Complexity）：复杂度理论的事实标准预印本库，1994 年至今，ISSN 1433-8092，编号形如 `TR26-178`。*没有官方 API*：`robots.txt` 明确 `Disallow: /search`；可用的是按年索引页 `https://eccc.weizmann.ac.il/year/2026/` 与单篇页 `https://eccc.weizmann.ac.il/report/2026/178/`（含标题、作者、日期、关键词、摘要与下载链接）。抓取只走这两类静态页并保持低频。#link("https://eccc.weizmann.ac.il/")[ECCC]
- *arXiv 分类*：`cs.CC`（计算复杂性）、`cs.DM`（离散数学）、`math.CO`（组合数学）是本项目主战场；三者的 RSS 实测可用，可低成本做每日增量。
- *会议论文库的开放程度差别很大*：
  - CCC / ITCS / STACS / APPROX-RANDOM 等由 Schloss Dagstuhl 的 *LIPIcs* 出版，完全开放获取（例：LIPIcs volume 300 即 "39th Computational Complexity Conference (CCC 2024)"）。#link("https://drops.dagstuhl.de/entities/volume/LIPIcs-volume-300")[DROPS: CCC 2024]
  - SODA（SIAM）、FOCS（IEEE）、STOC（ACM）正刊在付费墙后，DOI 可解析但全文不可免费获取。可行策略是"用 Crossref / DBLP 定位正刊记录，再用标题到 arXiv 与 ECCC 找预印本"；实测 STOC 的 DOI（如 `10.1145/3313276.3316366`）可被 Crossref 解析并直接产出 BibTeX。
  - 完全开放的理论期刊可作补充：*Theory of Computing*、Discrete Analysis、Electronic Journal of Combinatorics。#link("https://theoryofcomputing.org/")[Theory of Computing]

=== 去重、引用图与自动相关工作

- *主键优先，标题兜底*。推荐优先级：`DOI` → `arXiv id`（去掉版本后缀）→ `DBLP key` → `CorpusId` → `OpenAlex ID` → 归一化标题加年份。S2 的 `externalIds` 与 OpenAlex 的 `ids`（`doi` / `mag` / `pmid` / `openalex`，实测）都能一次性返回多个主键，是最省事的交叉映射层。
- 各家"按标题找主键"的能力按成本排序：S2 `paper/search/match`（返回 `matchScore`，最省事但共享池易 429）→ Crossref `query.bibliographic`（免费且稳定）→ OpenAlex `search=`（按次计费）→ DBLP（离线 dump）。
- *引用图三源互补*：S2 提供带上下文的有向边（`contexts` / `intents` / `isInfluential`）；OpenAlex 给出 `referenced_works` 集合与 `related_works` 推荐；Crossref 的 `has-references` 与 `reference-visibility` 用来判断哪些出版商的参考文献表是公开的。arXiv 本身没有引用数据。
- *自动生成相关工作的正确姿势*：不要用摘要向量相似度直接拼段落。应通过 S2 citations 的 `contexts` 抽出*他引原句*，让模型只做"组织与改写"，每条断言都挂一个可核对的原句与 `paperId`。产出的是可验证的综述草稿，而不是流畅的幻觉。
- 引用计数的口径必须显式标注来源：S2 的 `citationCount`、OpenAlex 的 `cited_by_count`、Crossref 的 `is-referenced-by-count` 三者互不相等（收录范围与去重规则不同），同一张表里混用会在答辩时被质疑。

=== 版权与合规边界：只走开放获取

- *可以放心做*：检索、存储、转换、共享 arXiv 的*描述性元数据*（CC0）；使用 zbMATH 与 DBLP 的元数据；缓存 OpenAlex 数据（CC0）；生成 BibTeX。
- *明确禁止*：把 arXiv 的 PDF 或源码转存到自有服务器对外提供（arXiv 不是版权方，且只有极少数投稿带允许再分发的许可）；绕过速率限制；使用他人凭据。合规做法是"存元数据加链接，按需拉取"。#link("https://info.arxiv.org/help/api/tou.html")[arXiv API ToU]
- 各源许可并不统一，插件中应逐源标注：arXiv 元数据 CC0 而正文非 CC0；OpenAlex CC0；DBLP CC0；Crossref 元数据无所有权主张；S2 受 API License Agreement 约束；zbMATH 受其 Terms and Conditions 约束；PubMed 摘要可能受版权保护。*UNVERIFIED*：zbMATH 数据再分发的具体许可条款未在本次调研中取得一手页面。
- 全文获取的合规梯度：优先用 `openAccessPdf` / `best_oa_location` 给出的开放链接；其次 arXiv 源码；OpenAlex 托管的 OA PDF 与 TEI 属付费服务，其文档强调"出售的是同步服务，不是文档"。拿到 PDF 绝不等于获得再分发权。

=== 给 agent 的工具接口建议

四个核心工具即可覆盖绝大多数场景；签名与返回值都应以"少而稳"为目标：

```json
{
  "search":        {"query": "str", "sources": ["arxiv","openalex","semantic_scholar","dblp"],
                    "year": "2020-", "categories": ["cs.CC"], "limit": 20,
                    "returns": "PaperRef[]"},
  "get_paper":     {"id": "doi|arxiv|dblp|corpusid", "include": ["abstract","bibtex","sections"],
                    "returns": "Paper"},
  "get_citations": {"id": "str", "direction": "citations|references|both",
                    "with_context": true, "limit": 50,
                    "returns": "Edge[]"},
  "get_bibtex":    {"ids": ["str"], "returns": "str"}
}
```

- *统一的内部 `PaperRef`*：`{doi, arxiv_id, dblp_key, corpus_id, openalex_id, title, authors, year, venue, msc}`。所有源在入口处归一到它，去重与引用图便退化为集合运算。
- *`get_bibtex` 的实现链*：Crossref 内容协商（有 DOI，最权威）→ 由 arXiv Atom 元数据自建（无 DOI 时的主力，`arxiv-mcp-server` 已验证可行）→ 由 S2 元数据自建（S2 无 BibTeX 端点）。三条路都失败时返回结构化错误，而不是编造条目。
- *配额核算必须是一等公民*：OpenAlex 读 `x-ratelimit-remaining-usd` 做熔断；S2 默认按 1 RPS 串行并对 429 指数退避；arXiv 硬性 3 秒串行；Crossref 与 DBLP 走低频。把"每源令牌桶 + 磁盘缓存 + 单张 SQLite 元数据表"放进 MCP server，而不是交给模型自觉。
- *返回裁剪*：单次工具调用返回上限建议 12,000 字符（直接沿用 `arxiv-mcp-server` 的默认值），大对象走"大纲 + 分段"两步；摘要默认给 `snippet`，仅在明确需要时给 `full`。这是长综述任务不爆上下文的关键机制。
- *可观测性*：每条记录都带 `source` 与 `retrieved_at`，生成的相关工作段落保留 `paperId` 或 `DOI` 与引用原句。缺了这两项，后续无法做事实核查。

=== 评估

- *该抄*：`arxiv-mcp-server` 的"元数据外链 + 正文落盘 + 默认 12k 字符分段 + `next_start` 续读"读取模型。它把上下文预算写成工具契约，而不是提示词里的一句祈使句。
- *该抄*：所有源统一归一到 `{doi, arxiv_id, dblp_key, corpus_id, openalex_id}` 的 `PaperRef`，并以 S2 `paper/search/match` 加 Crossref `query.bibliographic` 作为"标题到主键"的兜底。
- *该抄*：S2 引用边上的 `contexts` / `intents` / `isInfluential`。相关工作生成只允许基于被引原句，禁止模型自由发挥相似性判断。
- *该避免*：把 OpenAlex 当"免费无限"接口。2026-02 起它按次计费（search \$1 / 1000 次、全文 \$10 / 1000 次），必须在工具层做以美元计的熔断，否则一个失控的综述循环会真实产生费用。
- *该避免*：对 Semantic Scholar 未认证共享池做并发请求。实测连续调用即 429；正确做法是引导用户配置免费 API key，再按 1 RPS 串行。
- *该避免*：把任何来源的 PDF 缓存进插件目录并对外提供。设计上只持久化元数据与用户显式下载的单篇文件，PDF 一律通过官方链接按需获取。

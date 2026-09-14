== 开放问题与猜想的机器可读来源

下面所有事实均来自 2026-09-14 的只读抓取与探测（`FetchURL` / `curl` / 公开 API）。每条关键结论附带来源 URL；凡是本次未能一手核实的，显式标注 `UNVERIFIED`，不做猜测。

=== Formal Conjectures：目前唯一成规模的「形式化开放猜想」语料

一手来源为仓库 README、CONTRIBUTING、AGENTS、`lakefile.toml`、`lean-toolchain`、`scripts/extract_names.lean`，以及项目文档站。

- 定位：只收*陈述*不收证明，问题体几乎全是 `sorry`。目标之一是为自动定理证明器与自动形式化工具提供零污染基准 #link("https://github.com/google-deepmind/formal-conjectures")[README]。
- 论文口径（#link("https://arxiv.org/abs/2605.13171")[arXiv:2605.13171]，2026-05-13）：2615 条 Lean 4 问题语句，其中 1029 条开放猜想、836 条已解问题用于自动形式化评测。
- 当前口径（文档站「Browse by source」，2026-09-14 抓取，#link("https://google-deepmind.github.io/formal-conjectures/")[文档站]）：

  #table(columns: 3,
    [*来源目录*], [*文件数*], [*语句数*],
    [`ErdosProblems`], [671], [2064],
    [`OEIS`], [227], [1530],
    [`Wikipedia`], [147], [672],
    [`GreensOpenProblems`], [55], [241],
    [`Paper`], [30], [175],
    [`Arxiv`], [30], [147],
    [`WrittenOnTheWallII`], [49], [146],
    [`OpenQuantumProblems`], [3], [125],
    [`Mathoverflow`], [13], [65],
    [`Millenium`], [5], [33],
    [`Books`], [9], [32],
    [`Other`], [7], [30],
    [`HilbertProblems`], [2], [13],
    [`Kourovka`], [5], [5],
    [`OptimizationConstants`], [1], [5],
    [`LittProblems`], [1], [4],
  )

  按 AMS 主题分布：Number theory 3541 条、Combinatorics 1469 条，其后为凸与离散几何 176、量子理论 173、线性代数 163 —— 也就是说这份语料严重偏向数论/组合，与 Erdős 问题的分布一致。
- 工具链（实测文件）：`lean-toolchain` 为 `leanprover/lean4:v4.33.1`；`lakefile.toml` 依赖 mathlib `rev = "v4.33.1"`。构建流程为 `lake exe cache get` 然后 `lake build`；单文件构建用 `lake --wfail build 'FormalConjectures.ErdosProblems.«361»'`。
- 目录约定：`FormalConjectures/<Source>/` 一个来源一个目录、一个问题一个文件；可复用的数学放 `FormalConjecturesForMathlib/`，该目录不允许出现 `sorry` #link("https://raw.githubusercontent.com/google-deepmind/formal-conjectures/main/CONTRIBUTING.md")[CONTRIBUTING.md]。
- 四条机器可读属性：`@[category research open | research solved | textbook | API | test]`（每个语句恰一个）、`@[AMS n ...]`（MSC2020 主题，至少一个）、`@[formal_proof using <kind> at "url"]`（kind 取 `formal_conjectures` / `lean4` / `other_system`）、`answer(sorry)`（问题式陈述）。
- `answer()` 的语义陷阱（CONTRIBUTING 明写）：填进 `answer()` 的项再配一个证明，*并不*等于问题被解决；「答案是否数学上有意义」不在仓库职责内。→ 自动化流水线不能把 `answer()` 被填充当作已解决信号。
- 关键导出机制：默认 elaboration 下 `answer(sorry)` 会化简为 `True`，所以抽取 `answerKind` 前必须先 `lake build FormalConjecturesAnswerPostpone`（`weak.google.answer = "postpone"`），再运行 `lake exe extract_names [目录或文件] [--exclude=key1,key2] [--no-docstrings]`，即可导出定理名、语句、category、AMS 主题、`formal_proof` 链接与 answer 种类 #link("https://raw.githubusercontent.com/google-deepmind/formal-conjectures/main/scripts/extract_names.lean")[extract_names.lean]。这是插件接入该语料最直接的数据通道。
- 有限子问题与开放主问题的双层写法（下文 §有限搜索空间 会再用到）：
  ```lean
  @[category test, AMS 11]
  theorem maxSubsetSumAvoidingCard_three_four : maxSubsetSumAvoidingCard 3 4 = 2 := by
    native_decide

  @[category research open, AMS 11]
  theorem erdos_361 (c : ℝ) (hc : 0 < c) :
      subsetSumAvoidanceNumber c = answer(sorry) := by
    sorry
  ```
  #link("https://raw.githubusercontent.com/google-deepmind/formal-conjectures/main/FormalConjectures/ErdosProblems/361.lean")[Erdős 361]
- 仓库自带 linter 作为质量闸门（`lakefile.toml` 中按库启用）：`ams_attribute`、`category_attribute`、`category_answer`、`conditional_formal_proof`、`moduleDocstring`、`latex_docstring`、`imports`；CI 工作流为 `build-and-docs.yml`，文档站由 CI 自动生成。
- 贡献流程：签 Google CLA → 开 issue（或认领 `new conjecture` / `good first issue` 标签）→ fork → 在 `FormalConjectures/<Source>/` 放文件、必要时在 `FormalConjecturesForMathlib/` 放定义并登记到 `FormalConjecturesForMathlib.lean` → 检查外链 → `lake build` → 提 PR。标签可自助增删：单独一行评论 `+Easy` / `-WIP`。
- 版本纪律：仓库跟随 mathlib 月发布打 `v4.{X}.{Y}` 标签；基准快照形如 `bench-v{N}-lean4.{X}.{Y}`，且*不可变* —— 形式化错误只进 `v{N+1}`，不回溯修补旧快照。→ 插件应钉住快照 tag，不要追 `main`。
- 许可分层：软件 Apache-2.0，其余材料 CC-BY；但引用的 Wikipedia / MathOverflow / OEIS 素材是 CC-BY-SA 4.0，bbchallenge 素材 CC-BY 4.0，Equational Theories Project 为 Apache-2.0。再分发前需逐来源核对。

=== Erdős Problems：人工策展，无 API、无数据导出

- 当前状态（首页自报，2026-09-14）：数据库 1220 题，其中 586 题（48%）已解 #link("https://www.erdosproblems.com/")[erdosproblems.com]。同一天 Wikipedia 给出 ≥1220 题 / 634 未解，两者自洽。
- 站点由 Thomas Bloom 建立（2023 年起步，2024 年上线），FAQ 明确声明数据库*不保证*是最新状态，并给出原话警告：不要假定标为 unsolved 的题真的未解，投入前请自行查文献 #link("https://www.erdosproblems.com/faq")[FAQ]。
- 没有公开 API 或导出：实测 `/api`、`/download`、`/problems.json`、`/sitemap.xml` 全部 404。实际可访问的路由是 `/{id}`、`/lists`、`/definitions`、`/tags`、`/prizes`、`/forum/thread/blog:<n>`（`<n>` 取 1 到 7）。
- 抓取许可边界（`robots.txt`，Cloudflare 托管）：`Content-Signal: search=yes, ai-train=no, use=reference`，并显式 `Disallow` 了 `GPTBot`、`ClaudeBot`、`CCBot`、`Google-Extended`、`Amazonbot`、`Applebot-Extended`、`Bytespider`、`meta-externalagent` #link("https://www.erdosproblems.com/robots.txt")[robots.txt]。→ 插件若自动抓取并把正文喂给模型，这一步需要人工确认合规。
- AI 介入的关键节点（每条都给出一手或权威来源）：

  #table(columns: 3,
    [*时间*], [*事件*], [*来源*],
    [2025-10], [OpenAI 高管称 GPT-5 解决 10 道开放 Erdős 题；Bloom 称其为 "a dramatic misrepresentation"，实际是模型找到了文献中已被解决的引用], [#link("https://techcrunch.com/2025/10/19/openais-embarrassing-math/")[TechCrunch]],
    [2025-11], [Harmonic 的 Aristotle 解决了 Erdős 124 的一个简化变体], [#link("https://www.erdosproblems.com/forum/thread/blog:2")[Barreto 博客]],
    [2025-12-25], [Erdős 333 被宣布为「首个 LLM 自主解决」，数小时后被指出 Erdős 1977 年论文已给出解答，声明撤回], [同上],
    [2026-01-04], [Erdős 728 由 GPT-5.2 Pro 得到证明、Aristotle 形式化；随后 729、401、205 同法解决], [同上],
    [2026-01-29], [DeepMind 用 Gemini 系统评估 700 道标为 Open 的题，处理 13 道：5 道疑为自主新解、8 道是文献中已有解；结论是这些题「open 源于冷门而非困难」], [#link("https://arxiv.org/abs/2601.22401")[arXiv:2601.22401]],
    [2026-02-10], [DeepMind 发布 Aletheia 研究代理，含对上述 700 题的半自主评估], [#link("https://arxiv.org/abs/2602.10177")[arXiv:2602.10177]],
    [2026-05-20], [OpenAI 内部模型给出 Erdős 1946 年单位距离猜想的反例，人工数学家验证并写出精简版], [#link("https://openai.com/index/model-disproves-discrete-geometry-conjecture/")[OpenAI 公告]、#link("https://arxiv.org/abs/2605.20695")[arXiv:2605.20695]],
    [2026-06-08], [DeepMind 报告：最强 agent 自主解决 353 道开放 Erdős 题中的 9 道（每题数百美元），并证明 492 条 OEIS 猜想中的 44 条], [#link("https://arxiv.org/abs/2605.22763")[arXiv:2605.22763]],
    [2026-08-01], [OpenAI 未发布模型 Astra 报告 10 项数学进展，含 3 道 Erdős 题], [#link("https://www.quantamagazine.org/why-the-legendary-erdos-problems-are-falling-to-ai-20260803/")[Quanta]],
  )

- 主导失败模式是*文献查重*而非数学：上述 2025-10 的「10 题」实为文献检索；Barreto 的 481 与 333 均已发表；DeepMind 的 13 道里 8 道属文献误判。
- 一个已被复现的可信化工作流（Barreto 2026-01-26 博客）：先用「把它当作竞赛题、禁止联网」的提示绕过模型对开放问题的「拒绝作答」行为 → 得自然语言证明 → 交 autoformalizer（Aristotle）转 Lean → 反复迭代直至主定理形式化通过 → 人工核对主定理陈述是否真对应原题。作者明确表示：没有 Lean 形式化就不会把 AI 生成的证明发到站点上。
- 口径不一致警告：Aletheia 论文写「autonomous solutions to four open questions」，同一课题的案例研究 v3 写 5 条。引用时务必带 arXiv 版本号。

=== 其他清单：可及性差异极大

- *Wikipedia*：`List of unsolved problems in mathematics` 是导航型清单，含「问题数 / 未解数」表：Hilbert 23/13、Landau 4/4、Thurston 24/2、Smale 18/14、Millennium 7/6、Simon 15/12、Erdős ≥1220/634；正文还索引 Kourovka、Sverdlovsk、Dniester、Erlagol 等 notebook #link("https://en.wikipedia.org/wiki/List_of_unsolved_problems_in_mathematics")[Wikipedia]。许可 CC BY-SA 4.0；可经 MediaWiki API / Wikidata 结构化读取，但具体属性路径本次未核实 `UNVERIFIED`。
- *MacTutor*（圣安德鲁斯）：超过 3200 篇传记、2000 余篇文章，内容更新至 2026-07 #link("https://mathshistory.st-andrews.ac.uk/")[MacTutor]。它是数学史档案而非问题库，没有 API；Wikipedia 的引用把它的许可标为 CC BY-SA 4.0（站点许可本次未一手核实）。
- *Open Problem Garden*：2006–07 学年由 Matt DeVos 与 Robert Šámal 用 Drupal 搭建，站点自报的学科计数片段为 Algebra 298、Graph Theory 227、Combinatorics 35、Geometry 29、Analysis 5 #link("http://www.openproblemgarden.org/about")[OPG about]。无 API、无导出、规模远小于 formal-conjectures，只适合当人工线索。
- *UnsolvedMath*（`unsolvedmath.com`）：实测返回 Vercel 安全检查（HTTP 429），内容与许可均无法核实 `UNVERIFIED`。本阶段不建议纳入数据源。

=== OEIS：JSON 检索 + 全库文本下载

- 检索：在任意搜索 URL 后加 `&fmt=json`，返回一个 JSON *数组*（不是带计数的对象）。实测 #link("https://oeis.org/search?q=id:A000001&fmt=json")[/search?q=id:A000001&fmt=json] 返回单元素数组，观察到的字段有 `number`、`id`、`name`、`data`、`offset`、`keyword`、`author`、`comment`、`formula`、`link`、`xref`、`reference`、`program`、`maple`、`mathematica`、`created`、`time`、`revision`（列表字段为数组）。#link("https://oeis.org/wiki/JSON_Format")[官方 JSON 说明]
- 分页用 `&start=N`，默认每页 10 条（实测 `start=10` 返回下一批 10 条）。JSON 中没有总数，要总数只能读 HTML 结果页。
- 规模：首页自报 399,204 条序列（2026-09-14 抓取）；`names.gz` 文件头标注 `Last Modified: September 14 00:56 EDT 2026`，实测 399,639 行（含数行 `#` 注释行）。
- 全库下载：#link("https://oeis.org/wiki/Download")[Download 页] 给出的 `stripped.gz`（纯序列值，一行一条）与 `names.gz`（A 号 + 名称）实测均可下载；许可为 CC BY-SA 4.0，归因须写明 The OEIS Foundation 并给出 URL #link("https://oeis.org/wiki/The_OEIS_End-User_License_Agreement")[EULA]。
- 关键坑：*没有* `keyword:conj`。实测 `keyword:conj` 返回 0 条（提示 "the terms do not match anything"）；猜想的标记混在自由文本里，全文检索 `"Conjecture:"` 可用（实测命中 A002375 等），且部分条目的猜想状态写在评注中（如 A002372 注明弱形式已由 Helfgott 证明）。→ 想从 OEIS 抽猜想必须做文本解析，不能靠关键词过滤。
- 现成的粗粒度难度信号（关键词表，2026-04-08 修订）：`hard`（下一项未知且难求）、`more`（需要更多项）、`fini`/`full`（有限/完整序列，等价于搜索空间已封闭）、`easy`、`nice` #link("https://oeis.org/wiki/Keywords")[OEIS Keywords]。

=== LMFDB：API 存在但有反爬，规模极大

- 接口形态：`key=value` 查询串，值带类型前缀 `s:` / `i:` / `f:` / `ls:` / `li:` / `lf:` / `py:`，以及「包含于列表」的 `cs:` / `ci:` / `cf:`；元参数 `_format=html|json|yaml`、`_fields=a,b`、`_sort=name1,-name2`、`_delim`。官方示例：`?degree=i12&r2=i5&_format=json` #link("https://www.lmfdb.org/api/")[LMFDB API 索引]。
- 限额（官方文档）：单次请求最多 100 条，单次查询总量上限约 10000 条，超出需继续细化查询。
- 访问方式共五种：搜索结果页下载（限 100MB / 30 秒）、MCP server、API、命令行 CLI（需要 Sage，本机未安装）、只读 PostgreSQL 镜像（`devmirror.lmfdb.xyz:5432`，库名 / 用户名 / 口令均为 `lmfdb`）#link("https://www.lmfdb.org/api/options")[Access options]。全部数据 CC-BY-SA。
- 实测反爬：用 `curl` 直接请求 `https://www.lmfdb.org/api/` 与 `/api/options` 都被重定向到 Google reCAPTCHA 挑战页；只有经过渲染的抓取才拿到文档正文。→ 插件做 LMFDB 自动化查询时优先走 MCP server 或只读 SQL 镜像，不要指望裸 HTTP。（MCP server 的具体仓库地址本次未核实 `UNVERIFIED`。）
- 规模（API 索引页列出的表计数，节选）：

  #table(columns: 2,
    [*表*], [*行数*],
    [`char.dirichlet`], [562396733],
    [`gps.subgroup_data`], [275339797],
    [`lfunc.lfunctions`], [24201376],
    [`nf.fields`], [22444816],
    [`mf.twists_cc`], [49165089],
    [`gps.char`], [39901075],
    [`ec.curvedata`], [3824372],
    [`mf.newforms`], [1141510],
    [`lat.lattices`], [39293],
  )

=== 从猜想到「子猜想 → 有限搜索空间」

三条在本机工具链下可落地的范式，均由一手案例支撑。

*1. 有限实例判定（可判定化）。* FormalConjectures 的标准写法：主问题写成开放定理，有限特例写成 `@[category test]` 并用 `native_decide` 关闭（见上节 Erdős 361）。前置条件只是在 Lean 里给出 `Decidable` 实例；`Finset` 上的组合量通常能自动获得。这是成本最低的「把猜想变可计算」路径。

*2. 编码为 SAT/SMT 并产出可独立校验的证书。* 三条实测过的规模与验证成本：

  #table(columns: 4,
    [*问题*], [*结论*], [*计算 / 验证代价*], [*来源*],
    [Schur Number Five], [$n = 160$], [命题逻辑编码 + 大规模并行 SAT；证明 2 PB，经形式化验证的证明检查器认证], [#link("https://arxiv.org/abs/1711.08076")[arXiv:1711.08076]],
    [Boolean Pythagorean Triples], [不可二染色], [Cube-and-Conquer，800 核约 2 天；DRAT 证明约 200 TB，压缩证书 68 GB], [#link("https://arxiv.org/abs/1605.00723")[arXiv:1605.00723]],
    [Erdős Discrepancy，$C = 2$], [存在长度 1160 的序列；长度 1161 不存在], [布尔可满足性编码 + 当时最优 SAT 求解器], [#link("https://arxiv.org/abs/1402.2184")[arXiv:1402.2184]],
  )

*3. 停机问题化，用「忙碌海狸标尺」度量。* #link("https://bbchallenge.org/method")[Busy Beaver Challenge] 是目前工程化最好的模板：

- 结论 BB(5) = 47,176,870，搜索于 2024-07-02 完成。
- 两阶段设计：Phase 1 稀疏枚举（2021-12 完成，实际枚举 126,424,532 台机器，耗时 30 小时）产出 88,664,064 台未决机器的 seed database；Phase 2 由社区各自编写 decider 并附正确性证明。约化手段包括状态重命名与方向对称（各 24 与 2 种，合计 48 倍）。
- 数据格式：每台机器 30 字节，文件头含未决计数与字典序标志；zip 243 MB、解压约 2 GB，附 shasum。
- 实测 API：`GET https://api.bbchallenge.org/machine/<id>` 返回 `{"machine_code":"...","machine_id":12345678,"status":"decided"}`；`GET .../machine/<id>/decider` 返回决定它的 decider 标识。
- 难度标尺（站点整理，注意其中若干标注为未验证构造）：BB(15) 至少与「2 的幂的 3 进制表示含数字 2」的 Erdős 猜想同难；BB(27) 至少与 Goldbach 同难（未验证构造）；BB(744) 至少与黎曼假设同难（未发表）；BB(748) 独立于 ZF（未发表）；BB(5372) 至少与黎曼假设同难；BB(7910) 独立于 ZFC。

把上述范式抽象成插件应维护的字段（建议 schema，非官方）：

- `source_id`：如 `erdos:361`、`oeis:A002375`、`fc:Erdos361.erdos_361`。
- `formal_statement`：Lean 4 全限定名 + 快照 tag（形如 `bench-v{N}-lean4.4.33.1`）。
- `decidability`：`decidable-finite` / `decidable-parameterized` / `open-ended` / `undecidable-or-independent`。
- `search_space`：枚举基数与约化方式（如 bbchallenge 的 48 倍对称约化）。
- `known_bounds`：已知最优上界/下界及其形式（显式常数、渐近阶、具体反例）。
- `certificate`：可独立校验的产物（Lean 文件、DRAT / 压缩证书、seed DB 分片 + shasum）。
- `status_asof`：抓取日期 + 站点自报状态 —— 因为 erdosproblems.com 明确不保证最新。

=== 可自动化的难度分级

按「证据硬度」从高到低可自动化五档：

1. *可判定性与已知独立性。* 能给出显式 Turing 机编码的猜想可直接挂到忙碌海狸标尺上；`BB(748)` 独立于 ZF、`BB(7910)` 独立于 ZFC 这类结果意味着部分命题在给定公理系统内不可证，自动化系统应对这类问题拒绝「单调搜索」策略。注意这些具体数值来自 bbchallenge 的整理，其中若干署名为未发表工作。
2. *有限搜索空间是否封闭。* 可计算的等价信号：OEIS 的 `fini` / `full` 关键词、SAT 编码的变量与子句数、bbchallenge 的 seed 计数、FormalConjectures 中能用 `native_decide` 关闭的 `@[category test]` 语句。`Decidable` 实例 + `native_decide` 是最低成本的验证入口。
3. *已知反例/界的形式与幅度。* 有具体数值的界可自动比较：单位距离问题的 $delta = 0.014$（Sawin 的改进；OpenAI 原始证明未给显式 $delta$）、EDP $C = 2$ 的 1160、Schur 5 的 160。
4. *形式化就绪度。* `category`（open / solved / textbook / test）+ `AMS` + `formal_proof` 链接构成可直接计算的元数据；`answer(sorry)` 是否已填代表问题式陈述是否仍待定。
5. *成本与冷门度（最软）。* DeepMind 报告「每题数百美元」的 token 成本；Erdős 站点的奖金数额是 Erdős 本人对难度的主观标注（FAQ 说明奖金由 Combinatorics Foundation 发放，站点方不参与）；站点自报 48% 已解与 Wikipedia 的 634 未解提供分母。

明确不建议自动化、需要人把关的两件事：

- *新颖性判断与文献查重。* 2025-10 到 2026-01 的多次「AI 解决开放问题」误报，失败点全在文献检索而非数学。插件应把文献查重做成流程中的一等公民步骤，并要求每个结论附可比对的既有文献引用。
- *站点自报状态。* erdosproblems.com 的 FAQ 自己声明数据库不保证最新，其「open」只表示策展人不知道有解。

=== 评估

- *该抄 Formal Conjectures 的「属性即元数据」做法。* `@[category]` / `@[AMS]` / `@[formal_proof]` / `answer()` 四个属性足以让插件在不解析数学内容的前提下做筛选、分组与状态跟踪；插件应直接消费 `lake exe extract_names` 的 JSON 输出，而不是自己写 Lean 解析器——后者要处理 `answer(sorry)` 在默认 elaboration 下退化为 `True` 的坑，仓库已经提供了 `FormalConjecturesAnswerPostpone` 这一现成解法。
- *该抄 bbchallenge 的两阶段拆分与「机器可读 + 可校验」双输出。* Phase 1（廉价、可复现的枚举与约化）与 Phase 2（各自独立、需附正确性证明的 decider）分开，使得「搜索」与「判定」的信任边界清晰；每一层都同时给出二进制数据、校验和，以及（理想情况下）形式化证明。插件做反例搜索时应照着这个骨架拆分，并统一产出「结果 + 证书 + 校验和」三元组。
- *该抄 Busy Beaver 的难度分级思路，但只当作上界标尺。* 「把猜想编码成显式 Turing 机，用状态数当统一难度刻度」是可自动计算的，适合作为插件里最粗的一档排序信号；但该刻度对绝大多数有参数的猜想没有区分度（BB(5) 到 BB(15) 跨度已是天文数字），因此它只能用于「筛掉不可自动化的问题」，不能用于「排序可攻的问题」。
- *该避免把 OEIS 的关键词当作猜想过滤器。* `keyword:conj` 实测不存在，`hard` / `more` 只表示「下一项难求」，与「序列背后的命题是否开放」不是一回事。想从 OEIS 取猜想必须解析 `formula` / `comment` 文本（全文检索 `"Conjecture:"` 可用），并接受文本解析本身就是噪声源；正确的做法是把 OEIS 条目当线索，最终仍回到 formal-conjectures 的 `OEIS/` 目录取形式化陈述。
- *该避免在 erdosproblems.com 上做自动化抓取与状态判定。* 站点无 API、无导出、无 sitemap，`robots.txt` 的内容信号是 `ai-train=no, use=reference` 且显式屏蔽主流 AI 爬虫；更关键的是 FAQ 自己说明状态不保证最新——把它的「open」当作真值会让插件复现 2025-10 那次误报。插件应把该站当人工线索入口，状态以 formal-conjectures 的 `category` 与 `formal_proof` 链接为准。
- *该避免对 LMFDB 走裸 HTTP。* 实测 `curl` 直接请求 API 会撞上 reCAPTCHA 挑战页；官方提供的正规通道是 MCP server 与只读 PostgreSQL 镜像（`devmirror.lmfdb.xyz:5432`）。既然插件的形态本来就支持 `mcpServers`，应把 LMFDB 的 MCP server 作为默认接入方式，并把 SQL 镜像作为批量拉取的补充，而不是自己实现带重试的 JSON 抓取。

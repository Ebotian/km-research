= 风险与开放问题

== 环境风险与降级路径

下表每一条都来自本机实测，不是假设。

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*风险*], [*实测现状*], [*对策*]),
  [求解器缺失],
  [`z3`、`cvc5` 未安装；`python3` 无 `pip` 模块且有 `EXTERNALLY-MANAGED`],
  [能力探测 + 降级为穷举或启发式搜索，并*明确宣告不可解*。提示语二选一：`pacman -S` 或 `uv venv` 加 `uv pip install`],
  [CAS 重依赖],
  [`pacman -Sp sagemath` 需拉 112 个包共 460.2 MiB（其中 `gap` 单项 229 MiB）],
  [整类 CAS 能力标为可选重依赖，仅在探测到已安装时启用，不作为自动安装目标],
  [Lean 工具链],
  [elan 的 `stable` 指向未安装版本，裸 `lean` 触发联网下载],
  [调用前断言存在 `lean-toolchain`；必要时用 `~/.elan/toolchains/<tc>/bin/lean` 绝对路径绕过 shim],
  [内存与 CPU 无限制],
  [`ulimit -a` 的 cpu time 与 virtual memory 全为 `unlimited`；`/tmp` 是 16 GiB tmpfs],
  [默认走 `systemd-run --user --scope`；沙箱内挂独立 tmpfs，避免写 `/tmp` 吃内存],
  [磁盘配额不可用],
  [`Docker --storage-opt size=` 需 xfs 加 pquota，本机 overlay2 落在 ext4；`tune2fs` 普通用户无权限],
  [配额在应用层按目录累计字节数实现，并用 `RLIMIT_FSIZE` 兜底],
  [文献接口限流与计费],
  [OpenAlex 自 2026-02 起按次计费；Semantic Scholar 未认证共享池连续调用即 429],
  [工具层做以美元计的熔断；引导配置免费 API key 后按 1 RPS 串行],
  [来源站点反爬],
  [`erdosproblems.com` 无 API，`robots.txt` 显式屏蔽主流 AI 爬虫；LMFDB 裸 HTTP 请求会撞 reCAPTCHA],
  [不抓前者的状态；后者走官方 `MCP` 服务器或只读 `PostgreSQL` 镜像。状态一律以 `formal-conjectures` 的分类属性为准],
  [算力上限],
  [12 核 / 30 GiB；本地 loogle 建索引峰值约 13 GiB，会与 Mathlib 构建抢内存],
  [不做本地大模型与本地索引；671B 级 prover 走远端。复用已构建的 `.lake/packages/mathlib` 检出避免重复编译],
  [Typst 包漂移],
  [README 与包索引版本常不一致（`frame-it` 2.0.0 对 README 1.2.0）],
  [以 `packages.typst.org` 的索引为准，写死版本并 vendored 进插件目录，通过 `TYPST_PACKAGE_PATH` 以 `@local/<name>:<ver>` 导入],
  [hooks 不是安全边界],
  [hooks 为 fail-open：非零退出、超时、崩溃均放行],
  [只用于告警；真实约束写进权限规则的静态拒绝项],
)

== 方法论风险

环境风险可以靠工程解决，方法论风险只能靠纪律。

*形式化忠实度*是最根本的一个。语义正确率约 76% 意味着每四个形式化里可能有一个改变了原意，而编译率不会暴露这一点。对策是三重：形式化状态停在 `compiles`、忠实度检查清单进技能正文、人工闸门只设在「命题冻结」与「结论发布」两处。

*基准污染*是第二个。调研给出两条证据：FrontierMath 有 42% 的题目错误经修正，HLE 的错答率约 29% 与 18%。题目与验证器是会衰减的资产。对策是保留 `verifier_version` 与题目来源，题集修订后重算历史数字。

*评审不可靠*是第三个。LLM-as-judge 存在可被对手单靠调换顺序利用的位置偏差（arXiv:2305.17926），因此裁判只能用于筛选与升级，不能替代内核、复算脚本或署名评审人。

*自欺*是第四个，也是最难自动检测的。它不表现为错误结论，而表现为结论缺少必要的怀疑。对策写在第 6 章：验证器否决权、三态逻辑、空结果的独立退出码、以及禁止「工具不可用就估算」的 fallback。

== 待决问题

以下问题在设计阶段无法自行决定，需要在实施前确认。它们不影响 M0 到 M1 的开工。

#table(
  columns: (auto, 1fr),
  table.header([*问题*], [*说明*]),
  [`lab/` 的落点],
  [落在工作区便于与代码同仓、便于 `git` 追踪；落在 `KIMI_CODE_HOME` 便于跨项目复用台账。当前设计默认工作区，需要确认],
  [台账是否纳入版本控制],
  [`lab/conjectures/` 是文字记录，适合入 `git`；`lab/runs/` 含大产物，不适合。是否把二者拆到不同的根目录],
  [是否需要证书链],
  [当前只对单个证书做独立复核。是否要引入哈希链（每个结论指向其依赖的证书哈希）以获得更强的防篡改能力],
  [是否接入远端推理],
  [本机不做本地大模型。若要接入远端 prover（如 Goedel-Prover 类服务），需要决定是否把远端调用放进 `MCP`——这会破坏「`MCP` 不调用模型」的边界，需要重新论证],
  [多人协作],
  [当前设计是单用户本地。若需多人共享台账，`SQLite` 单文件与「一题一文件」的取舍需要重做],
)

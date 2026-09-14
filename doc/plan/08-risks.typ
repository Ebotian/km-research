= 风险与开放问题

== 环境风险与降级路径

下表每一条都来自本机实测，不是假设。

=== 本轮实测的环境基线

#table(
  columns: (auto, 1fr),
  table.header([*层*], [*实测可用*]),
  [必需], [`python3` 3.14.7、`typst` 0.15.1],
  [证明], [`drat-trim`、`lrat-check`（`decompress` 存在但功能异常）；经软链挂进 `plugin/bin/third-party/`，不依赖 `PATH`],
  [Lean], [Lean 4.33.1、Lake 5.0.0；`plugin/lean` 链到定点 toolchain `v4.33.0-rc1` 的项目，Mathlib 已构建],
  [SMT], [`z3` 4.16.0、`minisat`、`cryptominisat5`],
  [CAS], [`PARI/GP` 2.17.4、`fplll` 5.5.0],
  [基准], [`hyperfine` 1.20.0、`perf` 7.2.5、`cpupower` 7.2.5、`numactl` 2.0.19],
  [沙箱], [`bwrap` 0.12.0、Docker 29.8.0、systemd 261],
  [Python], [项目 venv（3.14.7）13 个模块全满足；系统 `python3` 只看得到 8 个],
  [仍缺], [`cadical`、`kissat`（官方源无，可由 PySAT 内建的 `CaDiCaL195` / `Glucose42` 顶上）；`cvc5` 作库可用但无命令行],
)

=== 降级与对策

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*风险*], [*实测现状*], [*对策*]),
  [求解器与库的可用性不一致],
  [`z3` 已装（pacman），`cvc5` / `ortools` / `python-sat` 只在 venv 里（PyPI），`cadical` / `kissat` 两边都没有],
  [能力探测同时覆盖*可执行文件与 Python 模块*，并按解释器分别探。库型后端（如 `cvc5`）只进模块层，不放进可执行文件层——否则会报 `not_found` 让消费者误判为不可用],
  [Python 依赖分裂],
  [曾出现系统 3.14 有 `z3`/`sympy`、另一 venv（基于 uv 下载的 3.12）有 `cvc5`/`ortools`，*没有任何单一解释器同时看得见两者*。这是最隐蔽的一类故障：每一侧单独看都正常],
  [venv 必须基于系统解释器（`home = /usr/bin`）才能让 `--system-site-packages` 指向 pacman 的 site-packages；`opl-capabilities` 新增 `split_brain` 字段，当某一层没有任何解释器能同时满足时报警并列出各缺什么],
  [CAS 重依赖],
  [`pacman -Sp sagemath` 需拉 112 个包共 460.2 MiB（其中 `gap` 单项 229 MiB）],
  [整类 CAS 能力标为可选重依赖，仅在探测到已安装时启用，不作为自动安装目标],
  [Lean 工具链未定点（已缓解，但引入外部依赖）],
  [elan 的 `default_toolchain = "stable"` 使每次 `lean` / `lake` 调用都要联网解析版本。实测在无 `lean-toolchain` 的目录里耗时 5.0 / 3.0 / 5.0 秒（两次撞上 5 秒预算）；同目录放入 `lean-toolchain` 后是 0.022 / 0.021 / 0.021 秒，用 `~/.elan/toolchains/<tc>/bin/` 绝对路径同样是 0.02 秒。*差 250 倍*，且哪一次超时纯看网络抖动],
  [已把 `plugin/lean` 链到一个定点 toolchain 的项目（`leanprover/lean4:v4.33.0-rc1`，Mathlib 已构建 8,279 个 `.olean`）。经软链 `lake --version` 为 0.021 秒，`import Mathlib` 编译项目外文件 2.18 秒。`opl-capabilities` 新增 `lean_project` 探测，报告 `pinned` / `pinned_fast`（超过 1 秒即说明仍在联网）与 Mathlib 是否已构建。*代价*：该项目已归档，它被删除或移动会让 Lean 层失效；超时只标「暂不可用」，绝不缓存为「不存在」],
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
  [`drat-trim` 编译不过],
  [`-std=c99` 置 `__STRICT_ANSI__`，glibc 隐藏 `getc_unlocked`；GCC 14 起隐式声明是硬错误],
  [加 `-D_DEFAULT_SOURCE`（保留 `-std=c99`）。注意 `FLAGS` 只被三个目标使用，`drat-trim` 与 `gapless` 的配方是硬编码的，只改 `FLAGS` 不够],
  [`decompress` 输出损坏],
  [上游 `decompress.c` 的 `read_lit` 内有一句遗留 `printf`，把每个原始字节混入 stdout。实测 7 行合法输入还原出 49 行垃圾（已核对上游 master，非本地改动）],
  [*包装，不 fork*。`opl-certcheck` 先验 LRAT 语法，不合法即判 `UNKNOWN`；`opl-capabilities` 用功能探测而非存在性探测把它标为 `broken`。另有一处较轻的缺陷：LRAT 删除行的索引取自未初始化变量，故 `decompress` 可用于验证链，*不可用于往返归档*],
  [`drat-trim` 覆盖面窄],
  [只验命题逻辑 CNF 上的 UNSAT。Z3/cvc5 在整数算术上给的 `unsat` 没有 DRAT 后端，区间算术与 Lean 也都另走各路],
  [把 SAT 层的 DRAT 定位为*可选的子集后端*，不是「证据分级的第三档」。UNSAT 结论若无法下推到 CNF，就停在 `empirical`，不得宣称 `exact_certificate`],
  [`cake_lpr` 用退出码撒谎],
  [它是 CakeML 编译、经形式化验证的 LPR 检查器，信任等级高于 `drat-trim`（后者是未经验证的 C 程序）。但*退出码恒为 0*：空证明、非法提示号、截断证明全都返回 0。判决只在文本里——通过时 stdout 出 `s VERIFIED UNSAT`，拒绝时 stdout 为空、stderr 出 `c Checking failed at line: N. Reason: ...`。若照搬 `drat-trim` 的「读退出码」写法，会把无效证明判成通过],
  [`opl-certcheck` 对 `lpr` 路径不读退出码：有 `s VERIFIED` 判通过，无判决行但有 `c ` 诊断判拒绝，两者皆无判 `UNKNOWN`（绝不猜）。拒绝原因写进证据记录的 `checker_messages`。这类「包装第三方工具时必须逐个确认其判决信道」是通用教训——退出码、stdout、stderr 三者谁说话，每个工具都要实测],
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
  [是否需要证书链],
  [当前只对单个证书做独立复核，证据记录带公式与证书的 SHA-256。是否要引入哈希链（每个结论指向其依赖的证书哈希）以获得更强的防篡改能力],
  [是否接入远端推理],
  [本机不做本地大模型。若要接入远端 prover（如 Goedel-Prover 类服务），需要决定放在哪一侧——放进可执行文件会破坏「工具链不调用大模型」的边界，需要重新论证],
  [多人协作],
  [当前设计是单用户本地，台账为「一题一文件」的纯文本。若需多人共享，要引入合并策略与冲突解决；`SQLite` 只作派生索引，不适合当共享真源],
  [`opl-capabilities` 的必需层边界],
  [当前必需层只含 `python3` 与 `typst`，证明层与求解器层均为可选。是否要把 `drat-trim` 提升为必需——取决于是否接受「UNSAT 结论在它缺失时只能停在 `empirical`」],
)

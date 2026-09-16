= 架构

*同步状态*（插件 `0.6.0`）：命令 12 个、技能 5 个，M0–M4 已交付并有回归覆盖（`scripts/regress.sh` 167 项全通过），M5（`opl-stat` + `opl-benchmark` 技能）与 M6（`opl-report`）未开始。命令数与原计划不同——原计划 13 个能力，实际 12 个且集合不同：多出实现期新增的 `opl-sign`，少了 `opl-stat` 与 `opl-report`。下文 `[已实现]` 与 `[未实现]` 即按此标注。

== 四个组件与一条边界

#table(
  columns: (auto, 1fr),
  table.header([*组件*], [*职责与边界*]),
  [`kimi.plugin.json`],
  [清单：显式列出技能目录、`sessionStart` 入口技能。选这个位置而非 `.kimi-plugin/plugin.json`，是因为调研确认前者优先，两者并存时后者被静默遮蔽，只在诊断里留一条 `shadowedManifestPath`],
  [`skills/<name>/SKILL.md`],
  [判据与流程。不写确定性逻辑，只写「何时触发、按什么判据判断、失败如何处置」；深材料放同级 `references/`，脚本放同级 `scripts/`],
  [`bin/opl-*`],
  [单一职责的可执行文件。判决走退出码，`stdout` 只出机器可解析内容。这是整个设计的事实中心],
  [`lab/`],
  [运行时数据，与插件代码分离。插件目录会被 `/plugins` 更新覆盖，实验数据不能被覆盖],
)

组件之间的核心边界有两条：*`bin/` 里不出现任何大模型调用*（变异算子留给宿主 agent，工具链只做确定性计算）；*技能里不出现确定性逻辑*（凡脚本能做的都下沉到 `bin/`）。第二条是 Unix 分工「机制与策略分离」的直接应用——技能是策略，可执行文件是机制。

实现落地后的分工与这张表一致，只是多了一层：`bin/` 下每个命令都是薄壳，确定性逻辑在 `lib/` 的共享模块里。

== 一次研究回合的时序

九步固定为命令序列，每步的判决都是退出码：

+ *能力探测*。`opl-capabilities` 落盘 `capabilities.json`。探测一律带超时，`decompress` 这类「存在但坏」的后端由功能探测而非存在性探测识别。
+ *台账登记*。`opl-conj add` 写入陈述、来源、可证伪性。
+ *形式化*。产出 Lean 陈述骨架与诊断，同时输出*忠实度检查清单*。形式化状态停在 `compiles`，除非人工确认。
+ *验证器就位*。在搜索之前确定「什么算解决」：Lean 内核接受、证书复核通过、或固定截断下的实测数字。
+ *编码*。`opl-encode` 把猜想与定义域转成 CNF 或 SMT-LIB。同一个猜想建议用两个后端各编码一遍，用不一致暴露编码错误。
+ *搜索*。`opl-search` 跑后端，产出见证或证明。三态由退出码承载。
+ *独立复核*。`opl-certcheck` 用与生成路径不同的代码复核证书。
+ *台账更新*。只有验证器通过才改状态；`opl-conj set` 无证据指针即拒绝写入。
+ *报告*。`opl-report` 从运行目录整篇重渲染 Typst。报告只读 `CSV` / `JSON` / `YAML`，不内嵌计算。`[未实现]`（M6）

前八步都已实现（`[已实现]`）。两处措辞要收紧：退出码只表达「这个命令完成了它那一步」，`0` 不等于「已被独立复核」——研究判决看结构化字段与档位（`verification_level`）；`4 MISSING` 也不只表示「后端不存在」，签名器缺席同样走这个码（见末节）。

== 进程模型与隔离

候选代码来自模型，必须按不可信代码处理。调研确认三套主流开源进化框架都假定候选代码是「合作者而非敌人」：OpenEvolve 在同进程内加载并执行候选代码，其默认配置自述内存与 CPU 限制「尚未实现」；ShinkaEvolve 的本地作业只是一条裸 `subprocess.Popen`。

改为小可执行文件后，隔离问题简化了一半：每个阶段本来就是独立进程，stdout 不会被 `JSON-RPC` 争用。剩下的问题只有「候选代码本身怎么跑」。

#table(
  columns: (auto, 1fr),
  table.header([*手段*], [*本机实测状态*]),
  [`bwrap`], [可用，非特权 user namespace。禁网、独立 PID/IPC/UTS、`--die-with-parent`、只读绑定系统库、`tmpfs` 写区],
  [`systemd-run --user --scope`], [可用且无需 root。一次给到 `MemoryHigh` / `MemoryMax` / `MemorySwapMax` / `CPUQuota` / `TasksMax` 与可寻址的 killswitch],
  [`Docker`], [29.7.2 存在。但 `--storage-opt size=` 在本机不可用（overlay2 落在 ext4，需 xfs 加 pquota），磁盘限额只能在应用层做],
  [`subprocess` + rlimit], [兜底路径。`ulimit -a` 显示 cpu time 与 virtual memory 全为 `unlimited`，必须显式设置],
  [`/tmp`], [16 GiB tmpfs。跑飞的代码写 `/tmp` 会直接吃内存，沙箱内应挂独立 `tmpfs`],
)

默认执行路径取 `systemd-run --user --scope`，`bwrap` 用于需要禁网与命名空间隔离的场景，`subprocess` + rlimit 作零依赖兜底。三条路径都不把 `RLIMIT_AS` 当唯一内存手段：内存压不住时它既不精确，又会误伤 BLAS 的地址预留。

长任务不用句柄轮询，用文件：以 `--detach` 启动，写 `runs/<id>/status.json`，用 `opl-run --wait` 轮询。这是 Unix 的既有做法，也让「超时重发」天然变成续跑而非重跑。`[已实现]`

== 目录布局

#table(
  columns: (auto, 1fr),
  table.header([*路径*], [*内容*]),
  [`kimi.plugin.json`], [清单：`skills` 数组、`sessionStart.skill`；插件版本的真源在此（`0.6.0`）。`[已实现]`],
  [`skills/<name>/SKILL.md`], [技能正文；深材料与脚本放同级 `references/`、`scripts/`。`[已实现]`：5 个技能目录，同级那两个目录目前为空],
  [`bin/opl-*`], [单一职责命令集，零第三方依赖（Python 标准库 + POSIX shell）。`[已实现]`：12 个命令；随包分发的校验器二进制（`drat-trim`、`lrat-check`、`cake_lpr` 等）另放 `bin/third-party/`，它们是外部工具而非 Python 依赖],
  [`lib/`], [共享契约与实现的所在地。`[已实现]`：12 个模块 5,743 行。`opl_common.py` 定退出码常量与流约定，命令本体是薄壳；其余按域切分（`opl_ledger` 台账、`opl_sign` 签名、`opl_evolve` 进化、`opl_run` 运行、`opl_sandbox` 沙箱、`opl_probe` 探测）],
  [`scripts/` 与 `hooks/`], [`[已实现]`：回归与打包脚本（`regress.sh` 167 项、`verify-zip.sh` 56 项）与一条 `pre-commit` 钩子。这两处是设计外新增的目录，不承担业务判断],
  [`tests/fixtures/`], [功能探测用的小样本（如 `tiny.clrat` 用于验证 `decompress` 是否可用）],
  [`lab/conjectures/<id>.json`], [猜想台账，一题一文件，记录内嵌 `signature`],
  [`lab/evidence/<id>.json`], [证据记录：后端、格式、SHA-256、解析完整性、耗时。路径由 `--evidence-out` 显式给出，一次写出、不许覆盖，并旁挂 `<path>.sig`],
  [`lab/runs/<run_id>/`], [实验快照：`cmd.json` / `env.json` / `capabilities.json` / `metrics.json`（`artifacts` 是 `metrics.json` 里的一个字段，指向产物）。默认位置是 `$OPL_LAB/runs`，未设 `OPL_LAB` 时是工作目录下的 `runs/`；进化实验的两阶段落在 `<lab>/evolve/runs/<hash16>/{extract,verify}/`],
  [`lab/programs/`], [原计划的程序库目录。`[已实现]`，但位置不同：库在实验目录里，是 `<lab>/evolve/programs.sqlite`（SQLite 派生索引而非真源），候选源码在 `<lab>/evolve/candidates/`],
  [`lab/report/`], [Typst 报告模板与产物。`[未实现]`（M6）],
)

`lab/` 默认落在工作区，可用环境变量 `OPL_LAB` 指向别处。台账与证据是纯文本、一记录一文件，因此可以直接进版本控制、可以 `diff`、可以被 `grep` 与 `jq` 消费——这也是把「台账要不要入 git」这个待决问题解掉的答案：文字证据入 git，大产物（`lab/runs/`）不入。

== 实现期补上的边界

有几条边界是原设计没想到、而实现必须有的。它们不是新想法，是上面两条边界在「证据要经得起复核」这一点上继续往前推的结果。

*签名层*。哈希是自证的：一份手写的 `verdict` 加一个算得出来的 `sha256` 就自洽，复核者看到的只是文件里的一行字。所以证据与台账记录要签名，用的是系统自带的 OpenSSH（`ssh-keygen -Y sign` / `-Y verify`，SSHSIG 格式，命名空间 `open-problem-lab`），不引入第二套密钥体系。两种形态对应两种提交方式：

- *台账记录内嵌签名*。记录 JSON 顶层多一个 `signature` 字段，签的是去掉它之后的规范序列化。于是「写入 + 签名」是一次提交：先算出签名、写 `.tmp`、在暂存处自验通过，再 `os.replace` 换过去。签名核不过的中间态不存在——正式路径上要么是旧记录，要么是验得过的完整新记录。
- *证据旁挂签名*。`<path>.sig` 由产出证据的那条命令一次写出（`opl-certcheck`、`opl-encode --eval-witness`、`opl-leancheck`）。找不到 `ssh-keygen`、或本机没有密钥时，它*不产出无签名的证据*：把刚写下的那份删掉，以 `4` 退出——与「找不到 `bwrap` 就不降级到裸跑」是同一条纪律。台账写入同样如此：没有可用的签名器就拒绝写。

*信任边界要说清*。密钥在本机 `~/.config/open-problem-lab/ledger_ed25519`（`OPL_SIGNING_KEY` 可覆盖），沙箱只挂显式列出的文件，因此候选代码看不到它；但*同一用户下有 shell 的进程仍能读密钥、照样签*。所以它降的是自欺的概率，不是把记录变成不可伪造。

*台账的事务式校验*。改动先全部应用到记录的副本，再校验*改完的整条记录*——结论与证据种类/判决是否相称、对象与范围、档位、被盖章的反例；不自洽就整笔拒绝，一个字段都不写。为什么看整条而不是那个字段：一条记录的各字段互为前提，「改完仍自洽」只有整条才判得出来。

*评估器的退出码契约*。评估器自己的退出码另有约定：`0` 跑完（可行性看实验定义里的字段）、`1` 按约定表示不可行（这是结论）、`2` 拒收这个候选、`3` 及以上视为它自身故障——此时它写下的指标一概不采信。退出码与指标互相矛盾时不下判决，返回 `UNKNOWN`（标签 `verdict_conflict`）：两份原始信息都留着，不挑一个当依据。判决只有一处实现，`init` 与 `eval` 共用同一份。

*建实验的事务*。`opl-evolve-init` 先在 sibling 暂存目录 `.evolve-new-<ts>` 里把整个新实验建完（含基线评估与程序库），再整体切换；旧实验整体归档到 `<lab>/.evolve-bak-<ts>`，提交之后不再写任何东西。为什么是整个目录而不是逐份文件替换：分批换的中间态是「新骨架配旧库」，而那种错配不报错，只会让成绩与产生它的代码对不上。

*成绩带着它的来源*。运行史里的 `run_dir` 相对实验目录存、读出时再解析成绝对路径，归档之后索引跟着归档走，不会指回活实验；`programs` 多一列 `metrics_evaluation_id`，记的是*当前头条指标是哪一次运行跑出来的*——失败运行（超时、评估器崩了）只追加历史，不动归属。来源说不清的成绩被排除在比较之外并单独报出，而不是拿别的运行的指纹顶上。

*证据不许覆盖*。`--evidence-out` 指向已存在的路径（或它的 `.sig`）时以 `2` 拒绝。理由不是洁癖：产出流程是「先写正式文件、再签名」，而签名失败会删掉刚写的那份，于是同一路径写第二次、签名器恰好不可用，就会把先前那份有效证据连同签名一起抹掉；更根本的是台账按哈希引用证据，换掉同一路径上的内容会让引用它的记录当场核不过。

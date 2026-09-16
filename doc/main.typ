#import "template.typ": opl-conf

#show: opl-conf.with(
  title: [open-problem-lab],
  subtitle: [本地 Kimi Code 插件设计方案 —— 开放问题算法研究],
  authors: ((name: "EBT", affiliation: "本地工作区 km-research"),),
  date: [2026-09-16],
  version: [设计 v0.1 ｜ 实装 0.6.0],
  abstract: [
    本文件第一部分给出插件的设计方案（架构、工具链、技能集、数据模型、验证纪律、路线图与风险），
    第二部分是支撑这些决策的 24 篇专题网络调研。

    设计围绕一个判断展开：这类工具的主要失效模式不是算不出来，而是*把没做成的事说成做成了*。
    因此插件的第一等公民不是搜索算法，而是验证器与证据等级——所有结论必须携带可复核的依据，
    求解器的 `unknown` 绝不能折叠成「已证」，缺失的验证器必须触发硬失败而不是回退到估算。

    方案按 M0 到 M6 七个里程碑推进，每个里程碑都有可执行的验收标准。
    各章保留了写下时的计划口径，并在章首或章末标注*同步状态*（截至插件 0.6.0）：
    M0–M4 已交付并有回归覆盖，M5（`opl-stat` + `opl-benchmark`）与 M6（`opl-report`）尚未开始；
    命令 12 个、技能 5 个，与原计划的 13 个 / 7 个差在「多出签名层 `opl-sign`，少了统计与报告」。
    所有环境相关的结论均来自本机实测，实测状态与降级路径集中在风险章。
  ],
)

#include "plan/01-overview.typ"
#include "plan/02-architecture.typ"
#include "plan/03-toolchain.typ"
#include "plan/04-skills.typ"
#include "plan/05-data-model.typ"
#include "plan/06-verification.typ"
#include "plan/07-roadmap.typ"
#include "plan/08-risks.typ"

= 调研附录

#v(-0.4em)

#text(size: 10pt, fill: luma(90))[
  以下六章是支撑前面方案决策的 24 个专题网络调研。每篇以「评估」小节收尾，
  列出本项目该抄什么、该避开什么。文中 `UNVERIFIED` 标记表示该结论未能核实。
]

#heading(level: 1)[附录 A：平台与插件形态]

#include "sections/01-kimi-plugin-spec.typ"
#include "sections/02-kimi-extension-points.typ"
#include "sections/03-claude-plugin-prior-art.typ"
#include "sections/04-mcp-server-design.typ"

#heading(level: 1)[附录 B：AI for Math 与开放问题来源]

#include "sections/05-deepmind-ai-for-math.typ"
#include "sections/06-ai-scientist-pipelines.typ"
#include "sections/07-lean-autoformalization.typ"
#include "sections/08-open-problem-sources.typ"

#heading(level: 1)[附录 C：求解与验证引擎]

#include "sections/09-smt-sat.typ"
#include "sections/10-cp-optimization.typ"
#include "sections/11-computer-algebra.typ"
#include "sections/12-rigorous-numerics.typ"

#heading(level: 1)[附录 D：算法实验方法学]

#include "sections/13-algorithm-config-benchmarking.typ"
#include "sections/14-runtime-distributions.typ"
#include "sections/15-llm-program-search.typ"

#heading(level: 1)[附录 E：科研基础设施]

#include "sections/16-literature-apis.typ"
#include "sections/17-reproducibility.typ"
#include "sections/18-conjecture-mgmt-notebooks.typ"
#include "sections/19-typst-for-research.typ"

#heading(level: 1)[附录 F：评估、案例与生态]

#include "sections/20-hitl-verification-gates.typ"
#include "sections/21-eval-methodology.typ"
#include "sections/22-ai-open-problem-successes.typ"
#include "sections/23-science-plugin-marketplaces.typ"
#include "sections/24-local-toolchain-provisioning.typ"

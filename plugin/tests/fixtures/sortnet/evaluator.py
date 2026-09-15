#!/usr/bin/env python3
"""0-1 原理评估器（**两阶段协议**）：候选进程只产出数据，判定在另一个进程里做。

    evaluator.py extract --problem P.json --candidate C.py --artifacts DIR
        ↑ 候选的代码在这里跑。**只产出普通数据，不产出判决。**
    evaluator.py verify  --problem P.json --artifacts DIR --metrics-out M.json
        ↑ **没有候选**。读 DIR 里的数据，独立枚举，写指标。

== 为什么要拆成两个进程 ==

实测（审阅稿第二轮）：候选在可进化区里放

    import itertools
    itertools.product = lambda *a, **k: [(0, 0, 0, 0)]

就能把**评估器进程内**的枚举器换掉。区外文本一字未改、冻结的题目参数也没变，
于是评估器只查一个全零输入就报 `sorts=true, comparators=0,
zero_one_inputs_checked=1`，插件给它退出码 0。

只读挂载挡不住这个——它保护的是**文件**，而候选改的是**进程内存**。所以边界只能画在
进程上：候选能碰到的只有 extract 那一侧；`verify` 是另一个进程，它读的是普通数据
（JSON），并且**自己独立枚举**。

== 两阶段的返回码约定（插件据此判定）==

    extract: 0 数据已产出 / 2 候选不可用（加载不了）/ 3+ 自身故障
    verify:  0 判定可行 / 1 判定不可行 / 2 数据不合规 / 3+ 自身故障

extract **不做**判断（除了「能不能加载」）。题目参数是否与冻结值一致、比较器是否越界、
网络是否真的排序——全都在 verify 里判。判断只有一处实现，也就只有一处可能出错。
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import sys

METRICS_SCHEMA = "opl.evolve.metrics/1"
ARTIFACT = "network.json"


def load_problem(path: str) -> dict:
    """读冻结的实验定义。缺 `params.n` 就报错——**不取默认值**。"""
    with open(path, encoding="utf-8") as fh:
        prob = json.load(fh)
    if not isinstance(prob, dict) or "n" not in (prob.get("params") or {}):
        raise ValueError(f"实验定义缺 params.n：{path}")
    return prob


# ------------------------------------------------------------------ extract 侧


def cmd_extract(args) -> int:
    """跑候选，**只把它的产物写成数据**。不判断，除了「能不能加载」。"""
    if not os.path.isfile(args.candidate):
        print(f"候选不存在：{args.candidate}", file=sys.stderr)
        return 2
    try:
        ns: dict = {"__file__": args.candidate, "__name__": "opl_candidate"}
        with open(args.candidate, encoding="utf-8") as fh:
            src = fh.read()
        exec(compile(src, args.candidate, "exec"), ns)  # noqa: S102
        n_declared = int(ns["N"])
        network = ns["build_network"]()
    except (KeyError, TypeError, ValueError, SyntaxError, OSError) as exc:
        print(f"候选不可用：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    os.makedirs(args.artifacts, exist_ok=True)
    # 存成**数据**，不存对象：verify 只读这个 JSON，不 import 任何候选代码。
    # 连构造不出合法形状也照实存下去，让 verify 去判「数据不合规」——
    # 判断集中在一处，不在两处各判一半。
    payload = {"schema": "opl.evolve.artifact/1", "n_declared": n_declared,
               "network": [list(x) if isinstance(x, (list, tuple)) else x
                           for x in (network if isinstance(network, (list, tuple)) else [])],
               "network_was_sequence": isinstance(network, (list, tuple))}
    with open(os.path.join(args.artifacts, ARTIFACT), "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    print(json.dumps({"artifact": ARTIFACT, "n_declared": n_declared,
                      "comparators_declared": len(payload["network"])}))
    return 0


# ------------------------------------------------------------------ verify 侧


def validate(network: object, n: int) -> list[tuple[int, int]]:
    """比较器表是否合法。**数据不合规就拒，不当成「排序失败」。**"""
    if not isinstance(network, (list, tuple)):
        raise ValueError(f"network 应为序列，实为 {type(network).__name__}")
    out: list[tuple[int, int]] = []
    for k, item in enumerate(network):
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            raise ValueError(f"第 {k} 个比较器不是 (i, j) 对：{item!r}")
        if isinstance(item[0], bool) or isinstance(item[1], bool):
            raise ValueError(f"第 {k} 个比较器的下标是布尔：{item!r}")
        i, j = int(item[0]), int(item[1])
        if not (0 <= i < n and 0 <= j < n):
            raise ValueError(f"第 {k} 个比较器越界：({i}, {j}) 不在 [0, {n})")
        if i == j:
            raise ValueError(f"第 {k} 个比较器自比：({i}, {j})")
        out.append((i, j))
    return out


def apply_network(net: list[tuple[int, int]], seq: tuple[int, ...]) -> list[int]:
    a = list(seq)
    for i, j in net:
        if a[i] > a[j]:
            a[i], a[j] = a[j], a[i]
    return a


def cmd_verify(args) -> int:
    """**没有候选**：读数据、独立枚举、写指标。所有判断都在这里。"""
    ap = args
    try:
        problem = load_problem(ap.problem)
        n_frozen = int(problem.get("params", {}).get("n"))
    except (OSError, ValueError, TypeError) as exc:
        print(f"实验定义不可用：{exc}", file=sys.stderr)
        return 2
    path = os.path.join(ap.artifacts, ARTIFACT)
    if not os.path.isfile(path):
        print(f"缺产物：{path}", file=sys.stderr)
        return 2
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"产物不是合法 JSON：{exc}", file=sys.stderr)
        return 2
    if not isinstance(data, dict) or data.get("schema") != "opl.evolve.artifact/1":
        print(f"产物的 schema 不是 opl.evolve.artifact/1：{data!r:.80}", file=sys.stderr)
        return 2
    # 题目参数由**冻结定义**给出，候选声明的值必须与之一致
    n_declared = data.get("n_declared")
    if isinstance(n_declared, bool) or not isinstance(n_declared, int):
        print(f"n_declared 不是整数：{n_declared!r}", file=sys.stderr)
        return 2
    if n_declared != n_frozen:
        print(f"候选声明的 N={n_declared} 与冻结定义的 n={n_frozen} 不一致："
              f"题目参数不许由候选改动", file=sys.stderr)
        return 2
    try:
        net = validate(data.get("network"), n_frozen)
    except (ValueError, TypeError) as exc:
        print(f"候选产物不合规：{exc}", file=sys.stderr)
        return 2

    checked = 0
    first_bad: list[int] | None = None
    for bits in itertools.product((0, 1), repeat=n_frozen):
        checked += 1
        if apply_network(net, bits) != sorted(bits):
            if first_bad is None:
                first_bad = list(bits)
    rec = {
        "schema": METRICS_SCHEMA,
        "candidate": data.get("candidate_hint"),
        "n": n_frozen,
        "n_frozen": n_frozen,
        "n_declared": n_declared,
        "sorts": first_bad is None,
        "comparators": len(net),
        "zero_one_inputs_checked": checked,
        "first_counterexample": first_bad,
    }
    if ap.metrics_out:
        with open(ap.metrics_out, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
    print(json.dumps(rec, ensure_ascii=False))
    return 0 if rec["sorts"] else 1


# ------------------------------------------------------------------ 入口


def main() -> int:
    ap = argparse.ArgumentParser(description="两阶段评估器：extract 产出数据，verify 判定")
    sub = ap.add_subparsers(dest="stage", required=True)
    e = sub.add_parser("extract", help="跑候选，把产物写成数据（不做判断）")
    e.add_argument("--problem", required=True)
    e.add_argument("--candidate", required=True)
    e.add_argument("--artifacts", required=True)
    e.set_defaults(func=cmd_extract)
    v = sub.add_parser("verify", help="读数据、独立判定、写指标（没有候选）")
    v.add_argument("--problem", required=True)
    v.add_argument("--artifacts", required=True)
    v.add_argument("--metrics-out")
    v.set_defaults(func=cmd_verify)
    args = ap.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())

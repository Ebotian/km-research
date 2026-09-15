#!/usr/bin/env python3
"""0-1 原理评估器：判定一个比较器网络是否真的排序，并数比较器个数。

用法：
    evaluator.py --candidate CAND.py --problem P.json [--metrics-out P.json]

候选契约：文件里要有 `N`（整数）与 `build_network()`，后者返回 `(i, j)` 序列。
**`N` 必须等于冻结定义里的 `params.n`**——题目参数由 `--problem` 给出，不由候选说了算。
理由（实测）：把 `N = 0` 放进可进化区重新绑定，就能让评估器看到一个零路问题并报
`sorts=true, comparators=0`，而区外文本一字未改。**区外不变不代表题目不变。**

评估器 `exec` 候选文件、调用 `build_network`，然后：

* **0-1 原理**：网络能排序所有输入 ⟺ 它能排序所有 `2^n` 个 0-1 序列。
  所以只枚举 2^n 个序列就够，n=4 是 16 个——这是**判定**，不是抽样。
* 记录**实际检查了多少个输入**，以及第一个反例。只说一句 `sorts: false` 是没用的：
  要能回答「你怎么知道」。

退出码：0 = 排序成立；1 = 被推翻（有反例）；2 = 用法/候选本身有问题。

这是一个**夹具**（玩具问题的评估器），不是插件的一部分——但它遵守同一套纪律：
判决要有证据、不确定要说出来。
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import sys


def load_problem(path: str) -> dict:
    """读冻结的实验定义。缺 `params.n` 就报错——**不取默认值**，默认值会让定义悄悄变松。"""
    with open(path, encoding="utf-8") as fh:
        prob = json.load(fh)
    if not isinstance(prob, dict) or "n" not in (prob.get("params") or {}):
        raise ValueError(f"实验定义缺 params.n：{path}")
    return prob


def load_candidate(path: str) -> tuple[int, object]:
    """执行候选文件，取回 (N, build_network)。"""
    ns: dict = {"__file__": path, "__name__": "opl_candidate"}
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    code = compile(src, path, "exec")
    exec(code, ns)  # noqa: S102 —— 候选就是代码，评估它的方式就是执行它
    if "N" not in ns or "build_network" not in ns:
        raise ValueError("候选必须同时定义 N 与 build_network()")
    return int(ns["N"]), ns["build_network"]


def validate(network: object, n: int) -> list[tuple[int, int]]:
    """比较器表本身是否合法。不合法就**报用法错**，不当成「排序失败」。"""
    if not isinstance(network, (list, tuple)):
        raise ValueError(f"build_network() 应返回序列，实为 {type(network).__name__}")
    out: list[tuple[int, int]] = []
    for k, item in enumerate(network):
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            raise ValueError(f"第 {k} 个比较器不是 (i, j) 对：{item!r}")
        i, j = int(item[0]), int(item[1])
        if not (0 <= i < n and 0 <= j < n):
            raise ValueError(f"第 {k} 个比较器越界：({i}, {j}) 不在 [0, {n})")
        if i == j:
            raise ValueError(f"第 {k} 个比较器自比：({i}, {j})")
        out.append((i, j))
    return out


def apply_network(net: list[tuple[int, int]], seq: list[int]) -> list[int]:
    a = list(seq)
    for i, j in net:
        if a[i] > a[j]:
            a[i], a[j] = a[j], a[i]
    return a


def evaluate(net: list[tuple[int, int]], n: int) -> dict:
    """按 0-1 原理判定。返回的可检查事实：查了几个、第一个反例是谁。"""
    checked = 0
    first_bad: list[int] | None = None
    for bits in itertools.product((0, 1), repeat=n):
        checked += 1
        got = apply_network(net, list(bits))
        if got != sorted(bits):
            if first_bad is None:
                first_bad = list(bits)
    return {
        "sorts": first_bad is None,
        "comparators": len(net),
        "zero_one_inputs_checked": checked,
        "first_counterexample": first_bad,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--problem", required=True,
                    help="冻结的实验定义（只读挂入）；题目参数以它为准")
    ap.add_argument("--metrics-out")
    ap.add_argument("--n", type=int, default=None,
                    help="覆盖冻结定义里的 n（诊断用；正式评估不要传）")
    args = ap.parse_args()

    if not os.path.isfile(args.candidate):
        print(f"候选不存在：{args.candidate}", file=sys.stderr)
        return 2
    try:
        problem = load_problem(args.problem)
        n_frozen = int(problem.get("params", {}).get("n"))
        n_declared, builder = load_candidate(args.candidate)
        n = args.n or n_frozen
        if args.n is None and n_declared != n_frozen:
            # 候选改了题目参数 → 直接拒，**不要**用冻结值替它算一遍再报「通过」
            print(f"候选声明的 N={n_declared} 与冻结定义的 n={n_frozen} 不一致："
                  f"题目参数不许由候选改动", file=sys.stderr)
            return 2
        net = validate(builder(), n)
    except (ValueError, SyntaxError, TypeError, OSError) as exc:
        # 候选**本身有问题**与「候选排序失败」是两件事，退出码必须分开。
        print(f"候选不可用：{exc}", file=sys.stderr)
        return 2

    res = evaluate(net, n)
    rec = {
        "schema": "opl.evolve.metrics/1",
        "candidate": os.path.abspath(args.candidate),
        "n": n,
        "n_frozen": n_frozen,
        "n_declared": n_declared,
        **res,
    }
    if args.metrics_out:
        with open(args.metrics_out, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
    print(json.dumps(rec, ensure_ascii=False))
    return 0 if res["sorts"] else 1


if __name__ == "__main__":
    sys.exit(main())

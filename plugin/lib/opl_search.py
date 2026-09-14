"""opl_search —— 在编码上跑搜索，产出见证或证明。

判决走退出码（见 `opl_common` 的契约）。本模块只负责「跑」与「自检」，不做 I/O。

三条来自实测的硬约束：

* 出 DRAT 必须用 Glucose42 或 Lingeling。`Cadical195` 在 PySAT 里
  `with_proof=True` 时*静默返回空证明*（连鸽笼实例都是空），那比报错危险——
  下游会把「没有证明」当成「证明为空子句」。`Kissat404` 与 `Minisat22` 直接
  抛 `NotImplementedError`。

* 超时只能靠*墙钟 + 子进程*。实测 PySAT 的 `conf_budget` / `prop_budget` 在本机
  对 Glucose42 完全无效：把它们设成 0，PC(4,3)/PC(6,5)/PC(9,8) 仍照常解完并
  返回 False，耗时与无预算时一模一样。所以预算不能当「必然超时」的机制。

* SAT 结论必须用*规格的直接求值*复核一遍。求解器说 sat，不等于它给的赋值满足
  规格——中间隔着编码与反解码两道翻译，任一处出错都会得到「看起来是反例，其实
  不是」的东西。这是与编码器无关的第三条路径。
"""

from __future__ import annotations

import multiprocessing
import time
from dataclasses import dataclass, field

from opl_encode import Cnf, EncodeError, SolverMissing, solve_cnf, solve_cnf_proof, solve_cpsat, to_cnf
from opl_spec import Spec


@dataclass
class SearchResult:
    verdict: str                                     # sat | unsat | unknown
    backend: str = ""
    reason: str | None = None
    assignment: dict[str, int] | None = None
    witness_ok: bool | None = None
    witness_reason: str | None = None
    proof: list[str] = field(default_factory=list)
    elapsed_ms: int = 0
    nvars: int = 0
    nclauses: int = 0
    notes: list[str] = field(default_factory=list)


# ------------------------------------------------------------------ 子进程求解


def _worker(conn, clauses: list[list[int]], backend_name: str, want_proof: bool) -> None:
    """子进程里的求解。结果经管道回传；异常也回传而不是崩掉。"""
    try:
        cnf = Cnf(clauses=clauses)
        if want_proof:
            verdict, model, proof = solve_cnf_proof(cnf, backend=backend_name)
        else:
            verdict, model = solve_cnf(cnf, backend=backend_name)
            proof = None
        conn.send(("ok", verdict, model, proof, None))
    except BaseException as exc:  # noqa: BLE001 —— 子进程里什么都要兜住
        conn.send(("err", None, None, None, f"{type(exc).__name__}: {exc}"))
    finally:
        conn.close()


def _solve_with_timeout(clauses: list[list[int]], backend_name: str,
                        want_proof: bool, timeout_s: float | None
                        ) -> tuple[str | None, list[int] | None, list[str] | None, str | None]:
    """返回 (verdict, model, proof, error)。verdict 为 None 表示没能判定。"""
    if timeout_s is None:
        cnf = Cnf(clauses=clauses)
        if want_proof:
            verdict, model, proof = solve_cnf_proof(cnf, backend=backend_name)
        else:
            verdict, model = solve_cnf(cnf, backend=backend_name)
            proof = None
        return verdict, model, proof, None

    ctx = multiprocessing.get_context("fork")
    parent_conn, child_conn = ctx.Pipe(duplex=False)
    proc = ctx.Process(target=_worker,
                       args=(child_conn, clauses, backend_name, want_proof),
                       daemon=True)
    proc.start()
    child_conn.close()
    try:
        if not parent_conn.poll(timeout_s):
            return None, None, None, f"超时：{timeout_s}s 内未判定"
        kind, verdict, model, proof, err = parent_conn.recv()
        if kind == "err":
            return None, None, None, err
        return verdict, model, proof, None
    finally:
        if proc.is_alive():
            proc.terminate()
        proc.join(5)
        parent_conn.close()


# ---------------------------------------------------------------------- 主流程


def search(spec: Spec, *, backend: str = "sat", sat_backend: str = "glucose42",
           timeout_s: float | None = None, want_proof: bool = True) -> SearchResult:
    """在一个规格上搜索。返回结构化的结果，退出码由调用方决定。"""
    t0 = time.monotonic()
    if backend == "cpsat":
        res = _search_cpsat(spec, timeout_s=timeout_s or 60.0)
    else:
        res = _search_sat(spec, sat_backend=sat_backend, timeout_s=timeout_s,
                          want_proof=want_proof)
    res.elapsed_ms = int((time.monotonic() - t0) * 1000)

    # 无论哪条路径，SAT 结论都要过一遍与编码器无关的直接求值。
    if res.verdict == "sat" and res.assignment is not None:
        ok, why = spec.eval(res.assignment)
        res.witness_ok = ok
        res.witness_reason = why
    return res


def _search_sat(spec: Spec, *, sat_backend: str, timeout_s: float | None,
                want_proof: bool) -> SearchResult:
    cnf = to_cnf(spec)
    res = SearchResult(verdict="unknown", backend=f"pysat:{sat_backend}",
                       nvars=cnf.nvars, nclauses=len(cnf.clauses))
    verdict, model, proof, err = _solve_with_timeout(
        cnf.clauses, sat_backend, want_proof, timeout_s)
    if err is not None:
        # 超时与「求解器报错」都不能当成「无解」——一律 unknown。
        res.reason = err
        return res
    if verdict == "sat":
        if model is None:
            res.reason = "求解器判 sat 却没给模型"
            return res
        res.verdict = "sat"
        res.assignment = cnf.decode(model)
    elif verdict == "unsat":
        res.verdict = "unsat"
        res.proof = proof or []
        if want_proof and not res.proof:
            res.notes.append("求解器未产出证明行（可能是根层单元传播直接导出冲突）；"
                             "此类空证明无法被独立校验器复核")
    else:
        res.reason = "求解器给出 unknown"
    return res


def _search_cpsat(spec: Spec, *, timeout_s: float) -> SearchResult:
    res = SearchResult(verdict="unknown", backend="ortools-cpsat")
    verdict, assign = solve_cpsat(spec, timeout_s=timeout_s)
    if verdict == "sat":
        res.verdict = "sat"
        res.assignment = assign
    elif verdict == "unsat":
        res.verdict = "unsat"
        res.notes.append("CP-SAT 不产出可独立复核的证明；要升到 exact_certificate，"
                         "请改用 SAT 后端出 DRAT 并交 opl-certcheck 复核")
    else:
        res.reason = f"CP-SAT 在 {timeout_s}s 内未能判定"
    return res


__all__ = ["SearchResult", "search", "EncodeError", "SolverMissing"]

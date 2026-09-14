import Init

-- 回归夹具：内核接受，且不依赖任何公理（空集是白名单的子集）。
-- 用 import Init 而非 Mathlib：判定逻辑与导入无关，而 Init 只要 0.5 秒
-- （Mathlib 要 2.2 秒），不让提交钩子为四个夹具多付 7 秒。
theorem opl_ok : True := trivial
#print axioms opl_ok

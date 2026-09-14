import Init

-- 端到端夹具：一个*真命题*，带真正的归纳证明。
--
-- 其余四个 Lean 夹具验的是判定分支（sorry / native_decide / 编译不过 / 无公理），
-- 用的都是 `True := trivial` 这类玩具命题 —— 它们能证明「分支走对了」，却证明不了
-- 「这条链路能承载一个真命题」。本文件补的是后者。
--
-- 命题：前 n 个奇数之和等于 n²。（1 = 1；1+3 = 4；1+3+5 = 9；……）
-- 证明：对 n 归纳。刻意避开 native_decide —— 那会引入白名单外的公理，
-- 于是「编译通过」与「命题已证」分离，正是本工具要抓的那种情形。
-- 只 import Init（0.5 秒；Mathlib 要 2.2 秒）：判定逻辑与导入无关，
-- 不必为提交钩子多付这个钱。
--
-- 期望：内核接受，且 #print axioms 落在白名单内 → lean_checked（退出码 0）。

/-- 前 n 个奇数之和：oddSum 0 = 0，oddSum (n+1) = oddSum n + (2n+1)。 -/
def oddSum : Nat → Nat
  | 0 => 0
  | n + 1 => oddSum n + (2 * n + 1)

theorem oddSum_eq_sq (n : Nat) : oddSum n = n * n := by
  induction n with
  | zero => rfl
  | succ k ih =>
    simp only [oddSum, ih, Nat.succ_mul, Nat.mul_succ]
    omega

#print axioms oddSum_eq_sq

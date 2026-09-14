import Init

-- 回归夹具：带 sorry。期望判定为 sorry_ax 而非 proved。
-- 注意 Lean 对含 sorry 的文件*退出码仍为 0* —— 编译通过不等于已证明。
theorem opl_sorry : True := by sorry
#print axioms opl_sorry

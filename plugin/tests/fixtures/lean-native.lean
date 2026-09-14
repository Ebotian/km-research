import Init

-- 回归夹具：native_decide。期望判定为「未证明」。
-- Lean 核心文档自述该机制向逻辑*新增一条断言公理*，而 #print axioms 会把它
-- 以 <定理名>._native.native_decide.ax_N_M 的名字报出来——不在白名单里。
theorem opl_native : (1 : Nat) + 1 = 2 := by native_decide
#print axioms opl_native

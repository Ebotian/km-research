import Init

-- 回归夹具：编译不过。期望判定为 failed（退出码 1），且错误信息被带出。
theorem opl_bad : (1 : Nat) + 1 = 3 := rfl

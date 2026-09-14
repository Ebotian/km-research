import Mathlib

-- M3 验收第三条：一个**已知定理**（Mathlib 中已有，不是我们自己证的）通过验证，
-- 且 #print axioms 输出落在白名单内。
--
-- 为什么这条不能用 lean-real.lean 顶替：那个验的是「我们的链路能承载一个真命题」，
-- 这个验的是另一件事——Mathlib 够不够得着、审计结论对已存在的定理是否同样正确。
-- 两件事都得有，所以是两个夹具。
--
-- 审计对象：Euclid 的素数无穷定理（`Nat.exists_infinite_primes`，定义见
-- .lake/packages/mathlib/Mathlib/Data/Nat/Prime/Infinite.lean）。选它是因为
-- 名字清晰、语义无歧义、且在 Mathlib 里而不是 Init 里——用它才能证明 Mathlib
-- 这条导入路径真的通了。
--
-- 本文件只 import 与打印，**不重复证明**任何东西。已知定理的价值就在于我们不必
-- 重证——要验的是审计器对它的结论。
--
-- 代价：import Mathlib 约 2.2 秒。所以这一项单独一组，只在 Lean 可用时跑，
-- 且跳过计入 skip，不与四个 Init 夹具共用预算（那四个刻意避开 Mathlib）。

#print axioms Nat.exists_infinite_primes

"""已知最优的 n=4 排序网络：5 个比较器。

它是 `skeleton.py` 的**目标**，不是答案——`opl-evolve` 的工作是从骨架出发把 6 个
比较器降到 5 个。把最优网络放进夹具是为了让「改进」这件事有可判定的参照：
评估器对它能给出 `comparators=5`，而骨架是 6。

n=4 的最优值是 5，这是已知结果（4 个输入的最优比较器网络长 5）。所以「跑出优于
骨架的候选」不是我们编出来的指标，而是一个既有的事实。
"""

N = 4

# EVOLVE-BLOCK-START
def build_network() -> list[tuple[int, int]]:
    return [(0, 1), (2, 3), (0, 2), (1, 3), (1, 2)]
# EVOLVE-BLOCK-END

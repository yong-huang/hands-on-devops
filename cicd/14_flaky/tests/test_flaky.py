"""flaky 用例：random() < 0.5 时失败——重试可能掩盖它，但不能治愈它。"""
import random


def test_flaky_order():
    if random.random() < 0.5:
        raise AssertionError("随机失败注入：本次掷骰子输了")

"""稳定用例：永远绿，用于证明隔离名单不会误伤正常测试。"""


def test_stable_add():
    assert 1 + 1 == 2


def test_stable_str():
    assert "ci".upper() == "CI"


def test_stable_list():
    assert sorted([3, 1, 2]) == [1, 2, 3]

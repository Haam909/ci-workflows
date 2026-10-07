from ciw_sdk import dump


def test_dump():
    assert dump({"a": 1}) == "a = 1\n"

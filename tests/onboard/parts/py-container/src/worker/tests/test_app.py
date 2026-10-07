from app import status


def test_status():
    assert status() == "ok = true\n"

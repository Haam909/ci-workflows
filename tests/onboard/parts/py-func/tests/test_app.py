from function_app import greet


def test_greet():
    assert greet("x") == "Hello, x!"

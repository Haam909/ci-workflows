import tomli_w


def dump(data: dict) -> str:
    return tomli_w.dumps(data)

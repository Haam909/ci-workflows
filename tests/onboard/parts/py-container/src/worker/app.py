import tomli_w


def status() -> str:
    return tomli_w.dumps({"ok": True})

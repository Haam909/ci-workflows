import tomli_w


def app(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [tomli_w.dumps({"ok": True}).encode()]

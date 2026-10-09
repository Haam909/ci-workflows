import azure.functions as func

app = func.FunctionApp()


def greet(name: str) -> str:
    return f"Hello, {name}!"


@app.route(route="ping", auth_level=func.AuthLevel.ANONYMOUS)
def ping(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(greet("ping"))

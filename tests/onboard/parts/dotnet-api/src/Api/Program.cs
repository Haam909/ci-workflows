using Api;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Greeting.For("world"));
app.MapGet("/hello/{name}", (string name) => Greeting.For(name));
app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

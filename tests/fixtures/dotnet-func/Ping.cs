using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

namespace Func;

public class Ping
{
    [Function("ping")]
    public static string Run([HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequestData req) => "pong";
}

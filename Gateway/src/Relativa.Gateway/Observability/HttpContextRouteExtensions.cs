namespace Relativa.Gateway.Observability;

public static class HttpContextRouteExtensions
{
    private const string UnmatchedRoute = "unmatched";

    public static string GetRouteTemplate(this HttpContext context) =>
        (context.GetEndpoint() as RouteEndpoint)?.RoutePattern.RawText ?? UnmatchedRoute;
}

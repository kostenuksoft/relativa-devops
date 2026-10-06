using System.Reflection;

namespace Relativa.Gateway.Health;

public static class HealthEndpoint
{
    private const string ServiceName = "relativa-gateway";

    private static readonly string Version =
        typeof(HealthEndpoint).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion
        ?? typeof(HealthEndpoint).Assembly.GetName().Version?.ToString()
        ?? string.Empty;

    public static IEndpointRouteBuilder MapGatewayHealth(this IEndpointRouteBuilder routes)
    {
        routes.MapGet("/health", () => Results.Ok(
                new GatewayHealthResponse("ok", ServiceName, Version, Environment.MachineName)))
            .AllowAnonymous();

        return routes;
    }

    private sealed record GatewayHealthResponse(string Status, string Service, string Version, string Instance);
}

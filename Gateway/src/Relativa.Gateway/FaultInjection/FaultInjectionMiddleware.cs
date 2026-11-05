using Microsoft.Extensions.Options;

using Relativa.Gateway.Observability;

namespace Relativa.Gateway.FaultInjection;

public sealed class FaultInjectionMiddleware(
    RequestDelegate next,
    IOptionsMonitor<FaultInjectionOptions> options,
    ILogger<FaultInjectionMiddleware> logger)
{
    public Task InvokeAsync(HttpContext context)
    {
        if (Random.Shared.NextDouble() >= options.CurrentValue.FailRate)
        {
            return next(context);
        }

        logger.LogWarning("Injected failure for {method} {route}", context.Request.Method, context.GetRouteTemplate());

        return Results.Problem(
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Injected failure",
                detail: $"The gateway rejects a {FaultInjectionOptions.FailRateKey} share of proxied requests.")
            .ExecuteAsync(context);
    }
}

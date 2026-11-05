using Prometheus;

using Serilog;
using Serilog.Events;

namespace Relativa.Gateway.Observability;

public static class ObservabilityExtensions
{
    private const string MetricsPath = "/metrics";

    public static IApplicationBuilder UseGatewayHttpMetrics(this IApplicationBuilder app) =>
        app.UseMiddleware<HttpMetricsMiddleware>();

    public static IApplicationBuilder UseGatewayRequestLogging(this IApplicationBuilder app) =>
        app.UseSerilogRequestLogging(options =>
        {
            options.MessageTemplate = "HTTP {method} {route} responded {status} in {duration_ms:0.000} ms";
            options.GetMessageTemplateProperties = (context, _, elapsed, status) =>
            [
                new LogEventProperty("method", new ScalarValue(context.Request.Method)),
                new LogEventProperty("route", new ScalarValue(context.GetRouteTemplate())),
                new LogEventProperty("status", new ScalarValue(status)),
                new LogEventProperty("duration_ms", new ScalarValue(elapsed))
            ];
            options.EnrichDiagnosticContext = (diagnostics, context) =>
                diagnostics.Set("path", context.Request.Path.Value);
        });

    public static IEndpointRouteBuilder MapGatewayMetrics(this IEndpointRouteBuilder routes)
    {
        routes.MapMetrics(MetricsPath)
            .WithMetadata(ExcludeFromHttpMetrics.Instance)
            .AllowAnonymous();

        return routes;
    }
}

using System.Diagnostics;
using System.Globalization;

using Prometheus;

namespace Relativa.Gateway.Observability;

public sealed class HttpMetricsMiddleware(RequestDelegate next)
{
    private static readonly Counter Requests = Metrics.CreateCounter(
        "relativa_gateway_http_requests_total",
        "HTTP requests handled by the gateway.",
        new CounterConfiguration { LabelNames = ["method", "route", "status"] });

    private static readonly Histogram Duration = Metrics.CreateHistogram(
        "relativa_gateway_http_request_duration_seconds",
        "Duration of HTTP requests handled by the gateway.",
        new HistogramConfiguration
        {
            LabelNames = ["method", "route"],
            Buckets = Histogram.ExponentialBuckets(0.001, 2, 15)
        });

    public async Task InvokeAsync(HttpContext context)
    {
        var started = Stopwatch.GetTimestamp();
        try
        {
            await next(context);
        }
        finally
        {
            if (context.GetEndpoint()?.Metadata.GetMetadata<ExcludeFromHttpMetrics>() is null)
            {
                var method = context.Request.Method;
                var route = context.GetRouteTemplate();
                var status = context.Response.StatusCode.ToString(CultureInfo.InvariantCulture);

                Requests.WithLabels(method, route, status).Inc();
                Duration.WithLabels(method, route).Observe(Stopwatch.GetElapsedTime(started).TotalSeconds);
            }
        }
    }
}

public sealed class ExcludeFromHttpMetrics
{
    public static readonly ExcludeFromHttpMetrics Instance = new();

    private ExcludeFromHttpMetrics()
    {
    }
}

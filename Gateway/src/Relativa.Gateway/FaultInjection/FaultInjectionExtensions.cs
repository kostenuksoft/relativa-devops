namespace Relativa.Gateway.FaultInjection;

public static class FaultInjectionExtensions
{
    public static IServiceCollection AddFaultInjection(this IServiceCollection services)
    {
        services.AddOptions<FaultInjectionOptions>()
            .Configure<IConfiguration>((options, configuration) =>
                options.FailRate = configuration.GetValue<double>(FaultInjectionOptions.FailRateKey))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        return services;
    }

    public static IApplicationBuilder UseFaultInjection(this IApplicationBuilder app) =>
        app.UseMiddleware<FaultInjectionMiddleware>();
}

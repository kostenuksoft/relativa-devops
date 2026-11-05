using System.ComponentModel.DataAnnotations;

namespace Relativa.Gateway.FaultInjection;

public sealed class FaultInjectionOptions
{
    public const string FailRateKey = "FAIL_RATE";

    [Range(0.0, 1.0)]
    public double FailRate { get; set; }
}

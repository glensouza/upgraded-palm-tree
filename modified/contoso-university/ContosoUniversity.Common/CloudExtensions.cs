using System;
using System.Linq;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using ContosoUniversity.Data.DbContexts;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace ContosoUniversity.Common
{
    // Everything the apps need to run well in Azure lives here. Each feature turns on
    // only when its setting is present, so local development and tests are unchanged.
    public static class CloudExtensions
    {
        // Pulls secrets (SQL, SendGrid, Twilio, OAuth, JWT key) from Key Vault using the
        // app's managed identity. Nothing sensitive lives in appsettings or env vars.
        public static IConfigurationBuilder AddAzureKeyVaultIfConfigured(this IConfigurationBuilder config)
        {
            var vaultUri = config.Build()["KeyVault:Uri"];
            if (!string.IsNullOrWhiteSpace(vaultUri))
            {
                config.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());
            }

            return config;
        }

        public static IServiceCollection AddCloudReadiness(this IServiceCollection services, IConfiguration configuration)
        {
            // Logs, traces and metrics to Application Insights through OpenTelemetry.
            if (!string.IsNullOrWhiteSpace(configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
            {
                services.AddOpenTelemetry().UseAzureMonitor();
            }

            // TLS ends at Front Door / the Container Apps ingress, so trust the forwarded
            // scheme and client IP. Otherwise HTTPS redirects and OAuth callbacks break.
            services.Configure<ForwardedHeadersOptions>(options =>
            {
                options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto | ForwardedHeaders.XForwardedHost;
                options.KnownIPNetworks.Clear();
                options.KnownProxies.Clear();
            });

            // With more than one replica, every instance must share the same Data Protection
            // keys or auth cookies and antiforgery tokens fail on the next request.
            var keysBlobUri = configuration["DataProtection:BlobUri"];
            var keyVaultKeyUri = configuration["DataProtection:KeyUri"];
            if (!string.IsNullOrWhiteSpace(keysBlobUri) && !string.IsNullOrWhiteSpace(keyVaultKeyUri))
            {
                var credential = new DefaultAzureCredential();
                services.AddDataProtection()
                    .SetApplicationName("ContosoUniversity")
                    .PersistKeysToAzureBlobStorage(new Uri(keysBlobUri), credential)
                    .ProtectKeysWithAzureKeyVault(new Uri(keyVaultKeyUri), credential);
            }

            services.AddHealthChecks()
                .AddDbContextCheck<ApplicationContext>("database", tags: new[] { "ready" });

            return services;
        }

        // /healthz/live  - process is up (liveness probe, no dependencies)
        // /healthz/ready - database reachable (readiness probe, Front Door and availability tests)
        public static IEndpointRouteBuilder MapHealthEndpoints(this IEndpointRouteBuilder endpoints)
        {
            endpoints.MapHealthChecks("/healthz/live", new HealthCheckOptions { Predicate = _ => false });
            endpoints.MapHealthChecks("/healthz/ready", new HealthCheckOptions { Predicate = check => check.Tags.Contains("ready") });
            return endpoints;
        }
    }
}

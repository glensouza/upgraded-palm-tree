using ContosoUniversity.Common;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace ContosoUniversity
{
    public class Program
    {
        public static void Main(string[] args)
        {
            CreateHostBuilder(args).Build().Run();
        }

        // Generic host + Startup keeps the existing Startup class and the
        // WebApplicationFactory-based integration tests working.
        public static IHostBuilder CreateHostBuilder(string[] args) =>
            Host.CreateDefaultBuilder(args)
                .ConfigureAppConfiguration(ConfigConfiguration)
                .ConfigureWebHostDefaults(webBuilder => webBuilder.UseStartup<Startup>());

        public static void ConfigConfiguration(HostBuilderContext context, IConfigurationBuilder config)
        {
            // sample data used by the database initializer
            config.AddJsonFile("sampleData.json", optional: true, reloadOnChange: false);

            if (context.HostingEnvironment.IsDevelopment())
            {
                config.AddUserSecrets<Startup>();
            }

            config.AddEnvironmentVariables();
            config.AddAzureKeyVaultIfConfigured();
        }
    }
}

using System.IO;
using ContosoUniversity.Common;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace ContosoUniversity.Api
{
    public class Program
    {
        public static void Main(string[] args)
        {
            CreateHostBuilder(args).Build().Run();
        }

        // also used by EF tooling
        public static IHostBuilder CreateHostBuilder(string[] args) =>
            Host.CreateDefaultBuilder(args)
                .ConfigureAppConfiguration(ConfigConfiguration)
                .ConfigureWebHostDefaults(webBuilder => webBuilder.UseStartup<Startup>());

        public static void ConfigConfiguration(HostBuilderContext context, IConfigurationBuilder config)
        {
            config.SetBasePath(Directory.GetCurrentDirectory())
                  .AddJsonFile("appsettings.json", optional: true, reloadOnChange: true)
                  .AddJsonFile($"appsettings.{context.HostingEnvironment.EnvironmentName}.json", optional: true)
                  .AddJsonFile("sampleData.json", optional: true, reloadOnChange: false);

            if (context.HostingEnvironment.IsDevelopment())
            {
                config.AddUserSecrets<Startup>();
            }

            config.AddEnvironmentVariables();
            config.AddAzureKeyVaultIfConfigured();
        }
    }
}

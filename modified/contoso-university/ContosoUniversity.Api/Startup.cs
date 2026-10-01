using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ContosoUniversity.Common;
using ContosoUniversity.Common.Data;
using ContosoUniversity.Common.Interfaces;
using Microsoft.OpenApi;
using ContosoUniversity.Data.DbContexts;

namespace ContosoUniversity.Api
{
    public class Startup
    {
        public IConfiguration Configuration { get; }
        public IWebHostEnvironment CurrentEnvironment { get; }

        public Startup(IWebHostEnvironment env, IConfiguration config)
        {
            CurrentEnvironment = env;
            Configuration = config;
        }

        public void ConfigureServices(IServiceCollection services)
        {
            services.AddCustomizedContext(Configuration, CurrentEnvironment)
                .AddCustomizedMvc(CurrentEnvironment)
                .AddSwaggerGen(c =>
                {
                    c.SwaggerDoc("v1", new OpenApiInfo { Title = "Contoso University Api", Version = "v1" });
                });

            services.AddCustomizedApiAuthentication(Configuration);
            services.AddCloudReadiness(Configuration);
            services.AddProblemDetails();
            services.AddScoped<UnitOfWork<ApiContext>, UnitOfWork<ApiContext>>();
            services.AddScoped<IDbInitializer, ApiInitializer>();
        }

        public void Configure(IApplicationBuilder app, IDbInitializer dbInitializer)
        {
            app.UseForwardedHeaders();

            if (CurrentEnvironment.IsDevelopment() || Configuration.GetValue<bool>("Database:InitializeOnStartup"))
            {
                dbInitializer.Initialize();
            }

            if (CurrentEnvironment.IsDevelopment())
            {
                app.UseDeveloperExceptionPage();
            }
            else
            {
                // RFC 7807 problem details instead of stack traces
                app.UseExceptionHandler();
                app.UseHsts();
            }

            app.UseDefaultFiles()
                .UseStaticFiles()
                .UseSwagger()
                .UseSwaggerUI(c =>
                {
                    c.SwaggerEndpoint("/swagger/v1/swagger.json", "Contoso API V1");
                })
                .UseRouting()
                .UseAuthentication()
                .UseAuthorization()
                .UseEndpoints(endpoints =>
                {
                    endpoints.MapHealthEndpoints();
                    endpoints.MapDefaultControllerRoute();
                });
        }

        public void ConfigureTesting(IApplicationBuilder app, IDbInitializer dbInitializer)
        {
            dbInitializer.Initialize();
            app.UseRouting()
                .UseAuthentication()
                .UseAuthorization()
                .UseEndpoints(endpoints => endpoints.MapDefaultControllerRoute());
        }
    }
}

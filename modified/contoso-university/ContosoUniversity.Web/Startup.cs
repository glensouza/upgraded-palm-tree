using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ContosoUniversity.Web;
using ContosoUniversity.Common;
using ContosoUniversity.Web.Helpers;
using ContosoUniversity.Common.Data;
using ContosoUniversity.Common.Interfaces;

namespace ContosoUniversity
{
    public class Startup
    {
        public Startup(IWebHostEnvironment env, IConfiguration config)
        {
            CurrentEnvironment = env;
            Configuration = config;
        }

        public IConfiguration Configuration { get; }
        public IWebHostEnvironment CurrentEnvironment { get; }

        public void ConfigureServices(IServiceCollection services)
        {
            services.AddCustomizedContext(Configuration, CurrentEnvironment);
            services.AddCustomizedIdentity(Configuration, CurrentEnvironment);
            services.AddCustomizedAuthentication(Configuration);
            services.AddCustomizedMessage(Configuration);
            services.AddCustomizedMvc(CurrentEnvironment);
            services.AddCloudReadiness(Configuration);

            services.AddScoped<IDbInitializer, WebInitializer>();
            services.AddScoped<IModelBindingHelperAdaptor, DefaultModelBindingHelaperAdaptor>();
            services.AddScoped<IUrlHelperAdaptor, UrlHelperAdaptor>();
            services.AddSingleton<IConfiguration>(Configuration);
        }

        public void Configure(IApplicationBuilder app,
            IWebHostEnvironment env,
            IDbInitializer dbInitializer)
        {
            app.UseForwardedHeaders();

            // In Azure, the staging slot sets Database:InitializeOnStartup so the schema and seed
            // data are applied once, before the slot is swapped into production.
            if (env.IsDevelopment() || Configuration.GetValue<bool>("Database:InitializeOnStartup"))
            {
                dbInitializer.Initialize();
            }

            if (env.IsDevelopment())
            {
                app.UseDeveloperExceptionPage();
            }
            else
            {
                // The original left this commented out, so production users saw raw errors.
                app.UseExceptionHandler("/Error");
                app.UseHsts();
            }

            // aspnetcore 2.1 Require HTTPS
            // https://docs.microsoft.com/en-us/aspnet/core/security/enforcing-ssl?view=aspnetcore-3.1&tabs=visual-studio
            // enable via config file
            var enableHttps = Configuration["EnableHttps"];
            if (!string.IsNullOrWhiteSpace(enableHttps) && enableHttps.ToLower() == "true")
            {
                // enable https redirection middleware
                app.UseHttpsRedirection();
            }

            app.UseStaticFiles();
            app.UseRouting();
            app.UseAuthentication();
            app.UseAuthorization();
            app.UseEndpoints(endpoints =>
            {
                endpoints.MapHealthEndpoints();
                endpoints.MapRazorPages();
                endpoints.MapDefaultControllerRoute();
            });
        }
    }
}

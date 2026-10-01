using Microsoft.Extensions.Logging;
using ContosoUniversity.Common.Interfaces;
using Microsoft.Extensions.Options;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Hosting;
using ContosoUniversity.Data.DbContexts;

namespace ContosoUniversity.Common.Data
{
    public class ApiInitializer : IDbInitializer
    {
        private readonly ApiContext _context;
        private readonly ILogger _logger;
        private readonly SampleData _data;
        private readonly IWebHostEnvironment _environment;

        public ApiInitializer(ApiContext context, 
            ILoggerFactory loggerFactory,
            IOptions<SampleData> dataOptions,
            IWebHostEnvironment env)
        {
            _context = context;
            _logger = loggerFactory.CreateLogger("ApiInitializer");
            _data = dataOptions.Value;
            _environment = env;
        }
        public void Initialize()
        {
            InitializeContext();
        }

        private void InitializeContext()
        {
            // create database schema if it does not exist
            if (_context.Database.EnsureCreated())
            {
                _logger.LogInformation("Creating database schema...");
            }
            var unitOfWork = new UnitOfWork<ApiContext>(_context);
            var seedData = new SeedData<ApiContext>(_logger, unitOfWork, _data);
            seedData.Initialize();
        }
    }
}

using Microsoft.AspNetCore.Mvc;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading.Tasks;
using ContosoUniversity.Common.Interfaces;
using ContosoUniversity.Data.Entities;
using System.Linq;
using ContosoUniversity.Common;
using ContosoUniversity.Data.DbContexts;
using ContosoUniversity.Common.DTO;

namespace ContosoUniversity_Spa_React.Controllers
{
    [Route("api/[controller]")]
    public class CoursesController : Controller
    {
        private readonly IRepository<Course> _coursesRepo;

        public CoursesController(UnitOfWork<ApiContext> unitOfWork)
        {
            _coursesRepo = unitOfWork.CourseRepository;
        }

        public IEnumerable<Course> Get()
        {
            return _coursesRepo.GetAll().ToArray();
        }
    }
}
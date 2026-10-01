using ContosoUniversity.Data.Entities;
using Microsoft.EntityFrameworkCore;
using System;
using System.Data.Common;
using System.Linq;
using System.Threading.Tasks;

namespace ContosoUniversity.Common.Interfaces
{
    public interface IRepository<T> where T : BaseEntity
    {
        IQueryable<T> GetAll();
        IQueryable<T> Get(int id);
        void Add(T entity);
        Task AddAsync(T entity);
        void Update(T entity, byte[] rowVersion);
        void Delete(T entity);
        Task<int> ExecuteSqlCommandAsync(FormattableString query);
        Task SaveChangesAsync();
        DbConnection GetDbConnection();
    }
}

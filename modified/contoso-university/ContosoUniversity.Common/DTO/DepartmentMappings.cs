using ContosoUniversity.Data.Entities;

namespace ContosoUniversity.Common.DTO
{
    // Explicit mappings replace AutoMapper. They are checked by the compiler,
    // easy to debug, and remove a third-party dependency from the runtime.
    public static class DepartmentMappings
    {
        public static DepartmentDTO ToDepartmentDTO(this Department department) => new DepartmentDTO
        {
            ID = department.ID,
            InstructorID = department.InstructorID ?? 0,
            Name = department.Name,
            Budget = department.Budget,
            StartDate = department.StartDate
        };

        public static Department ToDepartment(this DepartmentDTO dto) => new Department
        {
            ID = dto.ID,
            InstructorID = dto.InstructorID,
            Name = dto.Name,
            Budget = dto.Budget,
            StartDate = dto.StartDate
        };
    }
}

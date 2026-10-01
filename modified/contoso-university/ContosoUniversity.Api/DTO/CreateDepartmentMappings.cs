using ContosoUniversity.Data.Entities;

namespace ContosoUniversity.Api.DTO
{
    public static class CreateDepartmentMappings
    {
        public static Department ToDepartment(this CreateDepartmentDTO dto) => new Department
        {
            InstructorID = dto.InstructorID,
            Name = dto.Name,
            Budget = dto.Budget,
            StartDate = dto.StartDate
        };

        public static CreateDepartmentDTO ToCreateDepartmentDTO(this Department department) => new CreateDepartmentDTO
        {
            InstructorID = department.InstructorID ?? 0,
            Name = department.Name,
            Budget = department.Budget,
            StartDate = department.StartDate
        };
    }
}

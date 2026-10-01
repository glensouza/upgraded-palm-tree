using System;
using ContosoUniversity.Data.Entities;

namespace ContosoUniversity.ViewModels
{
    public static class DepartmentMappings
    {
        public static DepartmentDetailsViewModel ToDetailsViewModel(this Department department) => new DepartmentDetailsViewModel
        {
            ID = department.ID,
            Name = department.Name,
            Budget = department.Budget,
            StartDate = department.StartDate,
            InstructorID = department.InstructorID ?? 0,
            Administrator = department.Administrator?.FullName
        };

        public static DepartmentEditViewModel ToEditViewModel(this Department department) => new DepartmentEditViewModel
        {
            ID = department.ID,
            Name = department.Name,
            Budget = department.Budget,
            StartDate = department.StartDate,
            InstructorID = department.InstructorID ?? 0,
            Administrator = department.Administrator?.FullName,
            // Base64 round-trips the SQL Server rowversion through the hidden form field.
            // The original code used Encoding.ASCII on the way back in, which corrupted it.
            RowVersion = department.RowVersion == null ? null : Convert.ToBase64String(department.RowVersion)
        };

        public static Department ToDepartment(this DepartmentCreateViewModel vm) => new Department
        {
            Name = vm.Name,
            Budget = vm.Budget,
            StartDate = vm.StartDate,
            InstructorID = vm.InstructorID
        };

        public static void ApplyTo(this DepartmentEditViewModel vm, Department department)
        {
            department.Name = vm.Name;
            department.Budget = vm.Budget;
            department.StartDate = vm.StartDate;
            department.InstructorID = vm.InstructorID;
        }

        public static byte[] RowVersionBytes(this DepartmentEditViewModel vm) =>
            string.IsNullOrEmpty(vm.RowVersion) ? null : Convert.FromBase64String(vm.RowVersion);
    }
}

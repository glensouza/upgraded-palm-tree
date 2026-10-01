using 'main.bicep'

param environmentName = readEnvironmentVariable('ENVIRONMENT_NAME', 'dev')
param alertEmail = readEnvironmentVariable('ALERT_EMAIL', 'cloudops@example.com')
param sqlAdminGroupObjectId = readEnvironmentVariable('SQL_ADMIN_GROUP_OBJECT_ID', '00000000-0000-0000-0000-000000000000')
param sqlAdminGroupName = readEnvironmentVariable('SQL_ADMIN_GROUP_NAME', 'sg-contoso-sql-admins')
param sqlClientIpAddress = readEnvironmentVariable('SQL_CLIENT_IP', '')
param adminUserName = readEnvironmentVariable('ADMIN_USER_NAME', 'admin@contoso.edu')

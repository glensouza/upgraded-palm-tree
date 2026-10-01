using 'main.bicep'

param environmentName = readEnvironmentVariable('ENVIRONMENT_NAME', 'dev')
param location = 'westus2'
param alertEmail = readEnvironmentVariable('ALERT_EMAIL', 'cloudops@example.com')

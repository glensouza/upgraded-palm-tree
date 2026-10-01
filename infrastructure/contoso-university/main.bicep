// Contoso University on Azure App Service
//
//   Internet -> Front Door Premium + WAF -> App Service (web, api; .NET 10 Linux)
//            -> VNet integration -> private endpoints -> Azure SQL / Key Vault / Storage
//
// One user-assigned managed identity is used by both apps for SQL, Key Vault and Storage.
// No passwords, connection-string secrets or storage keys exist anywhere in this deployment.

targetScope = 'resourceGroup'

@description('Short environment name, used in resource names, SKUs and tags.')
@allowed([
  'dev'
  'prod'
])
param environmentName string = 'dev'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Email address that receives operational alerts.')
param alertEmail string

@description('Object ID of the Entra ID group that administers Azure SQL (e.g. "sg-contoso-sql-admins").')
param sqlAdminGroupObjectId string

@description('Display name of that Entra ID group.')
param sqlAdminGroupName string

@description('Optional: your public IP, opened on the SQL firewall only for the one-time database user setup. Leave empty afterwards.')
param sqlClientIpAddress string = ''

@description('Administrator account created on first run. The password goes in Key Vault as "Administrator--Password".')
param adminUserName string = 'admin@contoso.edu'

var isProduction = environmentName == 'prod'
var namePrefix = 'contoso-${environmentName}'
var uniqueSuffix = take(uniqueString(resourceGroup().id), 6)
var tags = {
  application: 'contoso-university'
  environment: environmentName
  managedBy: 'bicep'
}

var webAppName = 'app-${namePrefix}-web-${uniqueSuffix}'
var apiAppName = 'app-${namePrefix}-api-${uniqueSuffix}'
var appInsightsId = resourceId('Microsoft.Insights/components', 'appi-${namePrefix}')

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}'
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    alertEmail: alertEmail
    retentionInDays: isProduction ? 90 : 30
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module data 'modules/data.bicep' = {
  name: 'data'
  params: {
    location: location
    namePrefix: namePrefix
    uniqueSuffix: uniqueSuffix
    tags: tags
    isProduction: isProduction
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    sqlDnsZoneId: network.outputs.sqlDnsZoneId
    keyVaultDnsZoneId: network.outputs.keyVaultDnsZoneId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    appIdentityPrincipalId: appIdentity.properties.principalId
    sqlAdminGroupObjectId: sqlAdminGroupObjectId
    sqlAdminGroupName: sqlAdminGroupName
    sqlClientIpAddress: sqlClientIpAddress
  }
}

module frontDoor 'modules/frontdoor.bicep' = {
  name: 'frontdoor'
  params: {
    namePrefix: namePrefix
    tags: tags
    isProduction: isProduction
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    webAppHostname: '${webAppName}.azurewebsites.net'
    apiAppHostname: '${apiAppName}.azurewebsites.net'
  }
}

module web 'modules/web.bicep' = {
  name: 'web'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    isProduction: isProduction
    webAppName: webAppName
    apiAppName: apiAppName
    appSubnetId: network.outputs.appSubnetId
    identityId: appIdentity.id
    identityClientId: appIdentity.properties.clientId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    frontDoorId: frontDoor.outputs.frontDoorId
    keyVaultUri: data.outputs.keyVaultUri
    dataProtectionBlobUri: data.outputs.dataProtectionBlobUri
    dataProtectionKeyUri: data.outputs.dataProtectionKeyUri
    sqlServerFqdn: data.outputs.sqlServerFqdn
    sqlDatabaseName: data.outputs.sqlDatabaseName
    adminUserName: adminUserName
  }
}

// ---------- Alerts ----------

// Synthetic check of the full path (Front Door -> app -> SQL) from five regions.
resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'avail-${namePrefix}-web'
  location: location
  tags: union(tags, {
    'hidden-link:${appInsightsId}': 'Resource'
  })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: 'avail-${namePrefix}-web'
    Name: 'Contoso web readiness'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: true
    Locations: [
      { Id: 'us-ca-sjc-azr' }
      { Id: 'us-tx-sn1-azr' }
      { Id: 'us-va-ash-azr' }
      { Id: 'emea-nl-ams-azr' }
      { Id: 'apac-sg-sin-azr' }
    ]
    Request: {
      RequestUrl: 'https://${frontDoor.outputs.webEndpointHostname}/healthz/ready'
      HttpVerb: 'GET'
      ParseDependentRequests: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 14
    }
  }
}

resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${namePrefix}-availability'
  location: 'global'
  tags: tags
  properties: {
    description: 'Contoso web failed readiness checks from 2 or more regions.'
    severity: 1
    enabled: true
    scopes: [
      availabilityTest.id
      monitoring.outputs.appInsightsId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: monitoring.outputs.appInsightsId
      failedLocationCount: 2
    }
    actions: [
      { actionGroupId: monitoring.outputs.actionGroupId }
    ]
  }
}

var appAlerts = [
  { key: 'web', name: webAppName }
  { key: 'api', name: apiAppName }
]

resource http5xxAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for app in appAlerts: {
  name: 'alert-${namePrefix}-${app.key}-http5xx'
  location: 'global'
  tags: tags
  dependsOn: [
    web
  ]
  properties: {
    description: 'More than 10 server errors in 5 minutes.'
    severity: 2
    enabled: true
    scopes: [
      resourceId('Microsoft.Web/sites', app.name)
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'Http5xx'
          metricName: 'Http5xx'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 10
        }
      ]
    }
    actions: [
      { actionGroupId: monitoring.outputs.actionGroupId }
    ]
  }
}]

resource responseTimeAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for app in appAlerts: {
  name: 'alert-${namePrefix}-${app.key}-latency'
  location: 'global'
  tags: tags
  dependsOn: [
    web
  ]
  properties: {
    description: 'Average response time above 2 seconds for 10 minutes.'
    severity: 3
    enabled: true
    scopes: [
      resourceId('Microsoft.Web/sites', app.name)
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ResponseTime'
          metricName: 'HttpResponseTime'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: 2
        }
      ]
    }
    actions: [
      { actionGroupId: monitoring.outputs.actionGroupId }
    ]
  }
}]

output webAppName string = web.outputs.webAppName
output apiAppName string = web.outputs.apiAppName
output webUrl string = 'https://${frontDoor.outputs.webEndpointHostname}'
output apiUrl string = 'https://${frontDoor.outputs.apiEndpointHostname}'
output keyVaultName string = data.outputs.keyVaultName
output sqlServerName string = data.outputs.sqlServerName
output sqlDatabaseName string = data.outputs.sqlDatabaseName
output appIdentityName string = appIdentity.name

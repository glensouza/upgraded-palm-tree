// Linux App Service plan running the MVC web app and the REST API on the managed
// .NET 10 runtime. Each app has a staging slot for zero-downtime swap deployments.

param location string
param namePrefix string
param tags object
param isProduction bool

param appSubnetId string
param identityId string
param identityClientId string
param logAnalyticsId string
param appInsightsConnectionString string

@description('Front Door profile ID (frontDoorId). Apps only accept traffic carrying this ID in the X-Azure-FDID header.')
param frontDoorId string

param keyVaultUri string
param dataProtectionBlobUri string
param dataProtectionKeyUri string
param sqlServerFqdn string
param sqlDatabaseName string

@description('Administrator account seeded on first run. Its password is read from the Key Vault secret "Administrator--Password".')
param adminUserName string

// Names are computed in main.bicep so Front Door can reference the hostnames
// without creating a circular dependency on this module.
param webAppName string
param apiAppName string

// Passwordless: the app authenticates to Azure SQL with its managed identity.
var sqlConnectionString = 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Authentication=Active Directory Managed Identity;User Id=${identityClientId};Encrypt=True;TrustServerCertificate=False;MultipleActiveResultSets=True;Connection Timeout=30;'

var sharedSettings = [
  { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
  { name: 'AZURE_CLIENT_ID', value: identityClientId }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
  { name: 'KeyVault__Uri', value: keyVaultUri }
  { name: 'DataProtection__BlobUri', value: dataProtectionBlobUri }
  { name: 'DataProtection__KeyUri', value: dataProtectionKeyUri }
  { name: 'ConnectionStrings__DefaultConnection', value: sqlConnectionString }
  // HTTPS is enforced by Front Door and App Service (httpsOnly), not by app middleware.
  { name: 'EnableHttps', value: 'false' }
  { name: 'Administrator__UserName', value: adminUserName }
  // A slot swap only completes once the new code reports healthy on this path.
  { name: 'WEBSITE_SWAP_WARMUP_PING_PATH', value: '/healthz/ready' }
  { name: 'WEBSITE_SWAP_WARMUP_PING_STATUSES', value: '200' }
]

// The staging slot creates/seeds the database when it starts, before it is swapped in.
// Marked as a slot setting below so it never follows the code into production.
var stagingOnlySettings = [
  { name: 'Database__InitializeOnStartup', value: 'true' }
]

var siteConfig = {
  linuxFxVersion: 'DOTNETCORE|10.0'
  alwaysOn: true
  http20Enabled: true
  minTlsVersion: '1.2'
  ftpsState: 'Disabled'
  healthCheckPath: '/healthz/ready'
  vnetRouteAllEnabled: true
  // Only Front Door may reach the apps. Deployments use the SCM site, which keeps its own rules.
  ipSecurityRestrictionsDefaultAction: 'Deny'
  ipSecurityRestrictions: [
    {
      name: 'Allow-FrontDoor'
      action: 'Allow'
      priority: 100
      tag: 'ServiceTag'
      ipAddress: 'AzureFrontDoor.Backend'
      headers: {
        'x-azure-fdid': [
          frontDoorId
        ]
      }
    }
  ]
  scmIpSecurityRestrictionsUseMain: false
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${namePrefix}'
  location: location
  tags: tags
  kind: 'linux'
  sku: isProduction ? {
    name: 'P1v3'
    tier: 'PremiumV3'
    capacity: 2
  } : {
    name: 'P0v3'
    tier: 'PremiumV3'
    capacity: 1
  }
  properties: {
    reserved: true
    zoneRedundant: isProduction
  }
}

var apps = [
  { name: webAppName, role: 'web' }
  { name: apiAppName, role: 'api' }
]

resource sites 'Microsoft.Web/sites@2024-04-01' = [for app in apps: {
  name: app.name
  location: location
  tags: union(tags, { component: app.role })
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    keyVaultReferenceIdentity: identityId
    virtualNetworkSubnetId: appSubnetId
    siteConfig: union(siteConfig, {
      appSettings: sharedSettings
    })
  }
}]

resource stagingSlots 'Microsoft.Web/sites/slots@2024-04-01' = [for (app, i) in apps: {
  parent: sites[i]
  name: 'staging'
  location: location
  tags: union(tags, { component: app.role })
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    keyVaultReferenceIdentity: identityId
    virtualNetworkSubnetId: appSubnetId
    siteConfig: union(siteConfig, {
      // Smaller footprint while idle; the slot is warmed up by the pipeline before a swap.
      alwaysOn: false
      appSettings: concat(sharedSettings, stagingOnlySettings)
    })
  }
}]

resource stickySettings 'Microsoft.Web/sites/config@2024-04-01' = [for (app, i) in apps: {
  parent: sites[i]
  name: 'slotConfigNames'
  properties: {
    appSettingNames: [
      'Database__InitializeOnStartup'
    ]
  }
}]

// Deployments authenticate with Entra ID (OIDC from GitHub), so turn off FTP and basic auth.
resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = [for (app, i) in apps: {
  parent: sites[i]
  name: 'ftp'
  properties: {
    allow: false
  }
}]

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = [for (app, i) in apps: {
  parent: sites[i]
  name: 'scm'
  properties: {
    allow: false
  }
}]

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (app, i) in apps: {
  scope: sites[i]
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServiceConsoleLogs', enabled: true }
      { category: 'AppServiceAppLogs', enabled: true }
      { category: 'AppServicePlatformLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}]

// Production scales out on CPU between 2 and 6 instances.
resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = if (isProduction) {
  name: 'autoscale-${plan.name}'
  location: location
  tags: tags
  properties: {
    enabled: true
    targetResourceUri: plan.id
    profiles: [
      {
        name: 'cpu'
        capacity: {
          minimum: '2'
          maximum: '6'
          default: '2'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT20M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
  }
}

output planId string = plan.id
output webAppName string = sites[0].name
output apiAppName string = sites[1].name
output webAppId string = sites[0].id
output apiAppId string = sites[1].id
output webAppHostname string = sites[0].properties.defaultHostName
output apiAppHostname string = sites[1].properties.defaultHostName

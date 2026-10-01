// Log Analytics + Application Insights + the action group every alert routes to.

param location string
param namePrefix string
param tags object
param alertEmail string

@description('Days to keep logs. 30 is included in the base price; raise for compliance needs.')
param retentionInDays int = 30

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${namePrefix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    // Telemetry is sent with Entra auth from the app's managed identity in a later phase;
    // keep local auth on until then so the connection string works.
    DisableLocalAuth: false
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'contoso-ops'
    enabled: true
    emailReceivers: [
      {
        name: 'operations'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

output logAnalyticsId string = logAnalytics.id
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output actionGroupId string = actionGroup.id

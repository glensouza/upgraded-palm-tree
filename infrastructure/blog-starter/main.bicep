// Blog Starter (Next.js static export) on Azure Static Web Apps
//
// The blog is pre-rendered to plain HTML at build time, so there is no server to run,
// patch or scale. Static Web Apps serves it from a global edge network with a free
// managed TLS certificate, and gives every pull request its own preview environment.

targetScope = 'resourceGroup'

@description('Short environment name, used in resource names and tags.')
@allowed([
  'dev'
  'prod'
])
param environmentName string = 'dev'

@description('Region for the Static Web App control plane and monitoring resources. Content is served globally.')
@allowed([
  'westus2'
  'centralus'
  'eastus2'
  'westeurope'
  'eastasia'
])
param location string = 'westus2'

@description('Email address that receives availability alerts.')
param alertEmail string

var appName = 'blog-starter'
var suffix = take(uniqueString(resourceGroup().id), 6)
var tags = {
  application: appName
  environment: environmentName
  managedBy: 'bicep'
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${appName}-${environmentName}-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${appName}-${environmentName}-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// Standard tier: custom domains with SLA, private endpoints if needed later, and
// enterprise-grade edge. Free tier is fine for a personal blog but has no SLA.
resource staticWebApp 'Microsoft.Web/staticSites@2024-04-01' = {
  name: 'stapp-${appName}-${environmentName}-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    // Deployments come from the GitHub Actions workflow, not from a repo link,
    // so the pipeline stays in control of build, test and approval steps.
    provider: 'None'
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    enterpriseGradeCdnStatus: 'Disabled'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${appName}-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'blog-ops'
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

// Probes the home page from five regions every 5 minutes.
resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'avail-${appName}-${environmentName}'
  location: location
  tags: union(tags, {
    'hidden-link:${appInsights.id}': 'Resource'
  })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: 'avail-${appName}-${environmentName}'
    Name: 'Blog home page'
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
      RequestUrl: 'https://${staticWebApp.properties.defaultHostname}/'
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
  name: 'alert-${appName}-${environmentName}-availability'
  location: 'global'
  tags: tags
  properties: {
    description: 'The blog failed availability checks from 2 or more regions.'
    severity: 1
    enabled: true
    scopes: [
      availabilityTest.id
      appInsights.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: appInsights.id
      failedLocationCount: 2
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

output staticWebAppName string = staticWebApp.name
output defaultHostname string = staticWebApp.properties.defaultHostname
output appInsightsConnectionString string = appInsights.properties.ConnectionString

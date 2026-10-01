// Azure Front Door Premium with WAF: global entry point, TLS termination, managed
// certificates, OWASP and bot protection. Origins are the two App Service apps.

param namePrefix string
param tags object
param isProduction bool
param logAnalyticsId string

param webAppHostname string
param apiAppHostname string

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: 'afd-${namePrefix}'
  location: 'global'
  tags: tags
  sku: {
    // Premium is required for the managed WAF rule sets and bot protection.
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: 'waf${replace(namePrefix, '-', '')}'
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      // Detection in dev to tune false positives, Prevention in prod.
      mode: isProduction ? 'Prevention' : 'Detection'
      requestBodyCheck: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
        }
      ]
    }
  }
}

var sites = [
  { name: 'web', hostname: webAppHostname }
  { name: 'api', hostname: apiAppHostname }
]

resource endpoints 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = [for site in sites: {
  parent: profile
  name: '${namePrefix}-${site.name}'
  location: 'global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}]

resource originGroups 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = [for site in sites: {
  parent: profile
  name: 'og-${site.name}'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/healthz/live'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 60
    }
    sessionAffinityState: 'Disabled'
  }
}]

resource origins 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = [for (site, i) in sites: {
  parent: originGroups[i]
  name: 'appservice'
  properties: {
    hostName: site.hostname
    originHostHeader: site.hostname
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}]

resource routes 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = [for (site, i) in sites: {
  parent: endpoints[i]
  name: 'default'
  dependsOn: [
    origins[i]
  ]
  properties: {
    originGroup: {
      id: originGroups[i].id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
  }
}]

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  parent: profile
  name: 'waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: wafPolicy.id
      }
      associations: [
        {
          domains: [for (site, i) in sites: {
            id: endpoints[i].id
          }]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: profile
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      { category: 'FrontDoorAccessLog', enabled: true }
      { category: 'FrontDoorHealthProbeLog', enabled: true }
      { category: 'FrontDoorWebApplicationFirewallLog', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output profileId string = profile.id
output frontDoorId string = profile.properties.frontDoorId
output webEndpointHostname string = endpoints[0].properties.hostName
output apiEndpointHostname string = endpoints[1].properties.hostName

// Azure SQL, Key Vault and Storage, each reachable only through a private endpoint,
// with access granted to the apps' managed identity through Azure RBAC (no keys or passwords).

param location string
param namePrefix string
@minLength(6)
param uniqueSuffix string
param tags object
param isProduction bool

param privateEndpointSubnetId string
param sqlDnsZoneId string
param keyVaultDnsZoneId string
param blobDnsZoneId string

@description('Principal ID of the user-assigned identity the web apps run as.')
param appIdentityPrincipalId string

@description('Object ID of the Entra ID group that administers Azure SQL.')
param sqlAdminGroupObjectId string

@description('Display name of the Entra ID group that administers Azure SQL.')
param sqlAdminGroupName string

@description('Optional public IP allowed through the SQL firewall, only for the one-time database user setup. Leave empty to keep SQL fully private.')
param sqlClientIpAddress string = ''

// Built-in role definition IDs
var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultCryptoUser: '12338af0-0e69-4776-bea7-57ae8d297424'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

// ---------- Azure SQL ----------

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: 'sql-${namePrefix}-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: empty(sqlClientIpAddress) ? 'Disabled' : 'Enabled'
    // Entra ID only: no SQL logins or passwords exist on this server.
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlAdminGroupName
      sid: sqlAdminGroupObjectId
      principalType: 'Group'
      tenantId: subscription().tenantId
    }
  }
}

resource sqlFirewallClient 'Microsoft.Sql/servers/firewallRules@2023-08-01' = if (!empty(sqlClientIpAddress)) {
  parent: sqlServer
  name: 'one-time-admin-setup'
  properties: {
    startIpAddress: sqlClientIpAddress
    endIpAddress: sqlClientIpAddress
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: 'sqldb-contoso'
  location: location
  tags: tags
  // Dev: serverless, pauses when idle. Prod: provisioned General Purpose, zone redundant.
  sku: isProduction ? {
    name: 'GP_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  } : {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    zoneRedundant: isProduction
    autoPauseDelay: isProduction ? -1 : 60
    minCapacity: isProduction ? null : json('0.5')
    requestedBackupStorageRedundancy: isProduction ? 'Geo' : 'Local'
  }
}

resource sqlAuditing 'Microsoft.Sql/servers/auditingSettings@2023-08-01' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
  }
}

// ---------- Key Vault ----------

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${take(namePrefix, 12)}-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    // Data plane is private. Operators add secrets from the portal after adding their
    // client IP under Networking, or from a machine on the VNet.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Key that encrypts the ASP.NET Core Data Protection key ring at rest.
resource dataProtectionKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: 'dataprotection'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
  }
}

// ---------- Storage (Data Protection key ring) ----------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${replace(take(namePrefix, 12), '-', '')}${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: isProduction ? 'Standard_ZRS' : 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource dataProtectionContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'dataprotection'
  properties: {
    publicAccess: 'None'
  }
}

// ---------- Private endpoints ----------

var privateEndpoints = [
  {
    name: 'sql'
    resourceId: sqlServer.id
    groupId: 'sqlServer'
    dnsZoneId: sqlDnsZoneId
  }
  {
    name: 'kv'
    resourceId: keyVault.id
    groupId: 'vault'
    dnsZoneId: keyVaultDnsZoneId
  }
  {
    name: 'blob'
    resourceId: storage.id
    groupId: 'blob'
    dnsZoneId: blobDnsZoneId
  }
]

resource endpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for pe in privateEndpoints: {
  name: 'pe-${namePrefix}-${pe.name}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: pe.name
        properties: {
          privateLinkServiceId: pe.resourceId
          groupIds: [
            pe.groupId
          ]
        }
      }
    ]
  }
}]

resource endpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (pe, i) in privateEndpoints: {
  parent: endpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: pe.name
        properties: {
          privateDnsZoneId: pe.dnsZoneId
        }
      }
    ]
  }
}]

// ---------- RBAC for the app identity ----------

resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appIdentityPrincipalId, roles.keyVaultSecretsUser)
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
  }
}

resource kvCryptoUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appIdentityPrincipalId, roles.keyVaultCryptoUser)
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultCryptoUser)
  }
}

resource blobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataProtectionContainer
  name: guid(dataProtectionContainer.id, appIdentityPrincipalId, roles.storageBlobDataContributor)
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
  }
}

output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output dataProtectionKeyUri string = dataProtectionKey.properties.keyUri
output dataProtectionBlobUri string = '${storage.properties.primaryEndpoints.blob}${dataProtectionContainer.name}/keys.xml'

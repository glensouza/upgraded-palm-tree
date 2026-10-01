// Virtual network for App Service VNet integration and private endpoints, plus the
// private DNS zones that make SQL, Key Vault and Blob resolve to private IPs.

param location string
param namePrefix string
param tags object

@description('Address space for the virtual network.')
param addressPrefix string = '10.20.0.0/16'

var privateDnsZoneNames = [
  'privatelink${environment().suffixes.sqlServerHostname}' // privatelink.database.windows.net
  'privatelink.vaultcore.azure.net'
  'privatelink.blob.${environment().suffixes.storage}'
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namePrefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        // Outbound traffic from the web apps enters the VNet here.
        name: 'snet-app'
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 24, 1)
          delegations: [
            {
              name: 'appservice'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 24, 2)
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in privateDnsZoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in privateDnsZoneNames: {
  parent: dnsZones[i]
  name: 'link-${vnet.name}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

output vnetId string = vnet.id
output appSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
output sqlDnsZoneId string = dnsZones[0].id
output keyVaultDnsZoneId string = dnsZones[1].id
output blobDnsZoneId string = dnsZones[2].id

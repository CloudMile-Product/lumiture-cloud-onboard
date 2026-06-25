// Export storage account + container (resource-group scope)

@description('Globally-unique storage account name (3-24 lowercase chars).')
param storageAccountName string

@description('Blob container for exports. Must match the LumiTure copy-function (reads container "billing-export").')
param containerName string = 'billing-export'

@description('Region.')
param location string = 'eastasia'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: containerName
}

output storageAccountId string = storageAccount.id

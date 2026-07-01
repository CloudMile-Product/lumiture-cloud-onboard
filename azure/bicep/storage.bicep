// Export storage account + container (resource-group scope)

@description('Globally-unique storage account name (3-24 lowercase chars).')
param storageAccountName string

@description('Blob container for exports. Must match the LumiTure copy-function (reads container "billing-export").')
param containerName string = 'billing-export'

@description('Region.')
param location string = 'eastasia'

@description('Auto-delete export blobs older than this many days (0 disables the lifecycle rule). Keeps storage cost flat + bounds the never-deduplicated daily exports.')
param retentionDays int = 180

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

// Lifecycle: the daily exports never de-duplicate, so auto-delete blobs older than
// retentionDays to keep cost flat (LumiTure copies each blob on creation).
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = if (retentionDays > 0) {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'lumiture-export-retention'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ '${containerName}/cost/' ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: retentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

output storageAccountId string = storageAccount.id

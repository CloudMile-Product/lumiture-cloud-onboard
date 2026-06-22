// Storage Blob Data Reader assignment on the export storage account
// (resource-group scope; role assignment is scoped to the storage account)

@description('Storage account that holds the cost export.')
param storageAccountName string

@description('Object (principal) ID of LumiTure\'s consented service principal.')
param lumitureSpObjectId string

@description('Role definition ID (GUID) to assign — Storage Blob Data Reader.')
param roleDefinitionId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource blobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, lumitureSpObjectId, roleDefinitionId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: lumitureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

// LumiTure Azure Onboarding — Bicep module
//
// Declarative alternative to the bash / Cloud Shell flow. Grants the LumiTure
// service principal the two read roles and creates the daily cost export.
// Same end state as init.sh.
//
// PREREQUISITE (browser, un-scriptable): LumiTure's multi-tenant SP must already
// be consented in this tenant (done via the LumiTure "Connect Azure" wizard).
// Pass its objectId as lumitureSpObjectId.
//
// Deploy at subscription scope:
//   az deployment sub create \
//     --location eastasia \
//     --template-file main.bicep \
//     --parameters lumitureSpObjectId=<sp-object-id> \
//                  storageResourceGroup=lumiture-billing-rg \
//                  storageAccountName=lumitureexport123

targetScope = 'subscription'

@description('Object (principal) ID of LumiTure\'s consented service principal in this tenant.')
param lumitureSpObjectId string

@description('Resource group to hold the export storage account (created if absent).')
param storageResourceGroup string

@description('Globally-unique storage account name for the cost export (3-24 lowercase chars).')
param storageAccountName string

@description('Blob container for exports. Must match the LumiTure copy-function (reads container "billing-export").')
param containerName string = 'billing-export'

@description('Region for created resources.')
param location string = 'eastasia'

@description('Cost Management export name. Forms the path segment under rootFolder; the copy-function reads cost/daily-actual-cost/.')
param exportName string = 'daily-actual-cost'

@description('Auto-delete export blobs older than this many days (0 disables). Keeps the client storage cost flat since the daily exports never de-duplicate.')
param exportRetentionDays int = 180

@description('Recurrence start for the export schedule. Azure requires this to be in the future at deploy time, so it defaults to one day out (utcNow() is only valid as a param default). Do not hardcode a literal — a fixed date eventually fails validation.')
param exportFromDate string = dateTimeAdd(utcNow(), 'P1D')

@description('LumiTure billing event-trigger webhook URL (env-specific — from the wizard/API). This wires the data path (Event Grid BlobCreated → LumiTure). Leave empty to skip it, but billing data will NOT flow until the Event Grid subscription exists.')
param eventTriggerUrl string = ''

@description('Event Grid subscription name.')
param eventSubscriptionName string = 'lumiture-billing-export'

// Built-in role definition IDs (stable across tenants)
var costManagementReaderRoleId = '72fafb9e-0641-4937-9268-a91bfd8191a3' // Cost Management Reader
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' // Storage Blob Data Reader

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: storageResourceGroup
  location: location
}

module storage 'storage.bicep' = {
  name: 'lumiture-export-storage'
  scope: rg
  params: {
    storageAccountName: storageAccountName
    containerName: containerName
    location: location
    retentionDays: exportRetentionDays
  }
}

// Subscription-scope: Cost Management Reader to LumiTure SP
resource costReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, lumitureSpObjectId, costManagementReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', costManagementReaderRoleId)
    principalId: lumitureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Reader on the export storage account, granted in the RG module
module blobReader 'role-storage.bicep' = {
  name: 'lumiture-blob-reader'
  scope: rg
  params: {
    storageAccountName: storageAccountName
    lumitureSpObjectId: lumitureSpObjectId
    roleDefinitionId: storageBlobDataReaderRoleId
  }
  dependsOn: [ storage ]
}

// Daily ActualCost export at subscription scope
resource export 'Microsoft.CostManagement/exports@2023-08-01' = {
  name: exportName
  properties: {
    schedule: {
      status: 'Active'
      recurrence: 'Daily'
      recurrencePeriod: {
        from: exportFromDate
        to: '2030-12-31T00:00:00Z'
      }
    }
    format: 'Csv'
    deliveryInfo: {
      destination: {
        resourceId: storage.outputs.storageAccountId
        container: containerName
        rootFolderPath: 'cost'
      }
    }
    definition: {
      type: 'ActualCost'
      timeframe: 'MonthToDate'
      dataSet: {
        granularity: 'Daily'
      }
    }
  }
}

// Phase 2.7 — Event Grid subscription (billing DATA path). Only wired when an
// event-trigger URL is supplied; without it the export is created but data won't flow.
module eventGrid 'eventgrid.bicep' = if (!empty(eventTriggerUrl)) {
  name: 'lumiture-eventgrid'
  scope: rg
  params: {
    storageAccountName: storageAccountName
    eventTriggerUrl: eventTriggerUrl
    eventSubscriptionName: eventSubscriptionName
    location: location
  }
  dependsOn: [ storage, export ]
}

output storageAccountId string = storage.outputs.storageAccountId
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
output eventSubscriptionWired bool = !empty(eventTriggerUrl)

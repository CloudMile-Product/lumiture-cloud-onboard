// Event Grid system topic + BlobCreated → LumiTure webhook (resource-group scope)
//
// This is the billing DATA path: without it LumiTure never sees the export blobs.
// The customer's storage fires Microsoft.Storage.BlobCreated → this subscription
// delivers to LumiTure's billing-event function, which ingests the export.
//
// The webhook endpoint must answer Event Grid's validation handshake, so it has to
// be the real LumiTure function URL (a placeholder fails deployment).

@description('Storage account the cost export lands in (the event source).')
param storageAccountName string

@description('LumiTure billing event-trigger webhook URL (env-specific — from the wizard/API).')
param eventTriggerUrl string

@description('Event Grid subscription name.')
param eventSubscriptionName string = 'lumiture-billing-export'

@description('Region for the system topic.')
param location string = 'eastasia'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource systemTopic 'Microsoft.EventGrid/systemTopics@2022-06-15' = {
  name: '${storageAccountName}-egst'
  location: location
  properties: {
    source: storageAccount.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2022-06-15' = {
  parent: systemTopic
  name: eventSubscriptionName
  properties: {
    destination: {
      endpointType: 'WebHook'
      properties: {
        endpointUrl: eventTriggerUrl
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
    }
  }
}

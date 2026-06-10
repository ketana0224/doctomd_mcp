// =============================================================================
// Storage Account (LRS, Entra-only) + 3 containers + lifecycle (7-day delete)
// =============================================================================

@description('Globally-unique storage account name (3-24 chars, lowercase)')
param accountName string
param location string
param tags object = {}

@description('Lifecycle: days before auto-delete of job-scoped blobs')
param ttlDays int = 7

var pdfCutContainerName = 'pdf-cut'
var cuMdContainerName = 'cu-md'
var figuresContainerName = 'figures'
var deployContainerName = 'app-package'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    defaultToOAuthAuthentication: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource pdfCut 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: pdfCutContainerName
  properties: { publicAccess: 'None' }
}

resource cuMd 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: cuMdContainerName
  properties: { publicAccess: 'None' }
}

resource figures 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: figuresContainerName
  properties: { publicAccess: 'None' }
}

resource deployPkg 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deployContainerName
  properties: { publicAccess: 'None' }
}

// 7-day lifecycle for the 3 working containers
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'auto-delete-job-blobs'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [
                pdfCutContainerName
                cuMdContainerName
                figuresContainerName
              ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: ttlDays
                }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [
    pdfCut
    cuMd
    figures
  ]
}

output accountId string = sa.id
output accountName string = sa.name
output pdfCutContainerName string = pdfCutContainerName
output cuMdContainerName string = cuMdContainerName
output figuresContainerName string = figuresContainerName
output deployContainerName string = deployContainerName

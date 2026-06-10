// =============================================================================
// RBAC: Function MI -> Storage Account (Blob Data Owner)
// 'Owner' を選んだのは、AzureWebJobsStorage (deployment + host) と業務 Blob
// (pdf-cut/cu-md/figures) の両方で書込・削除を行うため。
// =============================================================================

param storageAccountName string
param functionPrincipalId string

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Storage Blob Data Owner
var blobOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

resource raBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sa
  name: guid(sa.id, functionPrincipalId, blobOwnerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobOwnerRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

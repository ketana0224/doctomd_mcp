// =============================================================================
// RBAC: Function MI -> AI Foundry account + Foundry project
//   account scope:
//     - Cognitive Services User          : Content Understanding 用
//     - Cognitive Services OpenAI User   : Azure OpenAI 推論 (account level)
//   project scope:
//     - Azure AI User                    : Foundry project endpoint
//                                          (Responses API / Agents) アクセス用
// =============================================================================

param aiFoundryAccountName string
param foundryProjectName string
param functionPrincipalId string

resource ai 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: aiFoundryAccountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: ai
  name: foundryProjectName
}

// Cognitive Services User
var csUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
// Cognitive Services OpenAI User
var aoaiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
// Azure AI User
var aiUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

// ---- account scope ---------------------------------------------------------

resource raCs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ai
  name: guid(ai.id, functionPrincipalId, csUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', csUserRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ai
  name: guid(ai.id, functionPrincipalId, aoaiUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aoaiUserRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- project scope (Foundry project endpoint 用) --------------------------

resource raProjectAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, functionPrincipalId, aiUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiUserRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

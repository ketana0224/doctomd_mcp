// =============================================================================
// MCP PDF Function (Flex Consumption) - Main orchestrator
//   AI Foundry も同じ RG に新規作成する
// =============================================================================

targetScope = 'resourceGroup'

@description('Environment name (azd-managed, used for resource naming)')
param environmentName string

@description('Primary region for all resources')
param location string = resourceGroup().location

@description('GPT モデル deployment 名 (AOAI_GA_DEPLOYMENT として注入)')
param aoaiGaDeployment string = 'gpt-5.4'

@description('GPT モデル名 (Foundry catalog)')
param aoaiModelName string = 'gpt-5.4'

@description('GPT モデルバージョン (gpt-5.4 GA = 2026-03-05)')
param aoaiModelVersion string = '2026-03-05'

@description('GPT モデル SKU')
param aoaiModelSku string = 'GlobalStandard'

@description('GPT モデル容量 (千 TPM 単位)。サブスクリプション quota に合わせて調整')
param aoaiModelCapacity int = 10

@description('Foundry project 名')
param foundryProjectName string = 'proj-mcp'

@description('Hard limit on accepted PDF size (bytes)')
param maxPdfBytes int = 52428800

// Deterministic, environment-scoped suffix for globally-unique names.
var rgSuffix = uniqueString(resourceGroup().id, environmentName)
var nameSuffix = take(toLower(replace(rgSuffix, '-', '')), 8)

var storageAccountName = take('stmcp${nameSuffix}', 24)
var functionAppName = 'func-mcp-${nameSuffix}'
var planName = 'plan-mcp-${nameSuffix}'
var laName = 'log-mcp-${nameSuffix}'
var aiName = 'appi-mcp-${nameSuffix}'
var aiFoundryName = 'aif-mcp-${nameSuffix}'

var tags = {
  'azd-env-name': environmentName
  workload: 'mcp-pdf'
}

// ---------------------------------------------------------------------------
// Storage Account (Blob only, MI-auth, 3 containers with lifecycle)
// ---------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    accountName: storageAccountName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// AI Foundry (Content Understanding + Azure OpenAI)
// ---------------------------------------------------------------------------
module aiFoundry 'modules/aiFoundry.bicep' = {
  name: 'aiFoundry'
  params: {
    accountName: aiFoundryName
    location: location
    tags: tags
    projectName: foundryProjectName
    gptDeploymentName: aoaiGaDeployment
    gptModelName: aoaiModelName
    gptModelVersion: aoaiModelVersion
    gptSku: aoaiModelSku
    gptCapacity: aoaiModelCapacity
  }
}

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: laName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Function App (Flex Consumption, Python 3.11, System-assigned MI)
// ---------------------------------------------------------------------------
module function 'modules/function.bicep' = {
  name: 'function'
  params: {
    functionAppName: functionAppName
    planName: planName
    location: location
    tags: tags
    storageAccountName: storage.outputs.accountName
    storageAccountId: storage.outputs.accountId
    deployContainerName: storage.outputs.deployContainerName
    appInsightsConnectionString: appInsights.properties.ConnectionString
    aiFoundryEndpoint: aiFoundry.outputs.foundryEndpoint
    aoaiEndpoint: aiFoundry.outputs.aoaiEndpoint
    foundryProjectEndpoint: aiFoundry.outputs.projectEndpoint
    aoaiGaDeployment: aiFoundry.outputs.gptDeploymentName
    blobAccountUrl: 'https://${storage.outputs.accountName}.blob.core.windows.net'
    pdfCutContainer: storage.outputs.pdfCutContainerName
    cuMdContainer: storage.outputs.cuMdContainerName
    figuresContainer: storage.outputs.figuresContainerName
    maxPdfBytes: maxPdfBytes
  }
}

// ---------------------------------------------------------------------------
// RBAC: Function MI -> Storage (Blob Data Owner) + AI Foundry (CS / AOAI User)
// ---------------------------------------------------------------------------
module roles 'modules/roleAssignments.bicep' = {
  name: 'roles'
  params: {
    storageAccountName: storage.outputs.accountName
    functionPrincipalId: function.outputs.principalId
  }
}

module rolesAi 'modules/roleAssignmentsAi.bicep' = {
  name: 'rolesAi'
  params: {
    aiFoundryAccountName: aiFoundry.outputs.accountName
    foundryProjectName: aiFoundry.outputs.projectName
    functionPrincipalId: function.outputs.principalId
  }
}

// ---------------------------------------------------------------------------
// Outputs (azd reads these into .env)
// ---------------------------------------------------------------------------
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output FUNCTION_APP_NAME string = function.outputs.functionAppName
output FUNCTION_APP_HOSTNAME string = function.outputs.defaultHostName
output BLOB_ACCOUNT_URL string = 'https://${storage.outputs.accountName}.blob.core.windows.net'
output STORAGE_ACCOUNT_NAME string = storage.outputs.accountName
output AI_FOUNDRY_ACCOUNT_NAME string = aiFoundry.outputs.accountName
output AI_FOUNDRY_PROJECT_NAME string = aiFoundry.outputs.projectName
output AZURE_CONTENT_UNDERSTANDING_ENDPOINT string = aiFoundry.outputs.foundryEndpoint
output AZURE_OPENAI_API_ENDPOINT string = aiFoundry.outputs.aoaiEndpoint
output AZURE_FOUNDRY_PROJECT_ENDPOINT string = aiFoundry.outputs.projectEndpoint
output AOAI_GA_DEPLOYMENT string = aiFoundry.outputs.gptDeploymentName
output APPINSIGHTS_CONNECTION_STRING string = appInsights.properties.ConnectionString

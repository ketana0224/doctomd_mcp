// =============================================================================
// Azure AI Foundry account (AIServices kind) + Foundry project + GPT model
//   - Content Understanding: account レベル endpoint で利用
//   - Azure OpenAI: Foundry project endpoint 経由で azure-ai-projects SDK から
//     アクセス可能 (project endpoint で Responses / Chat Completions API を提供)
// =============================================================================

param accountName string
param location string
param tags object = {}

@description('Foundry project 名 (account 配下の child resource)')
param projectName string = 'proj-mcp'

@description('Deployment 名 (アプリから AOAI_GA_DEPLOYMENT として参照)')
param gptDeploymentName string = 'gpt-5.4'

@description('OpenAI モデル名 (Foundry catalog)')
param gptModelName string = 'gpt-5.4'

@description('モデルバージョン (gpt-5.4 GA = 2026-03-05)')
param gptModelVersion string = '2026-03-05'

@description('SKU 名 (GlobalStandard / Standard / DataZoneStandard など)')
param gptSku string = 'GlobalStandard'

@description('TPM (千単位)。サブスクリプション quota に合わせて調整')
param gptCapacity int = 10

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    disableLocalAuth: true
    // Foundry project を作成可能にする (新世代 Foundry 必須)
    allowProjectManagement: true
  }
}

// Foundry project (新世代の管理単位 - Responses API / Agents / Tools の基点)
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'MCP PDF Project'
    description: 'PDF understanding pipeline (Content Understanding + GPT vision)'
  }
}

// gpt model deployment (account レベル — project からは inherit される)
resource gptDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: gptDeploymentName
  sku: {
    name: gptSku
    capacity: gptCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: gptModelName
      version: gptModelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

output accountName string = account.name
output accountId string = account.id
output projectName string = project.name
output projectId string = project.id
// Foundry resource (account) レベル endpoint - Content Understanding 用
output foundryEndpoint string = 'https://${accountName}.services.ai.azure.com/'
// AOAI レガシー endpoint (互換用に残す)
output aoaiEndpoint string = 'https://${accountName}.services.ai.azure.com/openai/v1'
// Foundry project endpoint - Foundry SDK (azure-ai-projects) で使う
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output gptDeploymentName string = gptDeployment.name

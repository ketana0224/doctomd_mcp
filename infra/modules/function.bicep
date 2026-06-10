// =============================================================================
// Function App (Flex Consumption, Python 3.11, System-assigned MI, MI-backed
// AzureWebJobsStorage)
// =============================================================================

param functionAppName string
param planName string
param location string
param tags object = {}

param storageAccountName string
param storageAccountId string
param deployContainerName string

param appInsightsConnectionString string
param aiFoundryEndpoint string
param aoaiEndpoint string
param foundryProjectEndpoint string
param aoaiGaDeployment string
param blobAccountUrl string
param pdfCutContainer string
param cuMdContainer string
param figuresContainer string

param maxPdfBytes int = 52428800

// Flex Consumption hosting plan
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: union(tags, {
    'azd-service-name': 'api'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${blobAccountUrl}/${deployContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }

        { name: 'BLOB_ACCOUNT_URL', value: blobAccountUrl }
        { name: 'BLOB_CONTAINER_PDFCUT', value: pdfCutContainer }
        { name: 'BLOB_CONTAINER_CUMD', value: cuMdContainer }
        { name: 'BLOB_CONTAINER_FIGURES', value: figuresContainer }

        { name: 'AZURE_CONTENT_UNDERSTANDING_ENDPOINT', value: aiFoundryEndpoint }
        { name: 'AZURE_CONTENT_UNDERSTANDING_API_VERSION', value: '2025-11-01' }
        { name: 'AZURE_OPENAI_API_ENDPOINT', value: aoaiEndpoint }
        { name: 'AZURE_FOUNDRY_PROJECT_ENDPOINT', value: foundryProjectEndpoint }
        { name: 'AOAI_GA_DEPLOYMENT', value: aoaiGaDeployment }

        { name: 'MAX_PDF_BYTES', value: string(maxPdfBytes) }
      ]
    }
  }
}

output functionAppName string = site.name
output defaultHostName string = site.properties.defaultHostName
output principalId string = site.identity.principalId

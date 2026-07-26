<#
.SYNOPSIS
    Cliente NerdGraph e resolucao idempotente de recursos.

.DESCRIPTION
    Carregado por dot-source.

    Um 200 com "errors" no corpo e falha silenciosa: a NerdGraph responde
    HTTP 200 mesmo quando a operacao nao aconteceu. Toda chamada verifica o campo
    errors antes de devolver.
#>

Set-StrictMode -Version Latest

function New-NerdGraphContext {
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [ValidateSet('US', 'EU')][string]$Region = 'US'
    )

    $endpoint = if ($Region -eq 'EU') { 'https://api.eu.newrelic.com/graphql' } else { 'https://api.newrelic.com/graphql' }

    return [pscustomobject]@{
        AccountId = $AccountId
        ApiKey    = $ApiKey
        Endpoint  = $endpoint
        Region    = $Region
    }
}

function Invoke-NerdGraph {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [hashtable]$Variables,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    $body = @{ query = $Query }
    if ($null -ne $Variables) { $body['variables'] = $Variables }
    $json = $body | ConvertTo-Json -Depth 25 -Compress

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Invoke-RestMethod `
                -Uri $Context.Endpoint `
                -Method Post `
                -Headers @{ 'API-Key' = $Context.ApiKey; 'Content-Type' = 'application/json' } `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
                -TimeoutSec 60
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw "NerdGraph inacessivel apos $attempt tentativa(s): $($_.Exception.Message)"
            }
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }

        if ($null -ne $response.PSObject.Properties['errors'] -and $null -ne $response.errors) {
            $mensagens = @($response.errors | ForEach-Object {
                    if ($null -ne $_.PSObject.Properties['message']) { $_.message } else { ($_ | ConvertTo-Json -Compress) }
                })
            # Nunca ecoar a chave: a mensagem de erro pode conter o corpo enviado.
            throw "NerdGraph devolveu errors: $($mensagens -join ' | ')"
        }

        return $response
    }
}

function Assert-NoMutationErrors {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($null -eq $Payload) {
        throw "$Label nao retornou payload."
    }

    if ($null -ne $Payload.PSObject.Properties['errors'] -and $null -ne $Payload.errors -and @($Payload.errors).Count -gt 0) {
        $mensagens = @($Payload.errors | ForEach-Object { "$($_.type): $($_.description)" })
        throw "$Label falhou: $($mensagens -join ' | ')"
    }
}

<#
Resolve entidade por nome estavel com contagem explicita.

0 resultados  -> devolve null (criar)
1 resultado   -> devolve a entidade (atualizar por GUID)
>1 resultados -> reprova e lista os GUIDs

Nunca devolver o primeiro de varios: buscar so por nome nao distingue duplicidade
deixada por execucao anterior, e atualizar arbitrariamente esconderia o problema.
#>
function Find-SingleEntity {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $response = Invoke-NerdGraph -Context $Context -Query @'
query($query: String!) {
  actor { entitySearch(query: $query) { results { entities { guid name entityType } } } }
}
'@ -Variables @{ query = $Query }

    $entities = @($response.data.actor.entitySearch.results.entities)
    if ($entities.Count -eq 0) { return $null }
    if ($entities.Count -eq 1) { return $entities[0] }

    $guids = ($entities | ForEach-Object { $_.guid }) -join ', '
    throw "$Label duplicado para a busca [$Query]. GUIDs: $guids. Remover a duplicidade antes de reexecutar; atualizar o primeiro resultado esconderia o problema."
}

function Set-NrqlCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)]$Condition,
        [switch]$UseFallback
    )

    $query = $Condition.nrql
    if ($UseFallback -and $null -ne $Condition.PSObject.Properties['nrqlFallback']) {
        # A escolha entre Metric e Span e automatica, decidida pelo gate de
        # semantica HTTP; nao existe decisao manual aqui.
        $query = $Condition.nrqlFallback
    }

    # $input e variavel automatica do PowerShell: sobrescreve-la dentro de uma
    # funcao mascara o enumerador do pipeline.
    $conditionInput = @{
        name    = $Condition.name
        enabled = $true
        nrql    = @{ query = $query }
        signal  = @{
            aggregationMethod = $Condition.aggregationMethod
            aggregationWindow = [int]$Condition.aggregationWindow
        }
    }

    if ($null -ne $Condition.PSObject.Properties['aggregationDelay']) {
        $conditionInput.signal['aggregationDelay'] = [int]$Condition.aggregationDelay
    }

    if ($null -ne $Condition.PSObject.Properties['lossOfSignal']) {
        # Loss of signal, e nao threshold: o problema e a ausencia de dado, e um
        # threshold sobre serie vazia nunca dispararia.
        $conditionInput['expiration'] = @{
            expirationDuration          = [int]$Condition.lossOfSignal.expirationDuration
            openViolationOnExpiration   = [bool]$Condition.lossOfSignal.openViolationOnExpiration
            closeViolationsOnExpiration = [bool]$Condition.lossOfSignal.closeViolationsOnExpiration
        }
    }
    else {
        $conditionInput['terms'] = @(@{
                threshold            = [double]$Condition.criticalThreshold
                thresholdDuration    = [int]$Condition.thresholdDuration
                thresholdOccurrences = $Condition.thresholdOccurrences
                operator             = $Condition.operator
                priority             = 'CRITICAL'
            })
    }

    $existing = Find-SingleNrqlCondition -Context $Context -PolicyId $PolicyId -Name $Condition.name

    if ($null -eq $existing) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $policyId: ID!, $condition: AlertsNrqlConditionStaticInput!) {
  alertsNrqlConditionStaticCreate(accountId: $accountId, policyId: $policyId, condition: $condition) { id name }
}
'@ -Variables @{ accountId = [int]$Context.AccountId; policyId = $PolicyId; condition = $conditionInput }
        return [pscustomobject]@{ Guid = $created.data.alertsNrqlConditionStaticCreate.id; Action = 'created' }
    }

    $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $id: ID!, $condition: AlertsNrqlConditionUpdateStaticInput!) {
  alertsNrqlConditionStaticUpdate(accountId: $accountId, id: $id, condition: $condition) { id name }
}
'@ -Variables @{ accountId = [int]$Context.AccountId; id = $existing.id; condition = $conditionInput }
    return [pscustomobject]@{ Guid = $updated.data.alertsNrqlConditionStaticUpdate.id; Action = 'updated' }
}

<#
Busca condicao por nome E policyId.

Buscar so por nome nao serve: o mesmo nome pode existir em outra policy, e a
condicao precisa pertencer a policy correta para a notificacao funcionar.
#>
function Find-SingleNrqlCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $response = Invoke-NerdGraph -Context $Context -Query @'
query($accountId: Int!, $name: String!) {
  actor { account(id: $accountId) { alerts {
    nrqlConditionsSearch(searchCriteria: {nameLike: $name}) {
      nrqlConditions { id name policyId }
    }
  } } }
}
'@ -Variables @{ accountId = [int]$Context.AccountId; name = $Name }

    $matches = @($response.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions |
        Where-Object { $_.name -eq $Name -and [string]$_.policyId -eq [string]$PolicyId })

    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -eq 1) { return $matches[0] }

    $ids = ($matches | ForEach-Object { $_.id }) -join ', '
    throw "Condicao '$Name' duplicada na policy $PolicyId. IDs: $ids. Remover a duplicidade antes de reexecutar."
}

function Set-SyntheticCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)]$Condition,
        [Parameter(Mandatory = $true)][string]$MonitorGuid
    )

    # Tres falhas consecutivas por localizacao e o comportamento nativo do
    # Synthetic Monitor. O enunciado pede duas; o desvio esta registrado no
    # relatorio de implementacao, porque duas exigiria uma condicao NRQL paralela
    # sobre SyntheticCheck, duplicando a fonte do mesmo alerta.
    $conditionInput = @{
        name                      = $Condition.name
        enabled                   = $true
        entities                  = @($MonitorGuid)
        terms                     = @(@{ priority = 'CRITICAL'; threshold = [int]$Condition.criticalThreshold })
        violationTimeLimitSeconds = [int]$Condition.violationTimeLimitSeconds
    }

    $existing = Find-SingleLocationCondition -Context $Context -PolicyId $PolicyId -Name $Condition.name

    if ($null -eq $existing) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $policyId: ID!, $condition: AlertsSyntheticsMultiLocationConditionInput!) {
  alertsSyntheticsMultiLocationConditionCreate(accountId: $accountId, policyId: $policyId, condition: $condition) { id name }
}
'@ -Variables @{
            accountId = [int]$Context.AccountId
            policyId  = $PolicyId
            condition = $conditionInput
        }
        return [pscustomobject]@{ Guid = $created.data.alertsSyntheticsMultiLocationConditionCreate.id; Action = 'created' }
    }

    $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $id: ID!, $condition: AlertsSyntheticsMultiLocationConditionUpdateInput!) {
  alertsSyntheticsMultiLocationConditionUpdate(accountId: $accountId, id: $id, condition: $condition) { id name }
}
'@ -Variables @{
        accountId = [int]$Context.AccountId
        id        = $existing.id
        condition = $conditionInput
    }
    return [pscustomobject]@{ Guid = $updated.data.alertsSyntheticsMultiLocationConditionUpdate.id; Action = 'updated' }
}

function Find-SingleLocationCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $response = Invoke-NerdGraph -Context $Context -Query @'
query($accountId: Int!, $policyId: ID!) {
  actor { account(id: $accountId) { alerts {
    syntheticsMultiLocationConditionsSearch(searchCriteria: {policyId: $policyId}) {
      conditions { id name policyId }
    }
  } } }
}
'@ -Variables @{ accountId = [int]$Context.AccountId; policyId = $PolicyId } -MaxAttempts 1

    $conditions = @($response.data.actor.account.alerts.syntheticsMultiLocationConditionsSearch.conditions |
        Where-Object { $_.name -eq $Name })

    if ($conditions.Count -eq 0) { return $null }
    if ($conditions.Count -eq 1) { return $conditions[0] }

    $ids = ($conditions | ForEach-Object { $_.id }) -join ', '
    throw "Condicao de Synthetic '$Name' duplicada na policy $PolicyId. IDs: $ids."
}

<#
Destination -> Channel -> Workflow.

Provisionar a policy e o monitor nao basta: sem a cadeia completa o incidente
aparece na UI e nao vira e-mail.
#>
function Set-NotificationChain {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Email,
        [Parameter(Mandatory = $true)][string]$PolicyId
    )

    $destinations = Invoke-NerdGraph -Context $Context -Query @'
query($accountId: Int!) {
  actor { account(id: $accountId) { aiNotifications {
    destinations { entities { id name type } }
  } } }
}
'@ -Variables @{ accountId = [int]$Context.AccountId }

    $existingDestinations = @($destinations.data.actor.account.aiNotifications.destinations.entities |
        Where-Object { $_.name -eq $Name })
    if ($existingDestinations.Count -gt 1) {
        throw "Destination '$Name' duplicado. IDs: $(($existingDestinations | ForEach-Object { $_.id }) -join ', ')."
    }

    $destinationProperties = @(@{ key = 'email'; value = $Email })

    if ($existingDestinations.Count -eq 0) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $destination: AiNotificationsDestinationInput!) {
  aiNotificationsCreateDestination(accountId: $accountId, destination: $destination) {
    destination { id name }
    errors { description type }
  }
}
'@ -Variables @{
            accountId   = [int]$Context.AccountId
            destination = @{ name = $Name; type = 'EMAIL'; properties = $destinationProperties }
        }
        Assert-NoMutationErrors -Payload $created.data.aiNotificationsCreateDestination -Label 'aiNotificationsCreateDestination'
        $destinationId = $created.data.aiNotificationsCreateDestination.destination.id
        $destinationAction = 'created'
    }
    else {
        $destinationId = $existingDestinations[0].id
        $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $destinationId: ID!, $destination: AiNotificationsDestinationUpdate!) {
  aiNotificationsUpdateDestination(accountId: $accountId, destinationId: $destinationId, destination: $destination) {
    destination { id name }
    errors { description type }
  }
}
'@ -Variables @{
            accountId     = [int]$Context.AccountId
            destinationId = $destinationId
            destination   = @{ name = $Name; properties = $destinationProperties }
        }
        Assert-NoMutationErrors -Payload $updated.data.aiNotificationsUpdateDestination -Label 'aiNotificationsUpdateDestination'
        $destinationAction = 'updated'
    }

    $channels = Invoke-NerdGraph -Context $Context -Query @'
query($accountId: Int!) {
  actor { account(id: $accountId) { aiNotifications {
    channels { entities { id name destinationId } }
  } } }
}
'@ -Variables @{ accountId = [int]$Context.AccountId }

    $existingChannels = @($channels.data.actor.account.aiNotifications.channels.entities |
        Where-Object { $_.name -eq $Name })
    if ($existingChannels.Count -gt 1) {
        throw "Channel '$Name' duplicado. IDs: $(($existingChannels | ForEach-Object { $_.id }) -join ', ')."
    }

    $channelProperties = @(
        @{ key = 'subject'; value = '[FIAP Oficina] {{ issueTitle }}' }
    )

    if ($existingChannels.Count -eq 0) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $channel: AiNotificationsChannelInput!) {
  aiNotificationsCreateChannel(accountId: $accountId, channel: $channel) {
    channel { id name }
    errors { description type }
  }
}
'@ -Variables @{
            accountId = [int]$Context.AccountId
            channel   = @{
                name          = $Name
                type          = 'EMAIL'
                product       = 'IINT'
                destinationId = $destinationId
                properties    = $channelProperties
            }
        }
        Assert-NoMutationErrors -Payload $created.data.aiNotificationsCreateChannel -Label 'aiNotificationsCreateChannel'
        $channelId = $created.data.aiNotificationsCreateChannel.channel.id
        $channelAction = 'created'
    }
    else {
        $channelId = $existingChannels[0].id
        $channelAction = 'updated'
    }

    $workflows = Invoke-NerdGraph -Context $Context -Query @'
query($accountId: Int!) {
  actor { account(id: $accountId) { aiWorkflows {
    workflows { entities { id name } }
  } } }
}
'@ -Variables @{ accountId = [int]$Context.AccountId }

    $existingWorkflows = @($workflows.data.actor.account.aiWorkflows.workflows.entities |
        Where-Object { $_.name -eq $Name })
    if ($existingWorkflows.Count -gt 1) {
        throw "Workflow '$Name' duplicado. IDs: $(($existingWorkflows | ForEach-Object { $_.id }) -join ', ')."
    }

    # O filtro amarra o workflow a policy: sem ele o workflow existiria sem
    # relacao com os incidentes desta solucao.
    $issuesFilter = @{
        name       = "$Name - filtro"
        type       = 'FILTER'
        predicates = @(@{
                attribute = 'labels.policyIds'
                operator  = 'EXACTLY_MATCHES'
                values    = @([string]$PolicyId)
            })
    }

    if ($existingWorkflows.Count -eq 0) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $workflow: AiWorkflowsCreateWorkflowInput!) {
  aiWorkflowsCreateWorkflow(accountId: $accountId, createWorkflowData: $workflow) {
    workflow { id name }
    errors { description type }
  }
}
'@ -Variables @{
            accountId = [int]$Context.AccountId
            workflow  = @{
                name                  = $Name
                workflowEnabled       = $true
                destinationsEnabled   = $true
                issuesFilter          = $issuesFilter
                destinationConfigurations = @(@{ channelId = $channelId; notificationTriggers = @('ACTIVATED', 'CLOSED') })
                mutingRulesHandling   = 'NOTIFY_ALL_ISSUES'
            }
        }
        Assert-NoMutationErrors -Payload $created.data.aiWorkflowsCreateWorkflow -Label 'aiWorkflowsCreateWorkflow'
        $workflowId = $created.data.aiWorkflowsCreateWorkflow.workflow.id
        $workflowAction = 'created'
    }
    else {
        $workflowId = $existingWorkflows[0].id
        $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $id: ID!, $workflow: AiWorkflowsUpdateWorkflowInput!) {
  aiWorkflowsUpdateWorkflow(accountId: $accountId, id: $id, updateWorkflowData: $workflow) {
    workflow { id name }
    errors { description type }
  }
}
'@ -Variables @{
            accountId = [int]$Context.AccountId
            id        = $workflowId
            workflow  = @{
                id                    = $workflowId
                name                  = $Name
                workflowEnabled       = $true
                destinationsEnabled   = $true
                destinationConfigurations = @(@{ channelId = $channelId; notificationTriggers = @('ACTIVATED', 'CLOSED') })
            }
        }
        Assert-NoMutationErrors -Payload $updated.data.aiWorkflowsUpdateWorkflow -Label 'aiWorkflowsUpdateWorkflow'
        $workflowAction = 'updated'
    }

    return [pscustomobject]@{
        DestinationId     = $destinationId
        DestinationAction = $destinationAction
        ChannelId         = $channelId
        ChannelAction     = $channelAction
        WorkflowId        = $workflowId
        WorkflowAction    = $workflowAction
    }
}

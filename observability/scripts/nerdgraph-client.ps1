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

<#
Status HTTP da falha, quando existir.

Falha de transporte (DNS, TLS, timeout) nao tem status: e a ausencia dele que
distingue "nao chegou ao servidor" de "o servidor recusou".
#>
function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $response = $exception.PSObject.Properties['Response']
        if ($null -ne $response -and $null -ne $response.Value) {
            $status = $response.Value.PSObject.Properties['StatusCode']
            if ($null -ne $status -and $null -ne $status.Value) {
                try { return [int]$status.Value } catch { }
            }
        }
        $exception = $exception.InnerException
    }

    return $null
}

<#
So erro transitorio justifica nova tentativa: 401, 403 e 404 nao mudam de
resposta em cinco segundos, e insistir neles troca diagnostico imediato por
espera inutil.
#>
function Test-RetryableFailure {
    param($StatusCode)

    if ($null -eq $StatusCode) { return $true }
    if ($StatusCode -in @(408, 429)) { return $true }
    return $StatusCode -ge 500
}

<#
Mutation nao e reexecutada as cegas.

Um timeout de resposta pode ter chegado ao servidor: repetir criaria o segundo
dashboard, policy ou workflow, e a resolucao por nome da execucao seguinte
acusaria duplicidade que so sai com limpeza manual. Perder a execucao por um
erro transitorio custa um reexecutar; duplicar recurso custa intervencao no New
Relic. Query e leitura pura e continua sendo reexecutada.
#>
function Invoke-NerdGraph {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [hashtable]$Variables,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    if ($Query -match '(?m)^\s*mutation\b' -and -not $PSBoundParameters.ContainsKey('MaxAttempts')) {
        $MaxAttempts = 1
    }

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
            $status = Get-HttpStatusCode -ErrorRecord $_
            $descricao = if ($null -eq $status) { $_.Exception.Message } else { "HTTP ${status}: $($_.Exception.Message)" }

            if ($attempt -ge $MaxAttempts -or -not (Test-RetryableFailure -StatusCode $status)) {
                throw "NerdGraph inacessivel apos $attempt tentativa(s): $descricao"
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
        $mensagens = @($Payload.errors | ForEach-Object {
                $typename = if ($null -ne $_.PSObject.Properties['__typename']) { $_.__typename } else { '' }
                $type = if ($null -ne $_.PSObject.Properties['type']) { $_.type } else { '' }
                $description = if ($null -ne $_.PSObject.Properties['description']) { $_.description } else { '' }
                $message = if ($null -ne $_.PSObject.Properties['message']) { $_.message } else { '' }

                $prefix = if (-not [string]::IsNullOrWhiteSpace($type)) { $type } elseif (-not [string]::IsNullOrWhiteSpace($typename)) { $typename } else { 'erro' }
                $detail = if (-not [string]::IsNullOrWhiteSpace($description)) { $description } elseif (-not [string]::IsNullOrWhiteSpace($message)) { $message } else { ($_ | ConvertTo-Json -Compress) }
                "${prefix}: $detail"
            })
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

    $encontradas = @($response.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions |
        Where-Object { $_.name -eq $Name -and [string]$_.policyId -eq [string]$PolicyId })

    if ($encontradas.Count -eq 0) { return $null }
    if ($encontradas.Count -eq 1) { return $encontradas[0] }

    $ids = ($encontradas | ForEach-Object { $_.id }) -join ', '
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
'@ -Variables @{ accountId = [int]$Context.AccountId; policyId = $PolicyId }

    $conditions = @($response.data.actor.account.alerts.syntheticsMultiLocationConditionsSearch.conditions |
        Where-Object { $_.name -eq $Name })

    if ($conditions.Count -eq 0) { return $null }
    if ($conditions.Count -eq 1) { return $conditions[0] }

    $ids = ($conditions | ForEach-Object { $_.id }) -join ', '
    throw "Condicao de Synthetic '$Name' duplicada na policy $PolicyId. IDs: $ids."
}

<#
Percorre todas as paginas de uma listagem NerdGraph.

destinations, channels e workflows nao aceitam busca por nome nesta consulta:
devolvem a conta inteira, paginada. Parar na primeira pagina e falha silenciosa
de idempotencia -- com o recurso existente fora dela, a resolucao por nome
concluiria "nao existe" e criaria o segundo destination, channel ou workflow,
que a execucao seguinte acusaria como duplicidade.
#>
function Get-AllPages {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][hashtable]$Variables,
        [Parameter(Mandatory = $true)][scriptblock]$SelectPage,
        [ValidateRange(1, 200)][int]$MaxPages = 50
    )

    $entidades = @()
    $cursor = $null
    $pagina = 0

    do {
        $pagina++
        if ($pagina -gt $MaxPages) {
            throw "Listagem NerdGraph passou de $MaxPages paginas: o cursor nao esta avancando."
        }

        $variaveis = @{} + $Variables
        $variaveis['cursor'] = $cursor

        $resposta = Invoke-NerdGraph -Context $Context -Query $Query -Variables $variaveis
        $bloco = & $SelectPage $resposta

        $entidades += @($bloco.entities)
        $cursor = if ($null -ne $bloco.PSObject.Properties['nextCursor']) { [string]$bloco.nextCursor } else { '' }
    } while (-not [string]::IsNullOrWhiteSpace($cursor))

    return $entidades
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

    $destinations = Get-AllPages -Context $Context -Variables @{ accountId = [int]$Context.AccountId } -Query @'
query($accountId: Int!, $cursor: String) {
  actor { account(id: $accountId) { aiNotifications {
    destinations(cursor: $cursor) { nextCursor entities { id name type } }
  } } }
}
'@ -SelectPage { param($resposta) $resposta.data.actor.account.aiNotifications.destinations }

    $existingDestinations = @($destinations | Where-Object { $_.name -eq $Name })
    if ($existingDestinations.Count -gt 1) {
        throw "Destination '$Name' duplicado. IDs: $(($existingDestinations | ForEach-Object { $_.id }) -join ', ')."
    }

    $destinationProperties = @(@{ key = 'email'; value = $Email })

    if ($existingDestinations.Count -eq 0) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $destination: AiNotificationsDestinationInput!) {
  aiNotificationsCreateDestination(accountId: $accountId, destination: $destination) {
    destination { id name }
    errors { __typename }
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
    errors { __typename }
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

    $channels = Get-AllPages -Context $Context -Variables @{ accountId = [int]$Context.AccountId } -Query @'
query($accountId: Int!, $cursor: String) {
  actor { account(id: $accountId) { aiNotifications {
    channels(cursor: $cursor) { nextCursor entities { id name destinationId } }
  } } }
}
'@ -SelectPage { param($resposta) $resposta.data.actor.account.aiNotifications.channels }

    $existingChannels = @($channels | Where-Object { $_.name -eq $Name })
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
    errors { __typename }
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

    $workflows = Get-AllPages -Context $Context -Variables @{ accountId = [int]$Context.AccountId } -Query @'
query($accountId: Int!, $cursor: String) {
  actor { account(id: $accountId) { aiWorkflows {
    workflows(cursor: $cursor) {
      nextCursor
      entities { id name issuesFilter { id predicates { attribute values } } }
    }
  } } }
}
'@ -SelectPage { param($resposta) $resposta.data.actor.account.aiWorkflows.workflows }

    $existingWorkflows = @($workflows | Where-Object { $_.name -eq $Name })
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
    errors { __typename }
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

        # O update nao reescreve o issuesFilter, entao um workflow que deixou de
        # apontar para esta policy (policy recriada com outro id, filtro editado
        # na UI) continuaria existindo sem notificar nada. Reportar 'updated'
        # sobre uma cadeia que nao entrega e-mail e pior que reprovar aqui.
        $predicados = @()
        if ($null -ne $existingWorkflows[0].PSObject.Properties['issuesFilter'] -and $null -ne $existingWorkflows[0].issuesFilter) {
            $predicados = @($existingWorkflows[0].issuesFilter.predicates)
        }

        $filtraPolicy = $false
        foreach ($predicado in $predicados) {
            if (@($predicado.values) -contains [string]$PolicyId) { $filtraPolicy = $true }
        }

        if (-not $filtraPolicy) {
            throw "Workflow '$Name' ($workflowId) existe mas nao filtra a policy ${PolicyId}: o incidente nao viraria e-mail. Corrigir o filtro no New Relic ou remover o workflow para que a proxima execucao o recrie amarrado a policy."
        }

        # Diferente das demais mutations de update, aiWorkflowsUpdateWorkflow nao
        # aceita `id` como argumento: o id do workflow vai dentro de
        # updateWorkflowData. Passar no topo quebra a validacao de schema.
        $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $workflow: AiWorkflowsUpdateWorkflowInput!) {
  aiWorkflowsUpdateWorkflow(accountId: $accountId, updateWorkflowData: $workflow) {
    workflow { id name }
    errors { __typename }
  }
}
'@ -Variables @{
            accountId = [int]$Context.AccountId
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

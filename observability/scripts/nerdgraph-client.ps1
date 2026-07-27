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
        Warnings  = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-NerdGraphWarning {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Host "  AVISO: $Message"
    if ($null -ne $Context.PSObject.Properties['Warnings'] -and $null -ne $Context.Warnings) {
        $Context.Warnings.Add([pscustomobject]@{ Message = $Message }) | Out-Null
    }
}

function Get-NerdGraphWarnings {
    param([Parameter(Mandatory = $true)]$Context)

    if ($null -eq $Context.PSObject.Properties['Warnings'] -or $null -eq $Context.Warnings) {
        return @()
    }

    return @($Context.Warnings)
}

function Get-CanonicalResourceKey {
    param([Parameter(Mandatory = $true)]$Resource)

    foreach ($propertyName in @('guid', 'id')) {
        $property = $Resource.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return ($Resource | ConvertTo-Json -Depth 10 -Compress)
}

function Select-CanonicalResource {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Resources,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $ordered = @($Resources | Sort-Object { Get-CanonicalResourceKey -Resource $_ })
    if ($ordered.Count -eq 0) { return $null }

    if ($ordered.Count -gt 1) {
        $ids = ($ordered | ForEach-Object { Get-CanonicalResourceKey -Resource $_ }) -join ', '
        $canonical = Get-CanonicalResourceKey -Resource $ordered[0]
        Add-NerdGraphWarning -Context $Context -Message "$Label possui $($ordered.Count) ocorrencia(s). Usando canonico $canonical e mantendo duplicados para limpeza operacional futura. IDs/GUIDs: $ids."
    }

    return $ordered[0]
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

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }

    return $null
}

function Invoke-NewRelicRest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('Get', 'Post', 'Put', 'Delete')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Body
    )

    $baseUrl = if ($Context.Region -eq 'EU') { 'https://api.eu.newrelic.com/v2' } else { 'https://api.newrelic.com/v2' }
    $arguments = @{
        Uri        = "$baseUrl$Path"
        Method     = $Method
        Headers    = @{ 'Api-Key' = $Context.ApiKey; 'Content-Type' = 'application/json' }
        TimeoutSec = 60
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $json = $Body | ConvertTo-Json -Depth 25 -Compress
        $arguments['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
    }

    try {
        return Invoke-RestMethod @arguments
    }
        catch {
            $status = Get-HttpStatusCode -ErrorRecord $_
            $detalhe = if ([string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) { $_.Exception.Message } else { $_.ErrorDetails.Message }
            $descricao = if ($null -eq $status) { $detalhe } else { "HTTP ${status}: $detalhe" }
            throw "New Relic REST falhou ($Method $Path): $descricao"
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
>1 resultados -> escolhe canonico deterministico e registra aviso

Duplicidade no New Relic nao bloqueia o deploy: a execucao atualiza um recurso
canonico e deixa a limpeza manual como atividade operacional explicita.
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
    return Select-CanonicalResource -Context $Context -Resources $entities -Label "$Label para a busca [$Query]"
}

function Set-NrqlCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)]$Condition
    )

    $query = $Condition.nrql

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

    $existingConditions = @(Find-NrqlConditions -Context $Context -PolicyId $PolicyId -Name $Condition.name)

    if ($existingConditions.Count -eq 0) {
        $created = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $policyId: ID!, $condition: AlertsNrqlConditionStaticInput!) {
  alertsNrqlConditionStaticCreate(accountId: $accountId, policyId: $policyId, condition: $condition) { id name }
}
'@ -Variables @{ accountId = [int]$Context.AccountId; policyId = $PolicyId; condition = $conditionInput }
        return @([pscustomobject]@{ Guid = $created.data.alertsNrqlConditionStaticCreate.id; Action = 'created' })
    }

    if ($existingConditions.Count -gt 1) {
        $ids = ($existingConditions | ForEach-Object { $_.id }) -join ', '
        Add-NerdGraphWarning -Context $Context -Message "Condicao NRQL '$($Condition.name)' duplicada na policy $PolicyId. Atualizando todas para evitar divergencia. IDs: $ids."
    }

    $updates = @()
    foreach ($existing in $existingConditions) {
        $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $id: ID!, $condition: AlertsNrqlConditionUpdateStaticInput!) {
  alertsNrqlConditionStaticUpdate(accountId: $accountId, id: $id, condition: $condition) { id name }
}
'@ -Variables @{ accountId = [int]$Context.AccountId; id = $existing.id; condition = $conditionInput }
        $updates += [pscustomobject]@{ Guid = $updated.data.alertsNrqlConditionStaticUpdate.id; Action = 'updated' }
    }

    return @($updates)
}

<#
Busca condicao por nome E policyId.

Buscar so por nome nao serve: o mesmo nome pode existir em outra policy, e a
condicao precisa pertencer a policy correta para a notificacao funcionar.
#>
function Find-NrqlConditions {
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
        Where-Object { $_.name -eq $Name -and [string]$_.policyId -eq [string]$PolicyId } |
        Sort-Object { [string]$_.id })

    return @($encontradas)
}

function Find-SingleNrqlCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $conditions = @(Find-NrqlConditions -Context $Context -PolicyId $PolicyId -Name $Name)
    return Select-CanonicalResource -Context $Context -Resources $conditions -Label "Condicao NRQL '$Name' na policy $PolicyId"
}

function Set-SyntheticCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)]$Condition,
        [Parameter(Mandatory = $true)][string]$MonitorGuid
    )

    # A NerdGraph atual nao lista condicoes Synthetic multi-location no namespace
    # alerts; a propria documentacao da New Relic ainda direciona este tipo para
    # o REST v2 alerts_location_failure_conditions.
    $conditionInput = @{
        name                         = $Condition.name
        enabled                      = $true
        monitor_id                   = $MonitorGuid
        terms                        = @(@{ priority = 'critical'; threshold = [int]$Condition.criticalThreshold })
        violation_time_limit_seconds = [int]$Condition.violationTimeLimitSeconds
    }

    $existingConditions = @(Find-LocationConditions -Context $Context -PolicyId $PolicyId -Name $Condition.name)

    if ($existingConditions.Count -eq 0) {
        $created = Invoke-NewRelicRest `
            -Context $Context `
            -Method Post `
            -Path "/alerts_location_failure_conditions/policies/$PolicyId.json" `
            -Body @{ location_failure_condition = $conditionInput }
        $createdCondition = Get-ObjectPropertyValue -Object $created -Names @('location_failure_condition')
        if ($null -eq $createdCondition) { $createdCondition = $created }
        $createdId = Get-ObjectPropertyValue -Object $createdCondition -Names @('id')
        if ([string]::IsNullOrWhiteSpace([string]$createdId)) {
            throw "REST create da condicao Synthetic '$($Condition.name)' nao retornou id."
        }
        return @([pscustomobject]@{ Guid = $createdId; Action = 'created' })
    }

    if ($existingConditions.Count -gt 1) {
        $ids = ($existingConditions | ForEach-Object { $_.id }) -join ', '
        Add-NerdGraphWarning -Context $Context -Message "Condicao de Synthetic '$($Condition.name)' duplicada na policy $PolicyId. Atualizando todas para evitar divergencia. IDs: $ids."
    }

    $updates = @()
    foreach ($existing in $existingConditions) {
        $updated = Invoke-NewRelicRest `
            -Context $Context `
            -Method Put `
            -Path "/alerts_location_failure_conditions/$($existing.id).json" `
            -Body @{ location_failure_condition = $conditionInput }
        $updatedCondition = Get-ObjectPropertyValue -Object $updated -Names @('location_failure_condition')
        if ($null -eq $updatedCondition) { $updatedCondition = $updated }
        $updatedId = Get-ObjectPropertyValue -Object $updatedCondition -Names @('id')
        if ([string]::IsNullOrWhiteSpace([string]$updatedId)) { $updatedId = $existing.id }
        $updates += [pscustomobject]@{ Guid = $updatedId; Action = 'updated' }
    }

    return @($updates)
}

function Find-LocationConditions {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $response = Invoke-NewRelicRest -Context $Context -Method Get -Path "/alerts_location_failure_conditions/policies/$PolicyId.json"
    $itemsValue = Get-ObjectPropertyValue -Object $response -Names @('location_failure_conditions', 'conditions')
    $items = if ($null -eq $itemsValue) { @() } else { @($itemsValue) }

    $conditions = @($items |
        Where-Object { (Get-ObjectPropertyValue -Object $_ -Names @('name')) -eq $Name } |
        Sort-Object { [string](Get-ObjectPropertyValue -Object $_ -Names @('id')) })

    return @($conditions)
}

function Find-SingleLocationCondition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PolicyId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $conditions = @(Find-LocationConditions -Context $Context -PolicyId $PolicyId -Name $Name)
    return Select-CanonicalResource -Context $Context -Resources $conditions -Label "Condicao de Synthetic '$Name' na policy $PolicyId"
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
    $existingDestination = Select-CanonicalResource -Context $Context -Resources $existingDestinations -Label "Destination '$Name'"

    $destinationProperties = @(@{ key = 'email'; value = $Email })

    if ($null -eq $existingDestination) {
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
        $destinationId = $existingDestination.id
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
    $existingChannel = Select-CanonicalResource -Context $Context -Resources $existingChannels -Label "Channel '$Name'"

    $channelProperties = @(
        @{ key = 'subject'; value = '[FIAP Oficina] {{ issueTitle }}' }
    )

    if ($null -eq $existingChannel) {
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
        $channelId = $existingChannel.id
        $updated = Invoke-NerdGraph -Context $Context -Query @'
mutation($accountId: Int!, $channelId: ID!, $channel: AiNotificationsChannelUpdate!) {
  aiNotificationsUpdateChannel(accountId: $accountId, channelId: $channelId, channel: $channel) {
    channel { id name }
    errors { __typename }
  }
}
'@ -Variables @{
            accountId = [int]$Context.AccountId
            channelId = $channelId
            channel   = @{
                name          = $Name
                destinationId = $destinationId
                properties    = $channelProperties
            }
        }
        Assert-NoMutationErrors -Payload $updated.data.aiNotificationsUpdateChannel -Label 'aiNotificationsUpdateChannel'
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
    $existingWorkflow = Select-CanonicalResource -Context $Context -Resources $existingWorkflows -Label "Workflow '$Name'"

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

    if ($null -eq $existingWorkflow) {
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
        $workflowId = $existingWorkflow.id

        # O update tambem reescreve o issuesFilter: se a policy foi recriada, ou
        # alguem editou o workflow pela UI, o deploy volta a amarrar a notificacao
        # na policy canonica desta solucao.
        $predicados = @()
        if ($null -ne $existingWorkflow.PSObject.Properties['issuesFilter'] -and $null -ne $existingWorkflow.issuesFilter) {
            $predicados = @($existingWorkflow.issuesFilter.predicates)
        }

        $filtraPolicy = $false
        foreach ($predicado in $predicados) {
            if (@($predicado.values) -contains [string]$PolicyId) { $filtraPolicy = $true }
        }

        if (-not $filtraPolicy) {
            Add-NerdGraphWarning -Context $Context -Message "Workflow '$Name' ($workflowId) existia sem filtrar a policy $PolicyId. O filtro sera corrigido nesta execucao."
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
                issuesFilter          = $issuesFilter
                destinationConfigurations = @(@{ channelId = $channelId; notificationTriggers = @('ACTIVATED', 'CLOSED') })
                mutingRulesHandling   = 'NOTIFY_ALL_ISSUES'
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

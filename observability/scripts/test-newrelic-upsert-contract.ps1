<#
.SYNOPSIS
    Testa offline o contrato de upsert New Relic.

.DESCRIPTION
    Nao chama a New Relic. Simula respostas NerdGraph para provar que:

      - zero recurso encontrado cria;
      - um recurso encontrado atualiza;
      - multiplos recursos nao falham, registram warning e seguem criterio
        canonico deterministico.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'nerdgraph-client.ps1')

function Convert-ToObject {
    param([Parameter(Mandatory = $true)][hashtable]$Value)
    return ($Value | ConvertTo-Json -Depth 25 | ConvertFrom-Json)
}

$script:ExistingEntities = @()
$script:ExistingNrqlConditions = @()
$script:ExistingLocationConditions = @()
$script:CapturedMutations = [System.Collections.Generic.List[object]]::new()
$script:CapturedRestCalls = [System.Collections.Generic.List[object]]::new()

function Invoke-NerdGraph {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [hashtable]$Variables,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    if ($Query -match 'entitySearch') {
        return Convert-ToObject @{ data = @{ actor = @{ entitySearch = @{ results = @{ entities = $script:ExistingEntities } } } } }
    }

    if ($Query -match 'nrqlConditionsSearch') {
        return Convert-ToObject @{ data = @{ actor = @{ account = @{ alerts = @{ nrqlConditionsSearch = @{ nrqlConditions = $script:ExistingNrqlConditions } } } } } }
    }

    if ($Query -match 'alertsNrqlConditionStaticCreate') {
        $script:CapturedMutations.Add([pscustomobject]@{ Kind = 'create'; Variables = $Variables }) | Out-Null
        return Convert-ToObject @{ data = @{ alertsNrqlConditionStaticCreate = @{ id = 'condition-created'; name = $Variables.condition.name } } }
    }

    if ($Query -match 'alertsNrqlConditionStaticUpdate') {
        $script:CapturedMutations.Add([pscustomobject]@{ Kind = 'update'; Variables = $Variables }) | Out-Null
        return Convert-ToObject @{ data = @{ alertsNrqlConditionStaticUpdate = @{ id = $Variables.id; name = $Variables.condition.name } } }
    }

    throw "Query nao simulada no teste de upsert: $Query"
}

function Invoke-NewRelicRest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Body
    )

    $script:CapturedRestCalls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body }) | Out-Null

    if ($Method -eq 'Get' -and $Path -match '^/alerts_location_failure_conditions/policies/(?<policyId>[^/]+)\.json$') {
        return Convert-ToObject @{ location_failure_conditions = $script:ExistingLocationConditions }
    }

    if ($Method -eq 'Post' -and $Path -match '^/alerts_location_failure_conditions/policies/(?<policyId>[^/]+)\.json$') {
        return Convert-ToObject @{
            location_failure_condition = @{
                id        = 'synthetic-created'
                name      = $Body.location_failure_condition.name
                policy_id = $Matches['policyId']
            }
        }
    }

    if ($Method -eq 'Put' -and $Path -match '^/alerts_location_failure_conditions/(?<conditionId>[^/]+)\.json$') {
        return Convert-ToObject @{
            location_failure_condition = @{
                id   = $Matches['conditionId']
                name = $Body.location_failure_condition.name
            }
        }
    }

    throw "REST nao simulado no teste de upsert: $Method $Path"
}

function New-TestContext {
    return New-NerdGraphContext -AccountId '123456' -ApiKey 'offline' -Region 'US'
}

$condition = Convert-ToObject @{
    name                 = 'Oficina - Contrato Upsert'
    type                 = 'NRQL_STATIC'
    nrql                 = 'FROM Metric SELECT count(*) WHERE metricName LIKE ''otelcol_%'''
    operator             = 'ABOVE'
    criticalThreshold    = 1
    aggregationMethod    = 'EVENT_FLOW'
    aggregationWindow    = 60
    aggregationDelay     = 120
    thresholdDuration    = 300
    thresholdOccurrences = 'ALL'
}

# Recurso generico: zero, um e varios resultados.
$context = New-TestContext
$script:ExistingEntities = @()
$found = Find-SingleEntity -Context $context -Query "name = 'Dashboard' AND type = 'DASHBOARD'" -Label 'dashboard'
if ($null -ne $found) {
    throw 'Find-SingleEntity deveria devolver null quando nenhum recurso existe.'
}

$context = New-TestContext
$script:ExistingEntities = @(@{ guid = 'guid-1'; name = 'Dashboard'; entityType = 'DASHBOARD' })
$found = Find-SingleEntity -Context $context -Query "name = 'Dashboard' AND type = 'DASHBOARD'" -Label 'dashboard'
if ($found.guid -ne 'guid-1') {
    throw "Find-SingleEntity nao devolveu o unico recurso existente: $($found.guid)"
}

$context = New-TestContext
$script:ExistingEntities = @(
    @{ guid = 'guid-b'; name = 'Dashboard'; entityType = 'DASHBOARD' },
    @{ guid = 'guid-a'; name = 'Dashboard'; entityType = 'DASHBOARD' }
)
$found = Find-SingleEntity -Context $context -Query "name = 'Dashboard' AND type = 'DASHBOARD'" -Label 'dashboard'
if ($found.guid -ne 'guid-a') {
    throw "Duplicidade deveria escolher canonico deterministico guid-a; observado $($found.guid)."
}
if (@(Get-NerdGraphWarnings -Context $context).Count -ne 1) {
    throw 'Duplicidade de entidade deveria registrar exatamente 1 warning.'
}

# Monitor Synthetic: o alerta REST v2 usa monitorId, nao o EntityGuid do NerdGraph.
$context = New-TestContext
$script:ExistingEntities = @(@{ guid = 'entity-guid'; name = 'Oficina - Health'; entityType = 'MONITOR'; monitorId = 'monitor-id' })
$monitorId = Get-SyntheticMonitorId -Context $context -Name 'Oficina - Health' -MaxAttempts 1
if ($monitorId -ne 'monitor-id') {
    throw "Get-SyntheticMonitorId nao devolveu monitorId: $monitorId"
}

$context = New-TestContext
$script:ExistingEntities = @(@{ guid = 'entity-guid'; name = 'Oficina - Health'; entityType = 'MONITOR' })
try {
    Get-SyntheticMonitorId -Context $context -Name 'Oficina - Health' -MaxAttempts 1 | Out-Null
    throw 'Get-SyntheticMonitorId deveria reprovar monitor sem monitorId.'
}
catch {
    if ($_.Exception.Message -notmatch 'monitorId') { throw }
}

# Condicao NRQL: zero cria.
$context = New-TestContext
$script:CapturedMutations.Clear()
$script:ExistingNrqlConditions = @()
$result = @(Set-NrqlCondition -Context $context -PolicyId 'policy-1' -Condition $condition)
if ($result.Count -ne 1 -or $result[0].Action -ne 'created' -or $result[0].Guid -ne 'condition-created') {
    throw 'Set-NrqlCondition deveria criar quando nao existe.'
}
if (@($script:CapturedMutations | Where-Object { $_.Kind -eq 'create' }).Count -ne 1) {
    throw 'Cenario sem condicao existente deveria executar exatamente 1 create.'
}

# Condicao NRQL: um recurso atualiza.
$context = New-TestContext
$script:CapturedMutations.Clear()
$script:ExistingNrqlConditions = @(@{ id = 'condition-1'; name = $condition.name; policyId = 'policy-1' })
$result = @(Set-NrqlCondition -Context $context -PolicyId 'policy-1' -Condition $condition)
if ($result.Count -ne 1 -or $result[0].Action -ne 'updated' -or $result[0].Guid -ne 'condition-1') {
    throw 'Set-NrqlCondition deveria atualizar o unico recurso existente.'
}
if (@($script:CapturedMutations | Where-Object { $_.Kind -eq 'update' }).Count -ne 1) {
    throw 'Cenario com uma condicao existente deveria executar exatamente 1 update.'
}

# Condicao NRQL: varios recursos nao falham e todos sao normalizados.
$context = New-TestContext
$script:CapturedMutations.Clear()
$script:ExistingNrqlConditions = @(
    @{ id = 'condition-b'; name = $condition.name; policyId = 'policy-1' },
    @{ id = 'condition-a'; name = $condition.name; policyId = 'policy-1' }
)
$result = @(Set-NrqlCondition -Context $context -PolicyId 'policy-1' -Condition $condition)
if ($result.Count -ne 2 -or @($result | Where-Object { $_.Action -ne 'updated' }).Count -gt 0) {
    throw 'Condicoes duplicadas deveriam ser atualizadas em conjunto sem falhar.'
}
if (@($script:CapturedMutations | Where-Object { $_.Kind -eq 'create' }).Count -ne 0) {
    throw 'Cenario duplicado nao deve criar recurso novo.'
}
if (@(Get-NerdGraphWarnings -Context $context).Count -ne 1) {
    throw 'Condicoes duplicadas deveriam registrar exactly 1 warning.'
}

# Condicao Synthetic multi-location: usa REST v2 porque NerdGraph nao oferece a
# listagem deste tipo no namespace alerts.
$synthetic = Convert-ToObject @{
    name                      = 'Oficina - Synthetic REST'
    type                      = 'SYNTHETIC_MULTI_LOCATION'
    monitorName               = 'Oficina - Health'
    criticalThreshold         = 1
    violationTimeLimitSeconds = 3600
}

$context = New-TestContext
$script:CapturedRestCalls.Clear()
$script:ExistingLocationConditions = @()
$result = @(Set-SyntheticCondition -Context $context -PolicyId 'policy-1' -Condition $synthetic -MonitorId 'monitor-id')
if ($result.Count -ne 1 -or $result[0].Action -ne 'created' -or $result[0].Guid -ne 'synthetic-created') {
    throw 'Set-SyntheticCondition deveria criar via REST quando nao existe.'
}
$createCall = @($script:CapturedRestCalls | Where-Object { $_.Method -eq 'Post' }) | Select-Object -First 1
if ($null -eq $createCall -or $createCall.Path -ne '/alerts_location_failure_conditions/policies/policy-1.json') {
    throw 'Criacao Synthetic deveria usar o endpoint REST de location failure conditions.'
}
if ($createCall.Body.location_failure_condition.PSObject.Properties['monitor_id']) {
    throw 'REST de location failure conditions nao documenta monitor_id; use entities com o monitorId do monitor Synthetic.'
}
if (@($createCall.Body.location_failure_condition.entities) -notcontains 'monitor-id') {
    throw 'REST de location failure conditions exige entities com o monitorId do monitor Synthetic.'
}
if ($createCall.Body.location_failure_condition.terms[0].priority -ne 'critical') {
    throw 'REST de location failure conditions usa prioridade critical em minusculo.'
}
if ($createCall.Body.location_failure_condition.PSObject.Properties['violationTimeLimitSeconds']) {
    throw 'REST de location failure conditions deve usar violation_time_limit_seconds, nao camelCase.'
}

$context = New-TestContext
$script:CapturedRestCalls.Clear()
$script:ExistingLocationConditions = @(@{ id = 'synthetic-1'; name = $synthetic.name; policy_id = 'policy-1' })
$result = @(Set-SyntheticCondition -Context $context -PolicyId 'policy-1' -Condition $synthetic -MonitorId 'monitor-id')
if ($result.Count -ne 1 -or $result[0].Action -ne 'updated' -or $result[0].Guid -ne 'synthetic-1') {
    throw 'Set-SyntheticCondition deveria atualizar via REST quando a condicao existe.'
}
if (@($script:CapturedRestCalls | Where-Object { $_.Method -eq 'Put' }).Count -ne 1) {
    throw 'Cenario com uma Synthetic existente deveria executar exatamente 1 PUT.'
}

$context = New-TestContext
$script:CapturedRestCalls.Clear()
$script:ExistingLocationConditions = @(
    @{ id = 'synthetic-b'; name = $synthetic.name; policy_id = 'policy-1' },
    @{ id = 'synthetic-a'; name = $synthetic.name; policy_id = 'policy-1' }
)
$result = @(Set-SyntheticCondition -Context $context -PolicyId 'policy-1' -Condition $synthetic -MonitorId 'monitor-id')
if ($result.Count -ne 2 -or @($result | Where-Object { $_.Action -ne 'updated' }).Count -gt 0) {
    throw 'Condicoes Synthetic duplicadas deveriam ser atualizadas em conjunto sem falhar.'
}
if (@($script:CapturedRestCalls | Where-Object { $_.Method -eq 'Put' }).Count -ne 2) {
    throw 'Cenario Synthetic duplicado deveria executar 2 PUTs.'
}
if (@(Get-NerdGraphWarnings -Context $context).Count -ne 1) {
    throw 'Synthetic duplicada deveria registrar exactly 1 warning.'
}

Write-Host 'Contrato de upsert New Relic aprovado.'

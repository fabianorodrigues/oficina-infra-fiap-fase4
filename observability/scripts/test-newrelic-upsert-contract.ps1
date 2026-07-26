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
$script:CapturedMutations = [System.Collections.Generic.List[object]]::new()

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

Write-Host 'Contrato de upsert New Relic aprovado.'

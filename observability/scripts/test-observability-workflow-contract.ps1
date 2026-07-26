<#
.SYNOPSIS
    Testa offline o contrato do workflow de observabilidade.

.DESCRIPTION
    Garante que o workflow expose somente DEPLOY/VALIDATE e que VALIDATE siga
    caminho somente leitura: sem provisionamento New Relic, sem Helm apply, sem
    Secret novo e sem mutations NerdGraph.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$workflowPath = Join-Path $RepositoryRoot '.github/workflows/observability-deploy.yml'
$validatePath = Join-Path $PSScriptRoot 'validate-newrelic.ps1'

$workflow = Get-Content -LiteralPath $workflowPath -Raw
$validateScript = Get-Content -LiteralPath $validatePath -Raw

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Text -notmatch $Pattern) { throw $Message }
}

function Get-StepBlock {
    param([Parameter(Mandatory = $true)][string]$Name)

    $pattern = "(?ms)^\s+- name: $([regex]::Escape($Name))\r?\n.*?(?=^\s+- name:|\z)"
    $match = [regex]::Match($workflow, $pattern)
    if (-not $match.Success) { throw "Step nao encontrado no workflow: $Name" }
    return $match.Value
}

$removedInputNames = @(
    ('validation' + '_' + 'only'),
    ('application' + '_' + 'signals' + '_' + 'required')
)
foreach ($removedInputName in $removedInputNames) {
    if ($workflow.Contains($removedInputName)) {
        throw "Workflow ainda expoe input removido: $removedInputName."
    }
}

Assert-Contains -Text $workflow -Pattern '(?ms)mode:\s*\r?\n\s*description:.*DEPLOY.*VALIDATE' -Message 'Input mode DEPLOY/VALIDATE nao encontrado.'
Assert-Contains -Text $workflow -Pattern 'new_relic_provisioning_enabled.*\(\$mode -eq ''DEPLOY''\)' -Message 'Provisionamento New Relic precisa ficar restrito ao modo DEPLOY.'
Assert-Contains -Text $workflow -Pattern 'collector_deploy_enabled.*\(\$mode -eq ''DEPLOY''\)' -Message 'Collector apply precisa ficar restrito ao modo DEPLOY.'
Assert-Contains -Text $workflow -Pattern 'collector_validate_enabled.*\(\$mode -eq ''VALIDATE''\)' -Message 'Validacao do Collector precisa ficar restrita ao modo VALIDATE.'

$deployCollector = Get-StepBlock -Name 'Install or update the New Relic Collector'
Assert-Contains -Text $deployCollector -Pattern "collector_deploy_enabled == 'true'" -Message 'Step mutavel do Collector sem condicao de DEPLOY.'

$validateCollector = Get-StepBlock -Name 'Validate existing New Relic Collector'
Assert-Contains -Text $validateCollector -Pattern "collector_validate_enabled == 'true'" -Message 'Step de validacao do Collector sem condicao de VALIDATE.'
Assert-Contains -Text $validateCollector -Pattern '-ReadOnly' -Message 'Step VALIDATE do Collector precisa chamar install-newrelic-collector.ps1 -ReadOnly.'

$provisionNewRelic = Get-StepBlock -Name 'Provision New Relic resources'
Assert-Contains -Text $provisionNewRelic -Pattern "new_relic_provisioning_enabled == 'true'" -Message 'Provisionamento New Relic precisa ficar fora do modo VALIDATE.'

if ($validateScript -match '(?m)^\s*mutation\s*\(') {
    throw 'validate-newrelic.ps1 contem mutation NerdGraph; VALIDATE deve ser somente leitura.'
}
if ($validateScript -match 'Set-NotificationChain|Set-NrqlCondition|Set-SyntheticCondition|dashboard(Update|Create)|synthetics(Update|Create)|alertsPolicy(Update|Create)') {
    throw 'validate-newrelic.ps1 chama helper ou mutation de provisionamento.'
}

Write-Host 'Contrato do workflow Observability Deploy aprovado.'

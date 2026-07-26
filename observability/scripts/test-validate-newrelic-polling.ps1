<#
.SYNOPSIS
    Testa offline o contrato de polling da validacao New Relic.

.DESCRIPTION
    Nao chama New Relic. O objetivo e garantir que sinais opcionais de aplicacao
    nao segurem a primeira passagem do Observability Deploy.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'validate-newrelic.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "validate-newrelic.ps1 nao parseia: $($errors[0].Message)"
}

$waitFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Wait-ForSignal'
    }, $true)

if ($null -eq $waitFunction) {
    throw 'Funcao Wait-ForSignal nao encontrada.'
}

$body = $waitFunction.Body.Extent.Text
$optionalIndex = $body.IndexOf('if (-not $Required)', [System.StringComparison]::Ordinal)
$whileIndex = $body.IndexOf('while ((Get-Date) -lt $deadline)', [System.StringComparison]::Ordinal)

if ($optionalIndex -lt 0) {
    throw 'Wait-ForSignal nao tem caminho rapido para sinais opcionais.'
}
if ($whileIndex -lt 0) {
    throw 'Wait-ForSignal nao tem polling para sinais obrigatorios.'
}
if ($optionalIndex -gt $whileIndex) {
    throw 'Caminho opcional aparece depois do loop de polling; isso ainda segura application_signals_required=false.'
}

$optionalBlock = $body.Substring($optionalIndex, $whileIndex - $optionalIndex)
if ($optionalBlock -notmatch 'Invoke-Nrql') {
    throw 'Caminho opcional deve fazer uma unica leitura rapida antes de marcar pendente.'
}
if ($optionalBlock -match 'Start-Sleep') {
    throw 'Caminho opcional contem Start-Sleep e pode atrasar a primeira passagem.'
}
if ($optionalBlock -notmatch "Status 'pendente'") {
    throw 'Caminho opcional nao registra pendencia.'
}
if ($optionalBlock -notmatch 'return \$true') {
    throw 'Caminho opcional deve retornar sucesso logico para nao reprovar sinais nao obrigatorios.'
}

Write-Host 'Contrato de polling New Relic aprovado.'

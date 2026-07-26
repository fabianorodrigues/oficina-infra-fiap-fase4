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

# ---------------------------------------------------------------------------
# Leitura de resultado NRQL.
#
# Predicado que le coluna direto do objeto quebra sob StrictMode quando a coluna
# nao vem (FACET sem resultado, agregacao sem alias). O erro substituia o
# diagnostico do sinal ausente por "The property ... cannot be found".
# ---------------------------------------------------------------------------
$conteudo = Get-Content -LiteralPath $scriptPath -Raw
if ($conteudo -match '\$_\.facet') {
    throw 'validate-newrelic.ps1 le $_.facet diretamente. Use Get-NrqlValue: coluna ausente e erro terminante sob StrictMode.'
}
if ($conteudo -match '\.PSObject\.Properties\s*\|') {
    throw 'validate-newrelic.ps1 varre PSObject.Properties por pipeline. Use Get-NrqlColumn para nao devolver $null.Value.'
}

# K8sNodeSample, K8sPodSample e K8sContainerSample vem do agente de
# infraestrutura (nri-kubernetes), ausente deste chart. Este stack e OTel e
# publica metricas dimensionais em Metric: consultar aqueles tipos reprova a
# validacao com a coleta inteira funcionando.
if ($conteudo -match '(?i)FROM\s+K8s\w*Sample') {
    throw 'validate-newrelic.ps1 consulta K8s*Sample, que o nr-k8s-otel-collector nao produz. Use as metricas k8s.* em Metric.'
}

. (Join-Path $PSScriptRoot 'newrelic-common.ps1')

$linha = [pscustomobject]@{ 'uniqueCount.service.instance.id' = 3; 'facet' = 'oficina-cadastro' }

if ((Get-NrqlValue -Row $linha -Name 'facet') -ne 'oficina-cadastro') {
    throw 'Get-NrqlValue nao devolveu a coluna existente.'
}
if ($null -ne (Get-NrqlValue -Row $linha -Name 'inexistente')) {
    throw 'Get-NrqlValue deveria devolver $null para coluna ausente.'
}
if ($null -ne (Get-NrqlValue -Row $null -Name 'facet')) {
    throw 'Get-NrqlValue deveria tolerar linha nula.'
}
if ((Get-NrqlColumn -Row $linha -Pattern '*uniqueCount*') -ne 3) {
    throw 'Get-NrqlColumn nao resolveu a coluna por padrao.'
}
if ($null -ne (Get-NrqlColumn -Row $linha -Pattern '*latest*')) {
    throw 'Get-NrqlColumn deveria devolver $null quando nenhuma coluna casa.'
}
if ([int](Get-NrqlColumn -Row $null -Pattern '*count*') -ne 0) {
    throw 'Coluna ausente precisa converter para zero sem erro.'
}

# ---------------------------------------------------------------------------
# Publicacao do resumo.
#
# A validacao publica o titulo antes de montar a tabela: corpo vazio e uso
# legitimo e nao pode reprovar o passo por binding de parametro.
# ---------------------------------------------------------------------------
$summaryAnterior = $env:GITHUB_STEP_SUMMARY
$env:GITHUB_STEP_SUMMARY = ''
try {
    Write-Summary -Title 'Validacao da observabilidade' -Body @() | Out-Null
}
catch {
    throw "Write-Summary reprovou corpo vazio: $($_.Exception.Message)"
}
finally {
    $env:GITHUB_STEP_SUMMARY = $summaryAnterior
}

Write-Host 'Contrato de polling New Relic aprovado.'

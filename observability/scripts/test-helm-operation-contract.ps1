<#
.SYNOPSIS
    Testa offline a classificacao da operacao Helm do Collector.

.DESCRIPTION
    Nao chama Helm nem cluster. O teste cobre os formatos que o script remoto
    publica no stdout antes de decidir entre instalacao inicial e atualizacao.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'newrelic-common.ps1')

function Assert-Operation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$ExpectedKind,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision
    )

    $operation = Resolve-HelmOperation -Output $Output
    if ($operation.Kind -ne $ExpectedKind -or $operation.CurrentRevision -ne $ExpectedRevision) {
        throw "$Name falhou: esperado $ExpectedKind/$ExpectedRevision, recebido $($operation.Kind)/$($operation.CurrentRevision)."
    }
}

Assert-Operation `
    -Name 'release ausente' `
    -Output 'OFICINA_RELEASE_STATE=absent' `
    -ExpectedKind 'instalacao-inicial' `
    -ExpectedRevision 0

Assert-Operation `
    -Name 'release existente com revision do status' `
    -Output @'
OFICINA_RELEASE_STATE=exists
OFICINA_CURRENT_REVISION=3
'@ `
    -ExpectedKind 'atualizacao' `
    -ExpectedRevision 3

Assert-Operation `
    -Name 'release existente com history json numerico' `
    -Output @'
OFICINA_RELEASE_STATE=exists
[{"revision":1},{"revision":4}]
'@ `
    -ExpectedKind 'atualizacao' `
    -ExpectedRevision 4

Assert-Operation `
    -Name 'release existente com helm list json string' `
    -Output @'
OFICINA_RELEASE_STATE=exists
[{"name":"nr-otel","revision":"5","status":"deployed"}]
'@ `
    -ExpectedKind 'atualizacao' `
    -ExpectedRevision 5

Assert-Operation `
    -Name 'estado desconhecido' `
    -Output @'
OFICINA_RELEASE_STATE=unknown
--- helm status stderr
context deadline exceeded
'@ `
    -ExpectedKind 'unknown' `
    -ExpectedRevision 0

try {
    Resolve-HelmOperation -Output 'OFICINA_RELEASE_STATE=exists' | Out-Null
    throw 'Release existente sem revision deveria reprovar.'
}
catch {
    if ($_.Exception.Message -notmatch 'nenhuma revision') {
        throw "Mensagem inesperada para release sem revision: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Prontidao dos workloads.
#
# Um DaemonSet que nunca fica pronto ja passou pelas validacoes: o Collector nao
# coletava node, pod nem container, e a instalacao foi reportada como concluida.
# ---------------------------------------------------------------------------
$validacaoCompleta = @'
--- pods do newrelic
NAME                          READY   STATUS    RESTARTS   AGE
nr-otel-daemonset-rz7nf       1/1     Running   0          2m
--- prontidao dos workloads do Collector
OFICINA_WORKLOAD daemonset/nr-otel-nr-k8s-otel-collector-daemonset pronto=1 desejado=1
OFICINA_WORKLOAD deployment/nr-otel-nr-k8s-otel-collector-deployment pronto=1 desejado=1
'@

if (@(Test-CapacityValidation -Text $validacaoCompleta -MinimumAvailableMi 512).Count -ne 0) {
    throw 'Workloads prontos nao podem gerar violacao.'
}

$validacaoIncompleta = @'
--- prontidao dos workloads do Collector
OFICINA_WORKLOAD daemonset/nr-otel-nr-k8s-otel-collector-daemonset pronto= desejado=1
OFICINA_WORKLOAD deployment/nr-otel-nr-k8s-otel-collector-deployment pronto=1 desejado=1
'@

$violacoes = @(Test-CapacityValidation -Text $validacaoIncompleta -MinimumAvailableMi 512)
if ($violacoes.Count -ne 1) {
    throw "DaemonSet sem replica pronta deveria gerar 1 violacao; gerou $($violacoes.Count)."
}
if ($violacoes[0].Message -notmatch 'daemonset/nr-otel-nr-k8s-otel-collector-daemonset com 0 de 1') {
    throw "Mensagem nao identifica o workload: $($violacoes[0].Message)"
}
if ($violacoes[0].Capacity) {
    throw 'Replica faltando nao e diagnostico de capacidade: recomendaria t3.large sem a causa ser a instancia.'
}

# ---------------------------------------------------------------------------
# Escape dentro dos scripts enviados ao node.
#
# Em string de aspas duplas o escape do PowerShell e a crase, nao a barra
# invertida. Escrever \$(comando) nao produz texto literal: o PowerShell avalia a
# subexpressao e o comando roda no runner do GitHub, nao na EC2. Ja aconteceu com
# k3s, que existe so no node.
# ---------------------------------------------------------------------------
foreach ($arquivo in @('install-newrelic-collector.ps1', 'newrelic-common.ps1', 'provision-newrelic.ps1', 'validate-newrelic.ps1')) {
    $caminho = Join-Path $PSScriptRoot $arquivo
    $errosDeParse = $null
    $arvore = [System.Management.Automation.Language.Parser]::ParseFile($caminho, [ref]$null, [ref]$errosDeParse)
    if ($errosDeParse.Count -gt 0) {
        throw "$arquivo nao parseia: $($errosDeParse[0].Message)"
    }

    $expansiveis = $arvore.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)

    foreach ($texto in $expansiveis) {
        if ($texto.Extent.Text -match '\\\$') {
            throw ('{0} linha {1}: string de aspas duplas escapa com barra invertida. Em PowerShell o escape e a crase, entao a subexpressao seria avaliada no runner em vez de virar texto para o node.' -f $arquivo, $texto.Extent.StartLineNumber)
        }
    }
}

# ---------------------------------------------------------------------------
# Fallback da license key em ambientes restritos.
#
# O AWS Academy pode negar ssm:PutParameter para o principal do runner. Esse caso
# precisa degradar para criacao direta do Secret pelo Run Command, em vez de
# interromper o deploy antes do Helm.
# ---------------------------------------------------------------------------
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'install-newrelic-collector.ps1') -Raw
foreach ($requiredSnippet in @(
        '$licenseDeliveryMode = ''parameter-store''',
        '$licenseDeliveryMode = ''run-command-fallback''',
        'New-LicenseParameter -Name $parameterName -Value $LicenseKey -Region $AwsRegion',
        '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LicenseKey))',
        'license_data=$licenseDataExpression'
    )) {
    if (-not $installScript.Contains($requiredSnippet)) {
        throw "Fallback de license key sem PutParameter incompleto. Trecho ausente: $requiredSnippet"
    }
}

if ($installScript -notmatch '(?s)try\s*\{.*?Test-ObservabilityPermissions.*?New-LicenseParameter.*?\}\s*catch\s*\{.*?run-command-fallback') {
    throw 'Fallback de license key precisa capturar falha de permissao/PutParameter e seguir com run-command-fallback.'
}

Write-Host 'Contrato Helm operation offline aprovado.'

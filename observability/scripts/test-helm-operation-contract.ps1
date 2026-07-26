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

Write-Host 'Contrato Helm operation offline aprovado.'

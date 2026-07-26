<#
.SYNOPSIS
    Testa offline as queries NerdGraph usadas no provisionamento.

.DESCRIPTION
    Nao chama a New Relic. O objetivo e barrar, antes do deploy, queries que
    quebram na validacao de schema da NerdGraph, especialmente selections diretas
    em `errors` de AI Notifications/Workflows.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$clientPath = Join-Path $PSScriptRoot 'nerdgraph-client.ps1'
$provisionPath = Join-Path $PSScriptRoot 'provision-newrelic.ps1'

. $clientPath

function Convert-ToObject {
    param([Parameter(Mandatory = $true)][hashtable]$Value)
    return ($Value | ConvertTo-Json -Depth 25 | ConvertFrom-Json)
}

function Assert-ErrorsSelectionSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $matches = [regex]::Matches($Content, 'errors\s*\{(?<body>[^}]*)\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($match in $matches) {
        $body = $match.Groups['body'].Value
        $fields = @($body -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($fields -notcontains '__typename') {
            throw "$Label contem errors sem __typename: $($body.Trim())"
        }
        foreach ($field in $fields) {
            if ($field -in @('description', 'type')) {
                throw "$Label consulta '$field' diretamente em errors. Use somente __typename para evitar falha de schema em unions/interfaces."
            }
        }
    }
}

Assert-ErrorsSelectionSafe -Content (Get-Content -LiteralPath $clientPath -Raw) -Label 'nerdgraph-client.ps1'
Assert-ErrorsSelectionSafe -Content (Get-Content -LiteralPath $provisionPath -Raw) -Label 'provision-newrelic.ps1'

$payloadWithTypenameOnly = Convert-ToObject @{
    errors = @(@{ __typename = 'AiNotificationsResponseError' })
}
try {
    Assert-NoMutationErrors -Payload $payloadWithTypenameOnly -Label 'teste'
    throw 'Assert-NoMutationErrors deveria reprovar payload com errors.'
}
catch {
    if ($_.Exception.Message -notmatch 'AiNotificationsResponseError') {
        throw "Assert-NoMutationErrors nao preservou __typename no diagnostico: $($_.Exception.Message)"
    }
}

$script:CapturedQueries = [System.Collections.Generic.List[string]]::new()
function Invoke-NerdGraph {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [hashtable]$Variables,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    $script:CapturedQueries.Add($Query)

    if ($Query -match 'destinations\s*\{') {
        return Convert-ToObject @{ data = @{ actor = @{ account = @{ aiNotifications = @{ destinations = @{ entities = @() } } } } } }
    }
    if ($Query -match 'aiNotificationsCreateDestination') {
        return Convert-ToObject @{ data = @{ aiNotificationsCreateDestination = @{ destination = @{ id = 'destination-1'; name = $Variables.destination.name }; errors = @() } } }
    }
    if ($Query -match 'channels\s*\{') {
        return Convert-ToObject @{ data = @{ actor = @{ account = @{ aiNotifications = @{ channels = @{ entities = @() } } } } } }
    }
    if ($Query -match 'aiNotificationsCreateChannel') {
        return Convert-ToObject @{ data = @{ aiNotificationsCreateChannel = @{ channel = @{ id = 'channel-1'; name = $Variables.channel.name }; errors = @() } } }
    }
    if ($Query -match 'workflows\s*\{') {
        return Convert-ToObject @{ data = @{ actor = @{ account = @{ aiWorkflows = @{ workflows = @{ entities = @() } } } } } }
    }
    if ($Query -match 'aiWorkflowsCreateWorkflow') {
        return Convert-ToObject @{ data = @{ aiWorkflowsCreateWorkflow = @{ workflow = @{ id = 'workflow-1'; name = $Variables.workflow.name }; errors = @() } } }
    }

    throw "Query nao simulada no teste offline: $Query"
}

$context = [pscustomobject]@{
    AccountId = '123456'
    Endpoint  = 'offline'
    Region    = 'US'
}

$notification = Set-NotificationChain `
    -Context $context `
    -Name 'FIAP Oficina - Email' `
    -Email 'teste@example.com' `
    -PolicyId '123'

if ($notification.DestinationAction -ne 'created' -or $notification.ChannelAction -ne 'created' -or $notification.WorkflowAction -ne 'created') {
    throw 'Simulacao offline da cadeia de notificacao nao retornou acoes created.'
}

foreach ($query in $script:CapturedQueries) {
    Assert-ErrorsSelectionSafe -Content $query -Label 'query capturada'
}

Write-Host 'Contrato NerdGraph offline aprovado.'

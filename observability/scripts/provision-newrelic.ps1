<#
.SYNOPSIS
    Provisiona dashboard, alertas, notificacao e Synthetic Monitors por NerdGraph.

.DESCRIPTION
    Nao usa Terraform de proposito: o reset do AWS Academy apaga o state mas nao
    apaga os recursos no New Relic, entao o state deixaria de descrever a realidade
    e a proxima execucao criaria tudo em duplicidade.

    Resolucao por nome estavel, com contagem explicita:

        0 resultados  -> criar
        1 resultado   -> atualizar por GUID
        >1 resultados -> reprovar e listar os GUIDs

    Nunca atualizar arbitrariamente o primeiro resultado: buscar so por nome nao
    distingue duplicidade deixada por execucao anterior.

    Criar o monitor nao notifica nada por si so. Cada monitor recebe condicao
    propria dentro da policy, senao o uptime aparece no Synthetics e a
    indisponibilidade nao vira e-mail.
#>
[CmdletBinding()]
param(
    [string]$AccountId,
    [string]$UserApiKey,
    [ValidateSet('US', 'EU')][string]$NewRelicRegion = 'US',
    [string]$NotificationEmail,
    [string]$ApiUrl,
    [switch]$ApplicationSignalsReady,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repositoryRoot 'config/observability.yml'
}

. (Join-Path $PSScriptRoot 'newrelic-common.ps1')
. (Join-Path $PSScriptRoot 'nerdgraph-client.ps1')

if ([string]::IsNullOrWhiteSpace($AccountId) -or [string]::IsNullOrWhiteSpace($UserApiKey)) {
    Write-Summary -Title 'Provisionamento New Relic ignorado' -Body @(
        'NEW_RELIC_ACCOUNT_ID ou NEW_RELIC_USER_API_KEY nao configurado.',
        'Nenhum dashboard, policy, monitor, destination, channel ou workflow foi criado ou atualizado.'
    )
    Write-Host 'New Relic nao configurado: provisionamento ignorado.'
    return
}

$config = Read-ObservabilityConfig -Path $ConfigPath
$context = New-NerdGraphContext -AccountId $AccountId -ApiKey $UserApiKey -Region $NewRelicRegion

$dashboardPath = Join-Path $repositoryRoot 'observability/dashboards/oficina-overview.json'
$alertsPath = Join-Path $repositoryRoot 'observability/alerts/oficina-alerts.json'
$syntheticsPath = Join-Path $repositoryRoot 'observability/synthetics/health-monitors.json'

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Kind, [string]$Name, [string]$Guid, [string]$Action) {
    $results.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Guid = $Guid; Action = $Action })
}

# Gates que ainda nao fecharam nao podem virar widget ou condicao: o requisito e
# nao versionar query baseada em atributo nao confirmado.
$satisfiedGates = @(9, 10, 11)
if ($ApplicationSignalsReady) { $satisfiedGates += 12 }
$deferred = [System.Collections.Generic.List[string]]::new()

function Test-GateSatisfied {
    param($Item)

    if ($null -eq $Item.PSObject.Properties['requiresGate']) { return $true }
    return $satisfiedGates -contains [int]$Item.requiresGate
}

# ---------------------------------------------------------------------------
# Dashboard.
# ---------------------------------------------------------------------------
Write-Step "Dashboard '$($config.DashboardName)'"
$dashboardJson = (Get-Content -LiteralPath $dashboardPath -Raw).Replace('__ACCOUNT_ID__', $AccountId)
$dashboard = $dashboardJson | ConvertFrom-Json

$pages = @()
foreach ($page in $dashboard.pages) {
    $widgets = @()
    foreach ($widget in $page.widgets) {
        $queries = @()
        $skip = $false
        foreach ($query in $widget.rawConfiguration.nrqlQueries) {
            if (-not (Test-GateSatisfied -Item $query)) {
                $skip = $true
                continue
            }
            $queries += @{ accountId = [int64]$AccountId; query = $query.query }
        }

        if ($skip -or $queries.Count -eq 0) {
            $deferred.Add("widget '$($widget.title)' (pagina $($page.name))")
            continue
        }

        $widgets += @{
            title            = $widget.title
            layout           = @{
                column = [int]$widget.layout.column
                row    = [int]$widget.layout.row
                width  = [int]$widget.layout.width
                height = [int]$widget.layout.height
            }
            visualization    = @{ id = $widget.visualization.id }
            rawConfiguration = @{ nrqlQueries = $queries }
        }
    }

    $pages += @{ name = $page.name; description = $page.description; widgets = $widgets }
}

$dashboardInput = @{
    name        = $config.DashboardName
    description = $dashboard.description
    permissions = $dashboard.permissions
    pages       = $pages
}

$existingDashboard = Find-SingleEntity -Context $context -Query "name = '$($config.DashboardName)' AND type = 'DASHBOARD'" -Label 'dashboard'
if ($null -eq $existingDashboard) {
    $created = Invoke-NerdGraph -Context $context -Query @'
mutation($accountId: Int!, $dashboard: DashboardInput!) {
  dashboardCreate(accountId: $accountId, dashboard: $dashboard) {
    entityResult { guid }
    errors { __typename }
  }
}
'@ -Variables @{ accountId = [int]$AccountId; dashboard = $dashboardInput }
    Assert-NoMutationErrors -Payload $created.data.dashboardCreate -Label 'dashboardCreate'
    $dashboardGuid = $created.data.dashboardCreate.entityResult.guid
    Add-Result 'Dashboard' $config.DashboardName $dashboardGuid 'created'
}
else {
    $updated = Invoke-NerdGraph -Context $context -Query @'
mutation($guid: EntityGuid!, $dashboard: DashboardInput!) {
  dashboardUpdate(guid: $guid, dashboard: $dashboard) {
    entityResult { guid }
    errors { __typename }
  }
}
'@ -Variables @{ guid = $existingDashboard.guid; dashboard = $dashboardInput }
    Assert-NoMutationErrors -Payload $updated.data.dashboardUpdate -Label 'dashboardUpdate'
    $dashboardGuid = $existingDashboard.guid
    Add-Result 'Dashboard' $config.DashboardName $dashboardGuid 'updated'
}

# ---------------------------------------------------------------------------
# Policy.
# ---------------------------------------------------------------------------
Write-Step "Policy '$($config.PolicyName)'"
$alerts = Get-Content -LiteralPath $alertsPath -Raw | ConvertFrom-Json

$policySearch = Invoke-NerdGraph -Context $context -Query @'
query($accountId: Int!, $name: String!) {
  actor { account(id: $accountId) { alerts {
    policiesSearch(searchCriteria: {name: $name}) { policies { id name } }
  } } }
}
'@ -Variables @{ accountId = [int]$AccountId; name = $config.PolicyName }

$policies = @($policySearch.data.actor.account.alerts.policiesSearch.policies | Where-Object { $_.name -eq $config.PolicyName })
if ($policies.Count -gt 1) {
    throw "Policy '$($config.PolicyName)' duplicada. IDs: $(($policies | ForEach-Object { $_.id }) -join ', '). Remover a duplicidade antes de reexecutar."
}

if ($policies.Count -eq 0) {
    $createdPolicy = Invoke-NerdGraph -Context $context -Query @'
mutation($accountId: Int!, $policy: AlertsPolicyInput!) {
  alertsPolicyCreate(accountId: $accountId, policy: $policy) { id name }
}
'@ -Variables @{ accountId = [int]$AccountId; policy = @{ name = $config.PolicyName; incidentPreference = $alerts.policy.incidentPreference } }
    $policyId = $createdPolicy.data.alertsPolicyCreate.id
    Add-Result 'Policy' $config.PolicyName $policyId 'created'
}
else {
    $policyId = $policies[0].id
    Invoke-NerdGraph -Context $context -Query @'
mutation($accountId: Int!, $id: ID!, $policy: AlertsPolicyUpdateInput!) {
  alertsPolicyUpdate(accountId: $accountId, id: $id, policy: $policy) { id name }
}
'@ -Variables @{ accountId = [int]$AccountId; id = $policyId; policy = @{ incidentPreference = $alerts.policy.incidentPreference } } | Out-Null
    Add-Result 'Policy' $config.PolicyName $policyId 'updated'
}

# ---------------------------------------------------------------------------
# Synthetic Monitors.
#
# Criados antes das condicoes: a condicao de Synthetic precisa do GUID do monitor.
# Somente depois que a URL publica resolve.
# ---------------------------------------------------------------------------
$monitorGuids = @{}
if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    Write-Host 'URL publica ausente: Synthetic Monitors nao serao provisionados nesta execucao.'
    $deferred.Add('Synthetic Monitors (URL publica indisponivel)')
}
else {
    Write-Step 'Synthetic Monitors'
    $synthetics = (Get-Content -LiteralPath $syntheticsPath -Raw).Replace('__API_URL__', $ApiUrl.TrimEnd('/')) | ConvertFrom-Json
    $monitorTags = @($synthetics.tags | ForEach-Object { @{ key = $_.key; values = @($_.values) } })

    foreach ($monitor in $synthetics.monitors) {
        $monitorInput = @{
            name      = $monitor.name
            uri       = $monitor.uri
            period    = $synthetics.period
            status    = $synthetics.status
            locations = @{ public = @($synthetics.locations.public) }
            tags      = $monitorTags
        }

        $existing = Find-SingleEntity -Context $context -Query "name = '$($monitor.name)' AND type = 'MONITOR'" -Label 'monitor'
        if ($null -eq $existing) {
            $createdMonitor = Invoke-NerdGraph -Context $context -Query @'
mutation($accountId: Int!, $monitor: SyntheticsCreateSimpleMonitorInput!) {
  syntheticsCreateSimpleMonitor(accountId: $accountId, monitor: $monitor) {
    monitor { guid name }
    errors { __typename }
  }
}
'@ -Variables @{ accountId = [int]$AccountId; monitor = $monitorInput }
            Assert-NoMutationErrors -Payload $createdMonitor.data.syntheticsCreateSimpleMonitor -Label 'syntheticsCreateSimpleMonitor'
            $guid = $createdMonitor.data.syntheticsCreateSimpleMonitor.monitor.guid
            Add-Result 'Monitor' $monitor.name $guid 'created'
        }
        else {
            $updatedMonitor = Invoke-NerdGraph -Context $context -Query @'
mutation($guid: EntityGuid!, $monitor: SyntheticsUpdateSimpleMonitorInput!) {
  syntheticsUpdateSimpleMonitor(guid: $guid, monitor: $monitor) {
    monitor { guid name }
    errors { __typename }
  }
}
'@ -Variables @{ guid = $existing.guid; monitor = $monitorInput }
            Assert-NoMutationErrors -Payload $updatedMonitor.data.syntheticsUpdateSimpleMonitor -Label 'syntheticsUpdateSimpleMonitor'
            $guid = $existing.guid
            Add-Result 'Monitor' $monitor.name $guid 'updated'
        }

        $monitorGuids[$monitor.name] = $guid
    }
}

# ---------------------------------------------------------------------------
# Condicoes.
# ---------------------------------------------------------------------------
Write-Step 'Condicoes de alerta'
foreach ($condition in $alerts.conditions) {
    if (-not (Test-GateSatisfied -Item $condition)) {
        $deferred.Add("condicao '$($condition.name)'")
        continue
    }

    if ($condition.type -eq 'SYNTHETIC_MULTI_LOCATION') {
        if (-not $monitorGuids.ContainsKey($condition.monitorName)) {
            $deferred.Add("condicao '$($condition.name)' (monitor ainda nao provisionado)")
            continue
        }

        $guid = Set-SyntheticCondition -Context $context -PolicyId $policyId -Condition $condition -MonitorGuid $monitorGuids[$condition.monitorName]
        Add-Result 'Condicao' $condition.name $guid.Guid $guid.Action
        continue
    }

    $guid = Set-NrqlCondition -Context $context -PolicyId $policyId -Condition $condition -UseFallback:(-not $ApplicationSignalsReady)
    Add-Result 'Condicao' $condition.name $guid.Guid $guid.Action
}

# ---------------------------------------------------------------------------
# Destination, Channel e Workflow.
#
# NEW_RELIC_NOTIFICATION_EMAIL e obrigatorio somente aqui: sem provisionar destino
# de notificacao, ele nao e exigido.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($NotificationEmail)) {
    Write-Host 'E-mail de notificacao ausente: destination, channel e workflow nao serao provisionados.'
    $deferred.Add('cadeia de notificacao (e-mail nao informado)')
}
else {
    Write-Step "Cadeia de notificacao '$($config.WorkflowName)'"
    $notification = Set-NotificationChain `
        -Context $context `
        -Name $config.WorkflowName `
        -Email $NotificationEmail `
        -PolicyId $policyId

    Add-Result 'Destination' $config.WorkflowName $notification.DestinationId $notification.DestinationAction
    Add-Result 'Channel' $config.WorkflowName $notification.ChannelId $notification.ChannelAction
    Add-Result 'Workflow' $config.WorkflowName $notification.WorkflowId $notification.WorkflowAction
}

# ---------------------------------------------------------------------------
# Tabela nome -> GUID -> acao. E a prova de idempotencia: numa reexecucao, tudo
# precisa aparecer como updated.
# ---------------------------------------------------------------------------
Write-Step 'Recursos provisionados'
$table = $results | ForEach-Object { "| $($_.Kind) | $($_.Name) | ``$($_.Guid)`` | $($_.Action) |" }
$summary = @(
    '| Tipo | Nome | GUID | Acao |',
    '|---|---|---|---|'
) + $table

$results | Format-Table Kind, Name, Action, Guid -AutoSize | Out-String | Write-Host

if ($deferred.Count -gt 0) {
    $summary += @('', '### Pendentes de descoberta remota', '')
    $summary += ($deferred | Sort-Object -Unique | ForEach-Object { "- $_" })
    $summary += @('', 'Nenhuma query ficticia foi versionada. Reexecutar depois de fechar os gates correspondentes.')
    Write-Host ''
    Write-Host 'Pendentes de descoberta remota:'
    $deferred | Sort-Object -Unique | ForEach-Object { Write-Host " - $_" }
}

$summaryPath = $env:GITHUB_STEP_SUMMARY
if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
    Add-Content -LiteralPath $summaryPath -Value (@('## Provisionamento New Relic', '') + $summary + @(''))
}

Write-Host ''
Write-Host "Provisionamento concluido: $($results.Count) recurso(s)."

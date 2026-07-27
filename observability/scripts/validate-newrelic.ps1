<#
.SYNOPSIS
    Valida os sinais de observabilidade no New Relic.

.DESCRIPTION
    Polling com timeout somente para sinais obrigatorios: telemetria chega em
    janelas variaveis, e um sleep unico ou reprova cedo demais ou desperdicia
    minutos. Sinais opcionais fazem uma consulta rapida e viram pendencia sem
    esperar.

    Duas categorias de sinal:

      - sempre exigidos: sinais do cluster, do proprio Collector e existencia dos
        recursos provisionados que ja podem existir no ponto atual da sequencia;
      - exigidos so com RequireApiSignals: logs, spans, metricas HTTP e a
        comparacao tripla de service.version. A flag permanece no script para
        diagnosticos manuais, mas o workflow normal pos-Entrypoint usa sinais de
        aplicacao obrigatorios.

    Regras de janela por categoria, porque a gramatica difere:
      - consulta de validacao e descoberta: SELECT, FROM e janela explicita;
      - Alert Condition: sem SINCE, janela em aggregationWindow (validado por
        scripts/validate-observability-config.ps1).
#>
[CmdletBinding()]
param(
    [string]$AwsRegion,
    [string]$AccountId,
    [string]$UserApiKey,
    [string]$CorrelationId,
    [ValidateSet('US', 'EU')][string]$NewRelicRegion = 'US',
    [string]$ApiUrl,
    [string]$NotificationEmail,
    [switch]$RequireApiSignals,
    [string]$ConfigPath,
    [ValidateRange(60, 900)][int]$TimeoutSeconds = 300,
    [ValidateRange(5, 60)][int]$IntervalSeconds = 15
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
    Write-Summary -Title 'Validacao New Relic ignorada' -Body @(
        'NEW_RELIC_ACCOUNT_ID ou NEW_RELIC_USER_API_KEY nao configurado.',
        'Nenhuma consulta NerdGraph ou NRQL foi executada.'
    )
    Write-Host 'New Relic nao configurado: validacao remota ignorada.'
    return
}

if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
    $CorrelationId = "observability-validation-$([Guid]::NewGuid().ToString('N'))"
}

$config = Read-ObservabilityConfig -Path $ConfigPath
$context = New-NerdGraphContext -AccountId $AccountId -ApiKey $UserApiKey -Region $NewRelicRegion
$syntheticsExpected = -not [string]::IsNullOrWhiteSpace($ApiUrl)
$notificationExpected = -not [string]::IsNullOrWhiteSpace($NotificationEmail)

$services = @('oficina-cadastro', 'oficina-estoque', 'oficina-ordens-servico')
$results = [System.Collections.Generic.List[object]]::new()

function Test-ConditionHasMonitor {
    param([Parameter(Mandatory = $true)]$Condition)

    $monitorIdProperty = $Condition.PSObject.Properties['monitor_id']
    if ($null -ne $monitorIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$monitorIdProperty.Value)) {
        return $true
    }

    $entitiesProperty = $Condition.PSObject.Properties['entities']
    return $null -ne $entitiesProperty -and @($entitiesProperty.Value).Count -gt 0
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'falha', 'pendente')][string]$Status,
        [string]$Detail = ''
    )

    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $prefix = switch ($Status) { 'ok' { '  ok   ' } 'falha' { '  FALHA' } default { '  ...  ' } }
    Write-Host "$prefix $Name$(if ($Detail) { " -> $Detail" })"
}

function Invoke-Nrql {
    param([Parameter(Mandatory = $true)][string]$Query)

    $response = Invoke-NerdGraph -Context $context -Query @'
query($accountId: Int!, $nrql: Nrql!) {
  actor { account(id: $accountId) { nrql(query: $nrql) { results } } }
}
'@ -Variables @{ accountId = [int]$AccountId; nrql = $Query }

    return @($response.data.actor.account.nrql.results)
}

<#
Espera o sinal aparecer quando ele e obrigatorio. Sinal opcional consulta uma vez
e, se nao apareceu, registra pendencia sem segurar diagnosticos manuais.
#>
function Wait-ForSignal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [switch]$Required,
        # Janela propria para sinal que depende de workload recem-criado. Zero
        # mantem a janela padrao da execucao.
        [ValidateRange(0, 900)][int]$TimeoutOverrideSeconds = 0
    )

    $janela = if ($TimeoutOverrideSeconds -gt 0) { $TimeoutOverrideSeconds } else { $TimeoutSeconds }
    $deadline = (Get-Date).AddSeconds($janela)
    $lastDetail = 'sem resultado'

    if (-not $Required) {
        try {
            $rows = Invoke-Nrql -Query $Query
            $verdict = & $Predicate $rows
            if ($verdict.Ok) {
                Add-Check -Name $Name -Status 'ok' -Detail $verdict.Detail
                return $true
            }
            $lastDetail = $verdict.Detail
        }
        catch {
            $lastDetail = $_.Exception.Message
        }

        Add-Check -Name $Name -Status 'pendente' -Detail "Aguardando redeploy das APIs instrumentadas. Ultima leitura: $lastDetail"
        return $true
    }

    while ((Get-Date) -lt $deadline) {
        try {
            $rows = Invoke-Nrql -Query $Query
            $verdict = & $Predicate $rows
            if ($verdict.Ok) {
                Add-Check -Name $Name -Status 'ok' -Detail $verdict.Detail
                return $true
            }
            $lastDetail = $verdict.Detail
        }
        catch {
            $lastDetail = $_.Exception.Message
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
    Add-Check -Name $Name -Status 'falha' -Detail $lastDetail
    return $false
}

function Get-ApiSignalChecks {
    param(
        [Parameter(Mandatory = $true)][string]$CorrelationId,
        [Parameter(Mandatory = $true)][string[]]$Services
    )

    $checks = [ordered]@{}

    try {
        $rows = Invoke-Nrql -Query @"
FROM Log SELECT count(*)
WHERE correlationId = '$CorrelationId'
FACET service.name
SINCE 10 minutes ago
"@
        $found = @(@($rows | ForEach-Object { Get-NrqlValue -Row $_ -Name 'facet' } | Where-Object { $null -ne $_ }) | Sort-Object -Unique)
        $missing = @($Services | Where-Object { $found -notcontains $_ })
        $checks['Logs dos tres servicos com o correlationId'] = [pscustomobject]@{
            Ok     = $missing.Count -eq 0
            Detail = if ($missing.Count -eq 0) { "3 servicos: $($found -join ', ')" } else { "faltam: $($missing -join ', ')" }
        }
    }
    catch {
        $checks['Logs dos tres servicos com o correlationId'] = [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }

    try {
        $rows = Invoke-Nrql -Query @"
FROM Log SELECT count(service.name) AS 'servico', count(service.version) AS 'versao',
count(deployment.environment) AS 'ambiente', count(correlationId) AS 'correlacao',
count(trace.id) AS 'trace', count(span.id) AS 'span'
WHERE correlationId = '$CorrelationId'
SINCE 10 minutes ago
"@
        $colunas = [ordered]@{
            'service.name'           = 'servico'
            'service.version'        = 'versao'
            'deployment.environment' = 'ambiente'
            'correlationId'          = 'correlacao'
            'trace.id'               = 'trace'
            'span.id'                = 'span'
        }

        $linha = if ($rows.Count -gt 0) { $rows[0] } else { $null }
        $missing = @()
        foreach ($campo in $colunas.Keys) {
            if ([double](Get-NrqlValue -Row $linha -Name $colunas[$campo]) -le 0) { $missing += $campo }
        }

        $checks['Campos de log no nivel superior'] = [pscustomobject]@{
            Ok     = $missing.Count -eq 0
            Detail = if ($missing.Count -eq 0) { 'todos os campos no nivel superior' }
                     else { "faltam no nivel superior (campo aninhado em body indica filelog sem parsing JSON): $($missing -join ', ')" }
        }
    }
    catch {
        $checks['Campos de log no nivel superior'] = [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }

    try {
        $rows = Invoke-Nrql -Query @"
FROM Span SELECT count(*)
WHERE correlationId = '$CorrelationId'
FACET service.name
SINCE 10 minutes ago
"@
        $found = @(@($rows | ForEach-Object { Get-NrqlValue -Row $_ -Name 'facet' } | Where-Object { $null -ne $_ }) | Sort-Object -Unique)
        $checks['Span da API de origem com o correlationId'] = [pscustomobject]@{
            Ok     = $found.Count -gt 0
            Detail = "servicos: $($found -join ', ')"
        }
    }
    catch {
        $checks['Span da API de origem com o correlationId'] = [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }

    try {
        $rows = Invoke-Nrql -Query @"
FROM Metric SELECT uniques(service.name)
WHERE metricName LIKE 'http.server.%'
SINCE 10 minutes ago
"@
        $found = @()
        foreach ($row in $rows) {
            foreach ($prop in $row.PSObject.Properties) {
                if ($prop.Value -is [System.Array]) { $found += @($prop.Value) }
            }
        }
        $found = @($found | Sort-Object -Unique)
        $missing = @($Services | Where-Object { $found -notcontains $_ })
        $checks['Metricas HTTP dos tres servicos'] = [pscustomobject]@{
            Ok     = $missing.Count -eq 0
            Detail = if ($missing.Count -eq 0) { '3 servicos' } else { "faltam: $($missing -join ', ')" }
        }
    }
    catch {
        $checks['Metricas HTTP dos tres servicos'] = [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }

    return $checks
}

function Wait-ForApiSignals {
    param(
        [Parameter(Mandatory = $true)][string]$CorrelationId,
        [Parameter(Mandatory = $true)][string[]]$Services,
        [switch]$Required
    )

    $statusWhenMissing = if ($Required) { 'falha' } else { 'pendente' }
    $pendingPrefix = if ($Required) { '' } else { 'Aguardando redeploy das APIs instrumentadas. Ultima leitura: ' }

    if (-not $Required) {
        $checks = Get-ApiSignalChecks -CorrelationId $CorrelationId -Services $Services
        foreach ($name in $checks.Keys) {
            $check = $checks[$name]
            $status = if ($check.Ok) { 'ok' } else { $statusWhenMissing }
            $detail = if ($check.Ok) { $check.Detail } else { "$pendingPrefix$($check.Detail)" }
            Add-Check -Name $name -Status $status -Detail $detail
        }
        return $true
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastChecks = $null
    while ((Get-Date) -lt $deadline) {
        $lastChecks = Get-ApiSignalChecks -CorrelationId $CorrelationId -Services $Services
        $missing = @($lastChecks.Keys | Where-Object { -not $lastChecks[$_].Ok })
        if ($missing.Count -eq 0) {
            foreach ($name in $lastChecks.Keys) {
                Add-Check -Name $name -Status 'ok' -Detail $lastChecks[$name].Detail
            }
            return $true
        }
        Start-Sleep -Seconds $IntervalSeconds
    }

    if ($null -eq $lastChecks) {
        $lastChecks = Get-ApiSignalChecks -CorrelationId $CorrelationId -Services $Services
    }
    foreach ($name in $lastChecks.Keys) {
        $check = $lastChecks[$name]
        $status = if ($check.Ok) { 'ok' } else { $statusWhenMissing }
        Add-Check -Name $name -Status $status -Detail $check.Detail
    }
    return (@($lastChecks.Keys | Where-Object { -not $lastChecks[$_].Ok }).Count -eq 0)
}

# ---------------------------------------------------------------------------
# Requisicoes de origem com correlationId conhecido.
#
# VALIDATION_STARTED_AT e carimbado aqui, e nao um periodo fixo: SINCE 5 minutes
# ago alcancaria spans da versao anterior quando o rollout terminou ha pouco, e o
# uniqueCount acusaria duas versoes ativas sem existir problema.
# ---------------------------------------------------------------------------
$validationStartedAt = [DateTimeOffset]::UtcNow.AddSeconds(-5)
$sinceClause = "SINCE '$($validationStartedAt.ToString("yyyy-MM-dd HH:mm:ss"))'"

if (-not [string]::IsNullOrWhiteSpace($ApiUrl)) {
    Write-Step "Requisicoes de origem com X-Correlation-Id: $CorrelationId"
    $base = $ApiUrl.TrimEnd('/')
    foreach ($service in @('cadastro', 'estoque', 'ordens')) {
        $uri = "$base/health/$service"
        try {
            $response = Invoke-WebRequest -Uri $uri -Method Get -Headers @{ 'X-Correlation-Id' = $CorrelationId } -TimeoutSec 20 -UseBasicParsing
            Add-Check -Name "GET /health/$service" -Status 'ok' -Detail "HTTP $($response.StatusCode)"
        }
        catch {
            Add-Check -Name "GET /health/$service" -Status 'falha' -Detail $_.Exception.Message
        }
    }
}
else {
    Add-Check -Name 'Requisicoes de origem' -Status 'pendente' -Detail 'URL publica indisponivel.'
}

# ---------------------------------------------------------------------------
# Validacoes sempre exigidas: cluster e Collector.
# ---------------------------------------------------------------------------
Write-Step 'Sinais do cluster e do Collector'

Wait-ForSignal -Name 'Metricas do proprio Collector' -Required -Query @"
FROM Metric SELECT uniqueCount(service.instance.id)
WHERE metricName LIKE 'otelcol_%'
$sinceClause
"@ -Predicate {
    param($rows)
    $count = [int](Get-NrqlColumn -Row $(if ($rows.Count -gt 0) { $rows[0] } else { $null }) -Pattern '*uniqueCount*')
    [pscustomobject]@{ Ok = $count -gt 0; Detail = "$count instancia(s) do Collector" }
} | Out-Null

# Descoberta das metricas de Kubernetes.
#
# O Collector desta instalacao e o OTel (nr-k8s-otel-collector): ele publica
# metricas dimensionais em Metric -- k8s.node.*, k8s.pod.*, container.* pelo
# kubeletstats e kube_* pelo kube-state-metrics. Os eventos K8sNodeSample,
# K8sPodSample e K8sContainerSample vem do agente de infraestrutura
# (nri-kubernetes), que NAO faz parte deste chart: consultar aqueles tipos
# reprovava com a coleta inteira funcionando.
#
# A validacao nao fixa nome de metrica: exige que exista alguma metrica de node com
# cpu e alguma com memoria, e publica o inventario completo para que widget e
# alerta sejam escritos sobre nome confirmado, nunca sobre suposicao.
#
# Janela propria: quem coleta metrica de node e o DaemonSet do Collector, criado
# minutos antes nesta mesma execucao e ja observado ainda em PodInitializing.
Write-Step 'Descoberta das metricas de Kubernetes'
$script:MetricasK8s = @()

Wait-ForSignal -Name 'CPU e memoria do node presentes' -Required -TimeoutOverrideSeconds 600 -Query @"
FROM Metric SELECT uniques(metricName, 500)
WHERE metricName LIKE 'k8s.%' OR metricName LIKE 'container.%' OR metricName LIKE 'kube_%'
OR metricName LIKE 'node.%' OR metricName LIKE 'system.%'
SINCE 30 minutes ago
"@ -Predicate {
    param($rows)

    $nomes = @()
    foreach ($row in $rows) {
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Value -is [string]) {
                $nomes += $prop.Value
            }
            elseif ($prop.Value -is [System.Collections.IEnumerable]) {
                foreach ($item in $prop.Value) {
                    if ($null -ne $item) { $nomes += [string]$item }
                }
            }
        }
    }

    $nomes = @($nomes | Sort-Object -Unique)
    $script:MetricasK8s = $nomes

    # O kubeletstats publica k8s.node.*; o processor metricsgeneration do chart
    # acrescenta node.cpu.usage.percentage e node.memory.usage.percentage, que sao
    # os nomes com a semantica percentual que as condicoes de alerta precisam.
    $cpu = @($nomes | Where-Object { $_ -match '^(k8s\.)?node\.' -and $_ -match '(?i)cpu' })
    $memoria = @($nomes | Where-Object { $_ -match '^(k8s\.)?node\.' -and $_ -match '(?i)mem' })

    [pscustomobject]@{
        Ok     = $cpu.Count -gt 0 -and $memoria.Count -gt 0
        Detail = if ($cpu.Count -gt 0 -and $memoria.Count -gt 0) {
            "cpu: $($cpu -join ', ') | memoria: $($memoria -join ', ')"
        }
        else {
            "$($nomes.Count) metrica(s) de Kubernetes e nenhuma de node com cpu/memoria. Amostra: $(@($nomes | Select-Object -First 15) -join ', ')"
        }
    }
} | Out-Null

# Inventario completo no log: e a partir dele que as queries de widget e de
# condicao sao escritas sem adivinhar nome de metrica.
if ($script:MetricasK8s.Count -gt 0) {
    Write-Host "  metricas de Kubernetes disponiveis ($($script:MetricasK8s.Count)):"
    foreach ($metrica in $script:MetricasK8s) { Write-Host "    $metrica" }
    Add-Check -Name 'Inventario de metricas de Kubernetes' -Status 'ok' -Detail "$($script:MetricasK8s.Count) metrica(s); lista completa no log do passo"

    # Metricas citadas pelas queries versionadas do dashboard e das condicoes.
    # Nao bloqueia: a validacao acima ja provou a coleta. O objetivo aqui e que um nome
    # errado apareca como pendencia nomeada, e nao como widget vazio ou alerta que
    # existe sem nunca poder disparar.
    $metricasVersionadas = @(
        'k8s.node.cpu.usage',
        'node.cpu.usage.percentage',
        'node.memory.usage.percentage',
        'container.cpu.usage',
        'k8s.pod.memory.working_set',
        'kube_pod_container_status_restarts_total',
        'kube_pod_status_ready',
        'kube_node_status_condition'
    )

    $ausentes = @($metricasVersionadas | Where-Object { $script:MetricasK8s -notcontains $_ })
    if ($ausentes.Count -eq 0) {
        Add-Check -Name 'Metricas usadas por widget e alerta' -Status 'ok' -Detail "$($metricasVersionadas.Count) metrica(s) presentes"
    }
    else {
        Add-Check -Name 'Metricas usadas por widget e alerta' -Status 'pendente' -Detail "ausentes: $($ausentes -join ', '). Widget correspondente fica vazio e condicao sobre a metrica nao dispara."
    }
}

Write-Step 'Descoberta dos Kubernetes Events'
$eventFound = $false
foreach ($eventType in @('InfrastructureEvent', 'K8sEventSample', 'Log')) {
    try {
        $filtro = if ($eventType -eq 'Log') { "WHERE k8s.namespace.name IS NOT NULL" } else { '' }
        $rows = Invoke-Nrql -Query "FROM $eventType SELECT count(*) $filtro SINCE 30 minutes ago"
        $count = [int](Get-NrqlColumn -Row $(if ($rows.Count -gt 0) { $rows[0] } else { $null }) -Pattern '*count*')
        if ($count -gt 0) {
            Add-Check -Name "Kubernetes Events em $eventType" -Status 'ok' -Detail "$count registro(s)"
            $eventFound = $true
            break
        }
    }
    catch { continue }
}
if (-not $eventFound) {
    # Nenhum evento no periodo nao reprova: a validacao registra a ausencia como
    # pendencia operacional.
    Add-Check -Name 'Kubernetes Events' -Status 'pendente' -Detail 'Nenhum evento no periodo. Widget registrado como pendente de descoberta.'
}

# ---------------------------------------------------------------------------
# Validacoes de sinais de aplicacao.
# ---------------------------------------------------------------------------
Write-Step "Sinais das APIs (obrigatorios: $($RequireApiSignals.IsPresent))"

# Estes quatro sinais dependem da mesma ingestao gerada pelas requisicoes acima.
# Rodar um polling separado para cada um transforma uma falta de telemetria em
# esperas sequenciais; um unico ciclo preserva a exigencia e reduz o pior caso.
Wait-ForApiSignals -CorrelationId $CorrelationId -Services $services -Required:$RequireApiSignals | Out-Null

# Semantica HTTP.
if ($RequireApiSignals) {
    Write-Step 'Descoberta da semantica HTTP'
    $httpShape = 'indefinida'
    try {
        $rows = Invoke-Nrql -Query "FROM Metric SELECT count(*) WHERE metricName = 'http.server.request.duration' SINCE 10 minutes ago"
        $count = [int](Get-NrqlColumn -Row $(if ($rows.Count -gt 0) { $rows[0] } else { $null }) -Pattern '*count*')
        if ($count -gt 0) {
            $httpShape = 'Metric'
            Add-Check -Name 'Semantica HTTP por Metric' -Status 'ok' -Detail "metricName http.server.request.duration com $count amostra(s)"
        }
    }
    catch { }

    if ($httpShape -eq 'indefinida') {
        try {
            $rows = Invoke-Nrql -Query "FROM Span SELECT count(*) WHERE span.kind = 'server' SINCE 10 minutes ago"
            $count = [int](Get-NrqlColumn -Row $(if ($rows.Count -gt 0) { $rows[0] } else { $null }) -Pattern '*count*')
            if ($count -gt 0) {
                $httpShape = 'Span'
                Add-Check -Name 'Semantica HTTP por Span' -Status 'ok' -Detail "$count span(s) server. Alerta de 5xx deve usar Span."
            }
        }
        catch { }
    }

    if ($httpShape -eq 'indefinida') {
        Add-Check -Name 'Semantica HTTP' -Status 'falha' -Detail 'Nem Metric nem Span server encontrados.'
    }

    # ---------------------------------------------------------------------------
    # Comparacao tripla: ConfigMap = imagem = service.version.
    #
    # O HEAD do repositorio de infra nao serve como referencia: sao repositorios
    # distintos, com cadencias de deploy distintas. A referencia e o estado
    # publicado no cluster.
    # ---------------------------------------------------------------------------
    Write-Step 'Comparacao tripla de service.version'
    $instanceId = Get-SsmValue -Name '/oficina/infra/k8s/instance-id' -Region $AwsRegion
    $namespace = Get-SsmValue -Name '/oficina/infra/k8s/namespace' -Region $AwsRegion

    $clusterState = Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'service.version' -Script @"
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
for svc in oficina-cadastro oficina-estoque oficina-ordens-servico; do
    versao="`$(k3s kubectl -n $namespace get configmap "`$svc-config" -o jsonpath='{.data.OTEL_SERVICE_VERSION}' 2>/dev/null || echo '')"
    imagem="`$(k3s kubectl -n $namespace get deployment "`$svc" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '')"
    echo "OFICINA_VERSION `$svc configmap=`$versao imagem=`$imagem"
done
"@

    Write-Host $clusterState

    foreach ($service in $services) {
        $line = @($clusterState -split "`n" | Where-Object { $_ -match "OFICINA_VERSION\s+$([regex]::Escape($service))\s" }) | Select-Object -First 1
        if ($null -eq $line) {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail 'Estado do cluster nao pudo ser lido.'
            continue
        }

        $configMapVersion = if ($line -match 'configmap=(?<v>\S*)') { $Matches['v'] } else { '' }
        $image = if ($line -match 'imagem=(?<i>\S*)') { $Matches['i'] } else { '' }

        if ([string]::IsNullOrWhiteSpace($configMapVersion)) {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail 'ConfigMap sem OTEL_SERVICE_VERSION.'
            continue
        }

        $imageTag = if ($image -match ':(?<tag>[^:]+)$') { $Matches['tag'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($imageTag) -or $imageTag -eq 'latest') {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail "Imagem sem tag imutavel: '$image'."
            continue
        }

        if ($imageTag -notlike "*$configMapVersion*" -and $configMapVersion -notlike "*$imageTag*") {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail "ConfigMap '$configMapVersion' divergente da imagem '$imageTag'."
            continue
        }

        $rows = @()
        try {
            $rows = Invoke-Nrql -Query @"
FROM Span SELECT latest(service.version), uniqueCount(service.version)
WHERE service.name = '$service' AND deployment.environment = 'production'
$sinceClause
"@
        }
        catch {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail $_.Exception.Message
            continue
        }

        if ($rows.Count -eq 0) {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail 'New Relic sem span do servico na janela da validacao.'
            continue
        }

        $latest = [string](Get-NrqlColumn -Row $rows[0] -Pattern '*latest*')
        $distinct = [int](Get-NrqlColumn -Row $rows[0] -Pattern '*uniqueCount*')

        if ($distinct -gt 1) {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail "$distinct versoes ativas depois da estabilizacao do rollout."
            continue
        }

        if ($latest -ne $configMapVersion) {
            Add-Check -Name "service.version de $service" -Status 'falha' -Detail "New Relic reporta '$latest' e o ConfigMap tem '$configMapVersion'."
            continue
        }

        Add-Check -Name "service.version de $service" -Status 'ok' -Detail "ConfigMap = imagem = New Relic = $latest"
    }
}

# ---------------------------------------------------------------------------
# Recursos provisionados e cadeia de notificacao.
#
# No fluxo atual a validacao acontece depois do Entrypoint: dashboard, policy,
# Synthetic Monitors e condicoes ja sao esperados. Duplicatas sao avisos
# operacionais, nao motivo para travar deploy.
# ---------------------------------------------------------------------------
Write-Step 'Recursos provisionados no New Relic'

$baseEntities = @(
    @{ Label = 'Dashboard'; Query = "name = '$($config.DashboardName)' AND type = 'DASHBOARD'" }
)
$syntheticEntities = @(
    @{ Label = 'Monitor Cadastro'; Query = "name = 'Oficina Cadastro - Health' AND type = 'MONITOR'" },
    @{ Label = 'Monitor Estoque'; Query = "name = 'Oficina Estoque - Health' AND type = 'MONITOR'" },
    @{ Label = 'Monitor Ordens'; Query = "name = 'Oficina Ordens - Health' AND type = 'MONITOR'" }
)

foreach ($entity in $baseEntities) {
    try {
        $found = Find-SingleEntity -Context $context -Query $entity.Query -Label $entity.Label
        if ($null -eq $found) {
            Add-Check -Name $entity.Label -Status 'falha' -Detail 'Nao encontrado.'
        }
        else {
            Add-Check -Name $entity.Label -Status 'ok' -Detail $found.guid
        }
    }
    catch {
        Add-Check -Name $entity.Label -Status 'falha' -Detail $_.Exception.Message
    }
}

if ($syntheticsExpected) {
    foreach ($entity in $syntheticEntities) {
        try {
            $found = Find-SingleEntity -Context $context -Query $entity.Query -Label $entity.Label
            if ($null -eq $found) {
                Add-Check -Name $entity.Label -Status 'falha' -Detail 'Nao encontrado.'
            }
            else {
                Add-Check -Name $entity.Label -Status 'ok' -Detail $found.guid
            }
        }
        catch {
            Add-Check -Name $entity.Label -Status 'falha' -Detail $_.Exception.Message
        }
    }
}
else {
    foreach ($entity in $syntheticEntities) {
        Add-Check -Name $entity.Label -Status 'pendente' -Detail 'ApiUrl nao informada para esta validacao manual.'
    }
}

try {
    $policySearch = Invoke-NerdGraph -Context $context -Query @'
query($accountId: Int!, $name: String!) {
  actor { account(id: $accountId) { alerts {
    policiesSearch(searchCriteria: {name: $name}) { policies { id name } }
  } } }
}
'@ -Variables @{ accountId = [int]$AccountId; name = $config.PolicyName }

    $policies = @($policySearch.data.actor.account.alerts.policiesSearch.policies | Where-Object { $_.name -eq $config.PolicyName })
    $policy = Select-CanonicalResource -Context $context -Resources $policies -Label "Policy '$($config.PolicyName)'"
    if ($null -eq $policy) {
        Add-Check -Name 'Policy' -Status 'falha' -Detail 'Nao encontrada.'
    }
    else {
        $policyId = $policy.id
        $policyDetail = if ($policies.Count -gt 1) { "$policyId (canonica entre $($policies.Count) ocorrencias)" } else { $policyId }
        Add-Check -Name 'Policy' -Status 'ok' -Detail $policyDetail

        $expectedSyntheticConditions = @('Oficina Cadastro - Health Failure', 'Oficina Estoque - Health Failure', 'Oficina Ordens - Health Failure')
        if ($syntheticsExpected) {
            $conditionsResponse = Invoke-NewRelicRest -Context $context -Method Get -Path "/alerts_location_failure_conditions/policies/$policyId.json"
            $conditionsValue = Get-ObjectPropertyValue -Object $conditionsResponse -Names @('location_failure_conditions', 'conditions')
            $monitorConditions = if ($null -eq $conditionsValue) { @() } else { @($conditionsValue) }
            foreach ($expected in $expectedSyntheticConditions) {
                $found = @($monitorConditions | Where-Object { $_.name -eq $expected })
                if ($found.Count -eq 0) {
                    Add-Check -Name "Condicao '$expected' na policy" -Status 'falha' -Detail 'Nao encontrada.'
                }
                elseif (@($found | Where-Object { -not (Test-ConditionHasMonitor -Condition $_) }).Count -gt 0) {
                    Add-Check -Name "Condicao '$expected' na policy" -Status 'falha' -Detail 'Existe condicao sem monitor associado: a indisponibilidade nao viraria e-mail.'
                }
                else {
                    if ($found.Count -gt 1) {
                        Add-NerdGraphWarning -Context $context -Message "Condicao de Synthetic '$expected' duplicada na policy $policyId. O DEPLOY atualiza todas, mas a duplicidade deve ser limpa manualmente quando possivel."
                    }
                    $references = (@($found | ForEach-Object {
                                $monitorId = Get-ObjectPropertyValue -Object $_ -Names @('monitor_id')
                                if (-not [string]::IsNullOrWhiteSpace([string]$monitorId)) { $monitorId } else { @($_.entities).Count }
                            }) -join ', ')
                    Add-Check -Name "Condicao '$expected' na policy" -Status 'ok' -Detail "$($found.Count) ocorrencia(s), monitor_id/entidades: $references"
                }
            }
        }
        else {
            foreach ($expected in $expectedSyntheticConditions) {
                Add-Check -Name "Condicao '$expected' na policy" -Status 'pendente' -Detail 'Aguardando URL publica para criar o monitor.'
            }
        }

        if ($notificationExpected) {
            $workflows = Invoke-NerdGraph -Context $context -Query @'
query($accountId: Int!) {
  actor { account(id: $accountId) { aiWorkflows {
    workflows { entities { id name workflowEnabled issuesFilter { predicates { attribute values } } } }
  } } }
}
'@ -Variables @{ accountId = [int]$AccountId }

            $matchingWorkflows = @($workflows.data.actor.account.aiWorkflows.workflows.entities | Where-Object { $_.name -eq $config.WorkflowName })
            if ($matchingWorkflows.Count -eq 0) {
                Add-Check -Name 'Workflow de notificacao' -Status 'falha' -Detail 'Nao encontrado.'
            }
            else {
                if ($matchingWorkflows.Count -gt 1) {
                    $ids = ($matchingWorkflows | ForEach-Object { $_.id }) -join ', '
                    Add-NerdGraphWarning -Context $context -Message "Workflow '$($config.WorkflowName)' duplicado. IDs: $ids."
                }

                $workflowsFilteringPolicy = @()
                foreach ($workflow in $matchingWorkflows) {
                    $predicates = @()
                    if ($null -ne $workflow.PSObject.Properties['issuesFilter'] -and $null -ne $workflow.issuesFilter) {
                        $predicates = @($workflow.issuesFilter.predicates)
                    }

                    foreach ($predicate in $predicates) {
                        if (@($predicate.values) -contains [string]$policyId) {
                            $workflowsFilteringPolicy += $workflow
                            break
                        }
                    }
                }

                if ($workflowsFilteringPolicy.Count -gt 0) {
                    $detail = if ($matchingWorkflows.Count -gt 1) {
                        "$($workflowsFilteringPolicy.Count) de $($matchingWorkflows.Count) workflow(s) filtram a policy $policyId"
                    }
                    else {
                        $matchingWorkflows[0].id
                    }
                    Add-Check -Name 'Workflow filtra a policy' -Status 'ok' -Detail $detail
                }
                else {
                    Add-Check -Name 'Workflow filtra a policy' -Status 'falha' -Detail 'Workflow existe mas nao filtra esta policy: o incidente nao viraria e-mail.'
                }
            }
        }
        else {
            Add-Check -Name 'Workflow de notificacao' -Status 'pendente' -Detail 'NEW_RELIC_NOTIFICATION_EMAIL nao informado.'
        }
    }
}
catch {
    Add-Check -Name 'Cadeia de notificacao' -Status 'falha' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Informativo: metricas de negocio e saga dependem de trafego autenticado, que o
# workflow nao gera. Sao registradas como pendentes de evidencia manual.
# ---------------------------------------------------------------------------
Write-Step 'Sinais de negocio (informativo)'
foreach ($sinal in @(
        @{ Name = 'Metricas oficina.os.*'; Query = "FROM Metric SELECT count(*) WHERE metricName LIKE 'oficina.os.%' SINCE 30 minutes ago" },
        @{ Name = 'Spans de SQS'; Query = "FROM Span SELECT count(*) WHERE name IN ('oficina.outbox.dispatch', 'oficina.inbox.consume') SINCE 30 minutes ago" })) {
    try {
        $rows = Invoke-Nrql -Query $sinal.Query
        $count = [int](Get-NrqlColumn -Row $(if ($rows.Count -gt 0) { $rows[0] } else { $null }) -Pattern '*count*')
        if ($count -gt 0) {
            Add-Check -Name $sinal.Name -Status 'ok' -Detail "$count registro(s)"
        }
        else {
            Add-Check -Name $sinal.Name -Status 'pendente' -Detail 'Sem trafego de negocio: pendente de evidencia manual.'
        }
    }
    catch {
        Add-Check -Name $sinal.Name -Status 'pendente' -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Resultado.
# ---------------------------------------------------------------------------
$failures = @($results | Where-Object { $_.Status -eq 'falha' })
$pending = @($results | Where-Object { $_.Status -eq 'pendente' })
$warnings = @(Get-NerdGraphWarnings -Context $context)

$summary = @(
    "Correlation ID: ``$CorrelationId``",
    "Janela da validacao: $($validationStartedAt.ToString('u'))",
    "Sinais de aplicacao obrigatorios: $($RequireApiSignals.IsPresent)",
    '',
    '| Verificacao | Resultado | Detalhe |',
    '|---|---|---|'
) + @($results | ForEach-Object { "| $($_.Name) | $($_.Status) | $($_.Detail) |" })

if ($pending.Count -gt 0) {
    $summary += @('', '### Pendentes', '') + @($pending | ForEach-Object { "- $($_.Name): $($_.Detail)" })
}

if ($warnings.Count -gt 0) {
    $summary += @('', '### Avisos operacionais', '') + @($warnings | ForEach-Object { "- $($_.Message)" })
}

if ($failures.Count -gt 0) {
    $summary += @('', '### Sinais que nao chegaram', '') + @($failures | ForEach-Object { "- $($_.Name): $($_.Detail)" })

    # Em falha, capturar estado do Collector e do node. Nunca imprimir secret: os
    # comandos abaixo nao leem Secret nem parametro.
    try {
        $instanceId = Get-SsmValue -Name '/oficina/infra/k8s/instance-id' -Region $AwsRegion
        $namespace = Get-SsmValue -Name '/oficina/infra/k8s/namespace' -Region $AwsRegion
        $diagnostico = Get-CollectorDiagnostics -InstanceId $instanceId -Region $AwsRegion -Config $config -Namespace $namespace
        Write-Host $diagnostico
        $summary += @('', '### Diagnostico do cluster', '', '```', $diagnostico, '```')
    }
    catch {
        $summary += @('', "Diagnostico do cluster indisponivel: $($_.Exception.Message)")
    }
}

Write-Summary -Title 'Validacao da observabilidade' -Body @()
$summaryPath = $env:GITHUB_STEP_SUMMARY
if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
    Add-Content -LiteralPath $summaryPath -Value $summary
}
else {
    $summary | ForEach-Object { Write-Host $_ }
}

Write-Host ''
Write-Host "Verificacoes: $($results.Count) | ok: $(@($results | Where-Object { $_.Status -eq 'ok' }).Count) | pendentes: $($pending.Count) | falhas: $($failures.Count)"

if ($failures.Count -gt 0) {
    throw "Validacao da observabilidade reprovada em $($failures.Count) verificacao(oes)."
}

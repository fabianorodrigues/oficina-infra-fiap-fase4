<#
.SYNOPSIS
    Valida os sinais de observabilidade no New Relic.

.DESCRIPTION
    Polling com timeout somente para sinais obrigatorios: telemetria chega em
    janelas variaveis, e um sleep unico ou reprova cedo demais ou desperdicia
    minutos. Sinais opcionais fazem uma consulta rapida e viram pendencia sem
    esperar.

    Duas categorias de gate:

      - sempre exigidos: sinais do cluster, do proprio Collector e existencia dos
        recursos provisionados que ja podem existir no ponto atual da sequencia;
      - exigidos so com ApplicationSignalsRequired: logs, spans, metricas HTTP e a
        comparacao tripla de service.version. Com a flag desligada eles sao
        registrados como "aguardando redeploy das APIs instrumentadas" e NAO
        marcam falha, porque na primeira passagem os Pods ainda rodam a versao
        anterior.

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
    [switch]$ApplicationSignalsRequired,
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
Espera o sinal aparecer quando ele e obrigatorio. Sinal opcional nao pode segurar
a primeira passagem do deploy: consulta uma vez e, se nao apareceu, registra
pendencia.
#>
function Wait-ForSignal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [switch]$Required
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
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
# Gates sempre exigidos: cluster e Collector.
# ---------------------------------------------------------------------------
Write-Step 'Sinais do cluster e do Collector'

Wait-ForSignal -Name 'Metricas do proprio Collector' -Required -Query @"
FROM Metric SELECT uniqueCount(service.instance.id)
WHERE metricName LIKE 'otelcol_%'
$sinceClause
"@ -Predicate {
    param($rows)
    $count = if ($rows.Count -gt 0) { [int]($rows[0].PSObject.Properties | Where-Object { $_.Name -like '*uniqueCount*' } | Select-Object -First 1).Value } else { 0 }
    [pscustomobject]@{ Ok = $count -gt 0; Detail = "$count instancia(s) do Collector" }
} | Out-Null

# Descoberta dos tipos K8s*Sample. Os nomes de atributo NAO sao contrato: eles vem
# desta descoberta, e nenhuma query e versionada antes de confirmar.
Write-Step 'Descoberta dos atributos de Kubernetes (gate 11)'
$k8sDiscovery = @{}
foreach ($sample in @('K8sNodeSample', 'K8sPodSample', 'K8sContainerSample')) {
    try {
        $rows = Invoke-Nrql -Query "FROM $sample SELECT keyset() SINCE 30 minutes ago"
        $keys = @()
        foreach ($row in $rows) {
            foreach ($prop in $row.PSObject.Properties) {
                if ($prop.Value -is [System.Array]) { $keys += @($prop.Value) }
                elseif ($null -ne $prop.Value) { $keys += [string]$prop.Value }
            }
        }
        $keys = @($keys | Sort-Object -Unique)
        $k8sDiscovery[$sample] = $keys
        if ($keys.Count -gt 0) {
            Add-Check -Name "keyset() de $sample" -Status 'ok' -Detail "$($keys.Count) atributo(s)"
        }
        else {
            Add-Check -Name "keyset() de $sample" -Status 'pendente' -Detail 'Nenhum atributo no periodo: widget e alerta ficam pendentes de descoberta.'
        }
    }
    catch {
        Add-Check -Name "keyset() de $sample" -Status 'pendente' -Detail $_.Exception.Message
    }
}

# CPU e memoria sao obrigatorios na coleta; o gate NRQL depende dos nomes reais.
$nodeKeys = if ($k8sDiscovery.ContainsKey('K8sNodeSample')) { $k8sDiscovery['K8sNodeSample'] } else { @() }
if ($nodeKeys.Count -gt 0) {
    $cpuKey = @($nodeKeys | Where-Object { $_ -match '(?i)cpu' }) | Select-Object -First 1
    $memoryKey = @($nodeKeys | Where-Object { $_ -match '(?i)memory' }) | Select-Object -First 1
    if ($cpuKey -and $memoryKey) {
        Add-Check -Name 'CPU e memoria do node presentes' -Status 'ok' -Detail "cpu=$cpuKey memoria=$memoryKey"
    }
    else {
        Add-Check -Name 'CPU e memoria do node presentes' -Status 'falha' -Detail 'Coleta de CPU/memoria e obrigatoria e nenhum atributo correspondente foi encontrado.'
    }
}
else {
    Add-Check -Name 'CPU e memoria do node presentes' -Status 'pendente' -Detail 'Aguardando primeiro ciclo de coleta do Collector.'
}

Write-Step 'Descoberta dos Kubernetes Events (gate 10)'
$eventFound = $false
foreach ($eventType in @('InfrastructureEvent', 'K8sEventSample', 'Log')) {
    try {
        $filtro = if ($eventType -eq 'Log') { "WHERE k8s.namespace.name IS NOT NULL" } else { '' }
        $rows = Invoke-Nrql -Query "FROM $eventType SELECT count(*) $filtro SINCE 30 minutes ago"
        $count = if ($rows.Count -gt 0) { [int]($rows[0].PSObject.Properties | Select-Object -First 1).Value } else { 0 }
        if ($count -gt 0) {
            Add-Check -Name "Kubernetes Events em $eventType" -Status 'ok' -Detail "$count registro(s)"
            $eventFound = $true
            break
        }
    }
    catch { continue }
}
if (-not $eventFound) {
    # Nenhum evento no periodo nao reprova: o requisito e nao criar query ficticia.
    Add-Check -Name 'Kubernetes Events' -Status 'pendente' -Detail 'Nenhum evento no periodo. Widget registrado como pendente de descoberta.'
}

# ---------------------------------------------------------------------------
# Gates de sinais de aplicacao.
# ---------------------------------------------------------------------------
Write-Step "Sinais das APIs (obrigatorios: $($ApplicationSignalsRequired.IsPresent))"

Wait-ForSignal -Name 'Logs dos tres servicos com o correlationId' -Required:$ApplicationSignalsRequired -Query @"
FROM Log SELECT count(*)
WHERE correlationId = '$CorrelationId'
FACET service.name
SINCE 10 minutes ago
"@ -Predicate {
    param($rows)
    $found = @($rows | ForEach-Object { $_.facet }) | Sort-Object -Unique
    $missing = @($services | Where-Object { $found -notcontains $_ })
    [pscustomobject]@{
        Ok     = $missing.Count -eq 0
        Detail = if ($missing.Count -eq 0) { "3 servicos: $($found -join ', ')" } else { "faltam: $($missing -join ', ')" }
    }
} | Out-Null

# Gate 9: nao basta o log existir. Campo aninhado em body significa que o filelog
# nao interpretou o JSON, e a correlacao com trace nao funciona.
Wait-ForSignal -Name 'Campos de log no nivel superior (gate 9)' -Required:$ApplicationSignalsRequired -Query @"
FROM Log SELECT keyset()
WHERE correlationId = '$CorrelationId'
SINCE 10 minutes ago
"@ -Predicate {
    param($rows)
    $keys = @()
    foreach ($row in $rows) {
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Value -is [System.Array]) { $keys += @($prop.Value) }
            elseif ($null -ne $prop.Value) { $keys += [string]$prop.Value }
        }
    }
    $keys = @($keys | Sort-Object -Unique)
    $required = @('service.name', 'service.version', 'deployment.environment', 'correlationId', 'trace.id', 'span.id')
    $missing = @($required | Where-Object { $keys -notcontains $_ })
    $nested = @($keys | Where-Object { $_ -like 'body.*' -or $_ -like 'message.*' })
    [pscustomobject]@{
        Ok     = $missing.Count -eq 0
        Detail = if ($missing.Count -eq 0) { 'todos os campos no nivel superior' }
                 elseif ($nested.Count -gt 0) { "campos aninhados detectados ($($nested[0])): configurar parsing JSON no filelog. Faltam: $($missing -join ', ')" }
                 else { "faltam: $($missing -join ', ')" }
    }
} | Out-Null

Wait-ForSignal -Name 'Span da API de origem com o correlationId' -Required:$ApplicationSignalsRequired -Query @"
FROM Span SELECT count(*)
WHERE correlationId = '$CorrelationId'
FACET service.name
SINCE 10 minutes ago
"@ -Predicate {
    param($rows)
    $found = @($rows | ForEach-Object { $_.facet }) | Sort-Object -Unique
    [pscustomobject]@{ Ok = $found.Count -gt 0; Detail = "servicos: $($found -join ', ')" }
} | Out-Null

Wait-ForSignal -Name 'Metricas HTTP dos tres servicos' -Required:$ApplicationSignalsRequired -Query @"
FROM Metric SELECT uniques(service.name)
WHERE metricName LIKE 'http.server.%'
SINCE 10 minutes ago
"@ -Predicate {
    param($rows)
    $found = @()
    foreach ($row in $rows) {
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Value -is [System.Array]) { $found += @($prop.Value) }
        }
    }
    $found = @($found | Sort-Object -Unique)
    $missing = @($services | Where-Object { $found -notcontains $_ })
    [pscustomobject]@{
        Ok     = $missing.Count -eq 0
        Detail = if ($missing.Count -eq 0) { "3 servicos" } else { "faltam: $($missing -join ', ')" }
    }
} | Out-Null

# Gate 12: semantica HTTP. Decide entre Metric e Span para o alerta de 5xx.
if ($ApplicationSignalsRequired) {
    Write-Step 'Descoberta da semantica HTTP (gate 12)'
    $httpShape = 'indefinida'
    try {
        $rows = Invoke-Nrql -Query "FROM Metric SELECT count(*) WHERE metricName = 'http.server.request.duration' SINCE 10 minutes ago"
        $count = if ($rows.Count -gt 0) { [int]($rows[0].PSObject.Properties | Select-Object -First 1).Value } else { 0 }
        if ($count -gt 0) {
            $httpShape = 'Metric'
            Add-Check -Name 'Semantica HTTP por Metric' -Status 'ok' -Detail "metricName http.server.request.duration com $count amostra(s)"
        }
    }
    catch { }

    if ($httpShape -eq 'indefinida') {
        try {
            $rows = Invoke-Nrql -Query "FROM Span SELECT count(*) WHERE span.kind = 'server' SINCE 10 minutes ago"
            $count = if ($rows.Count -gt 0) { [int]($rows[0].PSObject.Properties | Select-Object -First 1).Value } else { 0 }
            if ($count -gt 0) {
                $httpShape = 'Span'
                Add-Check -Name 'Semantica HTTP por Span (fallback)' -Status 'ok' -Detail "$count span(s) server. Alerta de 5xx deve usar Span."
            }
        }
        catch { }
    }

    if ($httpShape -eq 'indefinida') {
        Add-Check -Name 'Semantica HTTP (gate 12)' -Status 'falha' -Detail 'Nem Metric nem Span server encontrados.'
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

        $latest = [string](($rows[0].PSObject.Properties | Where-Object { $_.Name -like '*latest*' } | Select-Object -First 1).Value)
        $distinct = [int](($rows[0].PSObject.Properties | Where-Object { $_.Name -like '*uniqueCount*' } | Select-Object -First 1).Value)

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
# A primeira passagem pode acontecer antes do Entrypoint. Nesse ponto dashboard,
# policy e Collector sao obrigatorios, mas Synthetic Monitors dependem da URL
# publica e ficam pendentes ate /oficina/infra/api/url existir.
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
        Add-Check -Name $entity.Label -Status 'pendente' -Detail 'URL publica indisponivel antes do Entrypoint Deploy.'
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
    if ($policies.Count -ne 1) {
        Add-Check -Name 'Policy' -Status 'falha' -Detail "$($policies.Count) ocorrencia(s); esperado exatamente 1."
    }
    else {
        $policyId = $policies[0].id
        Add-Check -Name 'Policy' -Status 'ok' -Detail $policyId

        $expectedSyntheticConditions = @('Oficina Cadastro - Health Failure', 'Oficina Estoque - Health Failure', 'Oficina Ordens - Health Failure')
        if ($syntheticsExpected) {
            $conditions = Invoke-NerdGraph -Context $context -Query @'
query($accountId: Int!, $policyId: ID!) {
  actor { account(id: $accountId) { alerts {
    syntheticsMultiLocationConditionsSearch(searchCriteria: {policyId: $policyId}) {
      conditions { id name policyId entities }
    }
  } } }
}
'@ -Variables @{ accountId = [int]$AccountId; policyId = $policyId }

            $monitorConditions = @($conditions.data.actor.account.alerts.syntheticsMultiLocationConditionsSearch.conditions)
            foreach ($expected in $expectedSyntheticConditions) {
                $found = @($monitorConditions | Where-Object { $_.name -eq $expected })
                if ($found.Count -eq 1 -and @($found[0].entities).Count -gt 0) {
                    Add-Check -Name "Condicao '$expected' na policy" -Status 'ok' -Detail "referencia $(@($found[0].entities).Count) monitor(es)"
                }
                elseif ($found.Count -eq 1) {
                    Add-Check -Name "Condicao '$expected' na policy" -Status 'falha' -Detail 'Condicao existe mas nao referencia monitor: a indisponibilidade nao viraria e-mail.'
                }
                else {
                    Add-Check -Name "Condicao '$expected' na policy" -Status 'falha' -Detail "$($found.Count) ocorrencia(s); esperado 1."
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
            if ($matchingWorkflows.Count -ne 1) {
                Add-Check -Name 'Workflow de notificacao' -Status 'falha' -Detail "$($matchingWorkflows.Count) ocorrencia(s); esperado 1."
            }
            else {
                $filtersPolicy = $false
                foreach ($predicate in @($matchingWorkflows[0].issuesFilter.predicates)) {
                    if (@($predicate.values) -contains [string]$policyId) { $filtersPolicy = $true }
                }

                if ($filtersPolicy) {
                    Add-Check -Name 'Workflow filtra a policy' -Status 'ok' -Detail $matchingWorkflows[0].id
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
        $count = if ($rows.Count -gt 0) { [int]($rows[0].PSObject.Properties | Select-Object -First 1).Value } else { 0 }
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

$summary = @(
    "Correlation ID: ``$CorrelationId``",
    "Janela da validacao: $($validationStartedAt.ToString('u'))",
    "Sinais de aplicacao obrigatorios: $($ApplicationSignalsRequired.IsPresent)",
    '',
    '| Verificacao | Resultado | Detalhe |',
    '|---|---|---|'
) + @($results | ForEach-Object { "| $($_.Name) | $($_.Status) | $($_.Detail) |" })

if ($pending.Count -gt 0) {
    $summary += @('', '### Pendentes', '') + @($pending | ForEach-Object { "- $($_.Name): $($_.Detail)" })
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

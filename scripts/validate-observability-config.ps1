<#
.SYNOPSIS
    Guard de fonte unica da configuracao de observabilidade.

.DESCRIPTION
    Espelha validate-k3s-version.ps1: os valores que definem o que roda no cluster
    ficam em config/observability.yml e em nenhum outro lugar. Versao ou imagem
    duplicada em script, workflow ou values divergem em silencio, e o cluster passa
    a mudar sem que nenhum arquivo mude junto.

    Tambem reprova imagem com tag movel e NRQL de Alert Condition com clausula de
    janela, que a New Relic rejeita por serem processadas em streaming.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RepositoryRoot 'config/observability.yml'
}

$script:Failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:Failures.Add($Message) }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuracao de observabilidade nao encontrada: $ConfigPath"
}

# Leitura minima de YAML: so pares "chave: valor" achatados. Nao ha modulo de YAML
# garantido no runner nem no Windows PowerShell 5.1, e uma dependencia externa
# para ler seis campos nao se justifica.
function Get-YamlScalar {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Key
    )

    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*:\s*(.+?)\s*$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return $null
}

function Get-NestedImageValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$ImageName,
        [Parameter(Mandatory = $true)][string]$Field
    )

    $inImages = $false
    $inImage = $false
    foreach ($line in $Lines) {
        if ($line -match '^images:\s*$') {
            $inImages = $true
            $inImage = $false
            continue
        }
        if ($inImages -and $line -match '^\S') { break }
        if ($inImages -and $line -match "^\s{2}$([regex]::Escape($ImageName)):\s*$") {
            $inImage = $true
            continue
        }
        if ($inImage -and $line -match '^\s{2}\S') { $inImage = $false }
        if ($inImage -and $line -match "^\s{4}$([regex]::Escape($Field)):\s*(.+?)\s*$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return $null
}

$configLines = Get-Content -LiteralPath $ConfigPath
$officialPath = Join-Path $RepositoryRoot 'config/official.yml'
$expectedKubectlRepository = 'rancher/kubectl'
$expectedKubectlTag = $null

if (-not (Test-Path -LiteralPath $officialPath)) {
    Add-Failure 'config/official.yml ausente. A tag do kubectl deve acompanhar kubernetes.k3sVersion.'
}
else {
    $officialLines = Get-Content -LiteralPath $officialPath
    $k3sVersion = Get-YamlScalar -Lines $officialLines -Key 'k3sVersion'
    if ($k3sVersion -match '^(?<tag>v\d+\.\d+\.\d+)\+k3s\d+$') {
        $expectedKubectlTag = $Matches['tag']
    }
    else {
        Add-Failure "config/official.yml kubernetes.k3sVersion fora do formato vX.Y.Z+k3sN: $k3sVersion"
    }
}

$configKubectlRepository = Get-NestedImageValue -Lines $configLines -ImageName 'kubectl' -Field 'repository'
$configKubectlTag = Get-NestedImageValue -Lines $configLines -ImageName 'kubectl' -Field 'tag'
if ($configKubectlRepository -ne $expectedKubectlRepository) {
    Add-Failure "config/observability.yml images.kubectl.repository deve ser $expectedKubectlRepository (atual: $configKubectlRepository)."
}
if ($null -ne $expectedKubectlTag -and $configKubectlTag -ne $expectedKubectlTag) {
    Add-Failure "config/observability.yml images.kubectl.tag deve acompanhar config/official.yml sem o sufixo +k3sN: $expectedKubectlTag (atual: $configKubectlTag)."
}

# A chave `version` aparece em dois blocos (helm e chart), portanto a leitura e
# feita por bloco: um Get-YamlScalar achatado devolveria a primeira ocorrencia e
# confundiria versao do Helm com versao do chart.
$helmBlock = $false
$chartBlock = $false
$helmVersionValue = $null
$chartVersionValue = $null
$helmSha = $null
$helmMajor = $null
$historyMax = $null
$newRelicBlock = $false
$gatewayDeployment = $null
$gatewayService = $null
foreach ($line in $configLines) {
    if ($line -match '^newRelic:\s*$') { $newRelicBlock = $true; $helmBlock = $false; $chartBlock = $false; continue }
    if ($line -match '^helm:\s*$') { $newRelicBlock = $false; $helmBlock = $true; $chartBlock = $false; continue }
    if ($line -match '^chart:\s*$') { $newRelicBlock = $false; $chartBlock = $true; $helmBlock = $false; continue }
    if ($line -match '^\S') { $newRelicBlock = $false; $helmBlock = $false; $chartBlock = $false }

    if ($newRelicBlock) {
        if ($line -match '^\s+gatewayDeployment:\s*(.+?)\s*$') { $gatewayDeployment = $Matches[1].Trim() }
        if ($line -match '^\s+gatewayService:\s*(.+?)\s*$') { $gatewayService = $Matches[1].Trim() }
    }
    if ($helmBlock) {
        if ($line -match '^\s+version:\s*(.+?)\s*$') { $helmVersionValue = $Matches[1].Trim() }
        if ($line -match '^\s+majorVersion:\s*(.+?)\s*$') { $helmMajor = $Matches[1].Trim() }
        if ($line -match '^\s+sha256:\s*(.+?)\s*$') { $helmSha = $Matches[1].Trim() }
        if ($line -match '^\s+historyMax:\s*(.+?)\s*$') { $historyMax = $Matches[1].Trim() }
    }
    if ($chartBlock -and $line -match '^\s+version:\s*(.+?)\s*$') { $chartVersionValue = $Matches[1].Trim() }
}

if ([string]::IsNullOrWhiteSpace($chartVersionValue)) { Add-Failure 'chart.version ausente em config/observability.yml.' }
elseif ($chartVersionValue -eq 'latest') { Add-Failure 'chart.version nao pode ser latest.' }

if ([string]::IsNullOrWhiteSpace($helmVersionValue)) { Add-Failure 'helm.version ausente.' }
if ($helmMajor -ne '3') { Add-Failure "helm.majorVersion deve ser 3: o Helm 4 migrou post-renderer para plugins e quebraria post-render-newrelic.sh (atual: $helmMajor)." }
if ([string]::IsNullOrWhiteSpace($helmSha) -or $helmSha -notmatch '^[0-9a-f]{64}$') { Add-Failure 'helm.sha256 ausente ou fora do formato SHA-256.' }
if ($historyMax -ne '2') { Add-Failure "helm.historyMax deve ser 2 para alinhar o historico do Helm com a retencao de Secrets (atual: $historyMax)." }
if ($gatewayDeployment -ne 'nr-otel-nr-k8s-otel-collector-deployment') { Add-Failure "newRelic.gatewayDeployment deve refletir o Deployment renderizado pelo chart 0.14.0 (esperado: nr-otel-nr-k8s-otel-collector-deployment; atual: $gatewayDeployment)." }
if ($gatewayService -ne 'nr-k8s-otel-collector-gateway') { Add-Failure "newRelic.gatewayService deve refletir o Service renderizado pelo chart 0.14.0 (esperado: nr-k8s-otel-collector-gateway; atual: $gatewayService)." }

# ---------------------------------------------------------------------------
# Fonte unica: a versao do chart e a do Helm nao podem aparecer fora do config.
# ---------------------------------------------------------------------------
$scanRoots = @('observability', 'scripts', '.github') |
    ForEach-Object { Join-Path $RepositoryRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }

$scanFiles = @()
foreach ($root in $scanRoots) {
    $scanFiles += Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.sh', '*.yml', '*.yaml', '*.json' -ErrorAction SilentlyContinue
}

foreach ($file in $scanFiles) {
    $relative = $file.FullName.Substring($RepositoryRoot.Length).TrimStart('\', '/')
    # O proprio guard cita os valores nas mensagens de erro.
    if ($relative -like '*validate-observability-config.ps1') { continue }

    $content = Get-Content -LiteralPath $file.FullName -Raw

    if ($null -ne $chartVersionValue -and $content -match "nr-k8s-otel-collector[^\r\n]*--version\s+$([regex]::Escape($chartVersionValue))") {
        Add-Failure "$relative fixa a versao do chart literalmente. Ela deve vir de config/observability.yml."
    }
    if ($null -ne $helmSha -and $content -match [regex]::Escape($helmSha) -and $relative -notlike 'config/*') {
        Add-Failure "$relative repete o checksum do Helm. A fonte unica e config/observability.yml."
    }
}

# ---------------------------------------------------------------------------
# newrelic-values.yaml: sem secret e sem tag movel.
# ---------------------------------------------------------------------------
$valuesPath = Join-Path $RepositoryRoot 'observability/newrelic-values.yaml'
if (-not (Test-Path -LiteralPath $valuesPath)) {
    Add-Failure 'observability/newrelic-values.yaml ausente.'
}
else {
    $valuesLines = Get-Content -LiteralPath $valuesPath
    $valuesRaw = $valuesLines -join "`n"

    if ($valuesLines | Select-String -Pattern '^\s*licenseKey\s*:' -Quiet) {
        Add-Failure 'newrelic-values.yaml declara licenseKey. O arquivo e versionado e nao pode conter secret.'
    }
    if ($valuesLines | Select-String -Pattern '^\s*customSecretName\s*:' -Quiet) {
        Add-Failure 'newrelic-values.yaml declara customSecretName. O nome e versionado por execucao e chega por --set-string, senao o rollback perde a licenca da revisao anterior.'
    }
    foreach ($pattern in @('NRAK-[A-Za-z0-9]{10,}', 'NRAA-[A-Za-z0-9]{10,}')) {
        if ($valuesRaw -match $pattern) { Add-Failure "newrelic-values.yaml contem valor com formato de chave da New Relic ($pattern)." }
    }
    if ($valuesRaw -match '(?m)^\s*tag:\s*["'']?latest["'']?\s*$') {
        Add-Failure 'newrelic-values.yaml usa tag latest. Toda imagem precisa de tag fixa.'
    }
    if ($valuesRaw -match '(?m)^fullnameOverride:\s*') {
        Add-Failure 'newrelic-values.yaml declara fullnameOverride no topo. O chart 0.14.0 ignora isso para o Service do gateway e mascara nomes inexistentes.'
    }
    if ($valuesRaw -match '(?m)^image:\s*$') {
        Add-Failure 'newrelic-values.yaml declara image: no topo. O chart 0.14.0 usa images.collector; image: seria ignorado.'
    }
    if ($valuesRaw -match '(?m)^kubectl:\s*$') {
        Add-Failure 'newrelic-values.yaml declara kubectl: no topo. O chart 0.14.0 usa images.kubectl; kubectl.image seria ignorado.'
    }
    if ($valuesRaw -match 'newrelic/nrdot-collector-k8s') {
        Add-Failure 'newrelic-values.yaml usa newrelic/nrdot-collector-k8s, imagem depreciada e indisponivel para 1.19.0. Use newrelic/nrdot-collector.'
    }
    if ($valuesRaw -notmatch 'repository:\s*newrelic/nrdot-collector\b') {
        Add-Failure 'newrelic-values.yaml nao fixa images.collector.repository=newrelic/nrdot-collector.'
    }
    if ($valuesRaw -notmatch '(?m)^images:\s*$') {
        Add-Failure 'newrelic-values.yaml nao declara images:. collector/kubectl precisam ser fixados nas chaves suportadas pelo chart.'
    }
    if ((Get-NestedImageValue -Lines $valuesLines -ImageName 'collector' -Field 'tag') -ne '1.19.0') { Add-Failure 'newrelic-values.yaml nao fixa images.collector.tag=1.19.0.' }
    if ((Get-NestedImageValue -Lines $valuesLines -ImageName 'kubectl' -Field 'repository') -ne $expectedKubectlRepository) {
        Add-Failure "newrelic-values.yaml nao fixa images.kubectl.repository=$expectedKubectlRepository."
    }
    if ($null -ne $expectedKubectlTag -and (Get-NestedImageValue -Lines $valuesLines -ImageName 'kubectl' -Field 'tag') -ne $expectedKubectlTag) {
        Add-Failure "newrelic-values.yaml nao fixa images.kubectl.tag=$expectedKubectlTag."
    }
    if ($valuesRaw -notmatch 'updateStrategy:\s*Recreate') {
        Add-Failure 'newrelic-values.yaml nao define kube-state-metrics.updateStrategy=Recreate. O KSM vem do values, nao do post-renderer.'
    }
    if ($valuesRaw -notmatch 'collectorObservability:') {
        Add-Failure 'newrelic-values.yaml nao habilita collectorObservability. Sem ele o alerta "Collector sem sinal" nao tem sinal para consultar.'
    }
}

# ---------------------------------------------------------------------------
# Gramatica das NRQL. Dashboard, validacao e alerta seguem regras diferentes:
# aplicar a mesma regra as tres categorias reprova query legitima ou aprova
# condicao que a New Relic rejeita.
# ---------------------------------------------------------------------------
$alertsPath = Join-Path $RepositoryRoot 'observability/alerts/oficina-alerts.json'
if (Test-Path -LiteralPath $alertsPath) {
    $alerts = Get-Content -LiteralPath $alertsPath -Raw | ConvertFrom-Json
    foreach ($condition in $alerts.conditions) {
        foreach ($field in @('nrql', 'nrqlFallback')) {
            # Condicao de Synthetic nao tem NRQL: sob StrictMode, acessar a
            # propriedade inexistente e erro, nao valor nulo.
            if ($null -eq $condition.PSObject.Properties[$field]) { continue }
            $query = $condition.$field
            if ([string]::IsNullOrWhiteSpace($query)) { continue }

            if ($query -notmatch '\bSELECT\b') { Add-Failure "Condicao '$($condition.name)' sem SELECT." }
            if ($query -notmatch '\bFROM\b') { Add-Failure "Condicao '$($condition.name)' sem FROM." }
            foreach ($clause in @('SINCE', 'UNTIL', 'TIMESERIES', 'LIMIT')) {
                if ($query -match "\b$clause\b") {
                    Add-Failure "Condicao '$($condition.name)' usa $clause. Alert Condition e streaming: a janela vive em aggregationWindow e thresholdDuration."
                }
            }
        }

        if ($condition.type -eq 'NRQL_STATIC') {
            if ($null -eq $condition.PSObject.Properties['aggregationWindow']) { Add-Failure "Condicao '$($condition.name)' sem aggregationWindow." }
            if ($null -eq $condition.PSObject.Properties['aggregationMethod']) { Add-Failure "Condicao '$($condition.name)' sem aggregationMethod." }

            # Condicao de loss of signal nao usa threshold: o problema e a ausencia
            # de dado, e um threshold sobre serie vazia nunca dispararia.
            if ($null -eq $condition.PSObject.Properties['lossOfSignal']) {
                if ($null -eq $condition.PSObject.Properties['thresholdDuration']) { Add-Failure "Condicao '$($condition.name)' sem thresholdDuration." }
                if ($null -eq $condition.PSObject.Properties['thresholdOccurrences']) { Add-Failure "Condicao '$($condition.name)' sem thresholdOccurrences." }
            }
        }
    }
}

$dashboardPath = Join-Path $RepositoryRoot 'observability/dashboards/oficina-overview.json'
if (Test-Path -LiteralPath $dashboardPath) {
    $dashboard = Get-Content -LiteralPath $dashboardPath -Raw | ConvertFrom-Json
    foreach ($page in $dashboard.pages) {
        foreach ($widget in $page.widgets) {
            foreach ($query in $widget.rawConfiguration.nrqlQueries) {
                # Widget nao precisa de SINCE: o time picker global do dashboard e
                # comportamento desejado.
                if ($query.query -notmatch '\bSELECT\b' -or $query.query -notmatch '\bFROM\b') {
                    Add-Failure "Widget '$($widget.title)' na pagina '$($page.name)' sem SELECT ou FROM."
                }
            }
        }
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Host 'Configuracao de observabilidade reprovada:'
    foreach ($failure in $script:Failures) { Write-Host " - $failure" }
    throw "Validacao da configuracao de observabilidade falhou com $($script:Failures.Count) problema(s)."
}

Write-Host "Configuracao de observabilidade valida (chart $chartVersionValue, Helm $helmVersionValue)."

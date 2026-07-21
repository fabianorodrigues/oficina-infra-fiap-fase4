[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$officialPath = Join-Path $root 'config/official.yml'
$contractPath = Join-Path $root 'config/resource-contract.yml'

function Fail([string]$Message) {
    throw "Platform config validation failed: $Message"
}

function Assert-MatchCount([string]$Content, [string]$Pattern, [int]$Expected, [string]$Message) {
    $count = ([regex]::Matches($Content, $Pattern, 'Multiline')).Count
    if ($count -ne $Expected) {
        Fail "$Message Expected $Expected, found $count."
    }
}

if (-not (Test-Path -LiteralPath $officialPath)) { Fail "Missing config/official.yml." }
if (-not (Test-Path -LiteralPath $contractPath)) { Fail "Missing config/resource-contract.yml." }

$official = Get-Content -LiteralPath $officialPath -Raw
$contract = Get-Content -LiteralPath $contractPath -Raw
$combined = "$official`n$contract"

if ($official -notmatch '(?ms)^project:\s+.*?^\s{2}name: oficina\s*$') { Fail "project.name must be oficina." }
if ($official -notmatch '(?ms)^cluster:\s+.*?^\s{2}name: oficina\s*$') { Fail "cluster.name must be oficina." }
if ($official -notmatch '(?ms)^cluster:\s+.*?^\s{2}namespace: oficina\s*$') { Fail "cluster.namespace must be oficina." }
if ($official -notmatch '(?ms)^observability:\s+.*?^\s{2}enableNewRelic: false\s*$') { Fail "observability.enableNewRelic must start as false." }

$kubernetesVersionMatch = [regex]::Match($official, '(?m)^\s{2}kubernetesVersion:\s*"?([^"\r\n]*)"?\s*$')
if (-not $kubernetesVersionMatch.Success) { Fail "cluster.kubernetesVersion must be declared." }
$kubernetesVersion = $kubernetesVersionMatch.Groups[1].Value.Trim()
if ($kubernetesVersion.Length -gt 0) {
    if ($kubernetesVersion -notmatch '^\d+\.\d+$') { Fail "cluster.kubernetesVersion must use the EKS minor format, for example 1.30." }
    $versionParts = $kubernetesVersion.Split('.')
    $major = [int]$versionParts[0]
    $minor = [int]$versionParts[1]
    if ($major -lt 1 -or ($major -eq 1 -and $minor -lt 28)) {
        Fail "cluster.kubernetesVersion must be empty for the AWS default or explicitly set to 1.28 or newer."
    }
}

Assert-MatchCount $official '(?m)^\s{2}(cadastro|estoque|ordens): oficina-[a-z-]+\s*$' 3 'Exactly three ECR repository names are required.'
Assert-MatchCount $contract '(?m)^\s{2}[A-Za-z]+.*QueueUrl: /oficina/infra/sqs/.+/url\s*$' 2 'Exactly two main queue URL outputs are required.'
Assert-MatchCount $contract '(?m)^\s{2}[A-Za-z]+.*DlqUrl: /oficina/infra/sqs/.+/url\s*$' 2 'Exactly two DLQ URL outputs are required.'

$forbiddenKeyPattern = '(?m)^\s*' + 'environ' + 'ment\s*:'
$forbiddenSuffixPattern = '(' + '-' + 'dev|' + '-' + 'hml|' + '-' + 'prod|' + '/' + 'dev/)'
if ($combined -match $forbiddenKeyPattern) { Fail "Do not declare that forbidden key." }
if ($combined -match $forbiddenSuffixPattern) { Fail "Do not use dev, hml, or prod suffixes/paths." }
if ($combined -match '(?i)(password|license[_-]?key|access[_-]?key|secret[_-]?access|token)\s*:\s*[^/\s]') {
    Fail "Hardcoded secret-like values are not allowed."
}

$paths = [regex]::Matches($contract, '/oficina/[A-Za-z0-9/_-]+') | ForEach-Object { $_.Value }
if ($paths.Count -eq 0) { Fail "No /oficina/ paths found in resource contract." }
foreach ($path in $paths) {
    if (-not $path.StartsWith('/oficina/')) { Fail "Invalid path prefix: $path" }
}

$longPolling = [int]([regex]::Match($official, '(?m)^\s{2}longPollingSeconds: (\d+)\s*$').Groups[1].Value)
$visibility = [int]([regex]::Match($official, '(?m)^\s{2}visibilityTimeoutSeconds: (\d+)\s*$').Groups[1].Value)
$maxReceive = [int]([regex]::Match($official, '(?m)^\s{2}maxReceiveCount: (\d+)\s*$').Groups[1].Value)
$retention = [int]([regex]::Match($official, '(?m)^\s{2}messageRetentionSeconds: (\d+)\s*$').Groups[1].Value)
$dlqRetention = [int]([regex]::Match($official, '(?m)^\s{2}dlqRetentionSeconds: (\d+)\s*$').Groups[1].Value)

if ($longPolling -lt 0 -or $longPolling -gt 20) { Fail "SQS long polling must be between 0 and 20 seconds." }
if ($visibility -lt 0 -or $visibility -gt 43200) { Fail "SQS visibility timeout must be between 0 and 43200 seconds." }
if ($maxReceive -lt 1 -or $maxReceive -gt 1000) { Fail "SQS maxReceiveCount must be between 1 and 1000." }
if ($retention -lt 60 -or $retention -gt 1209600) { Fail "SQS message retention must be between 60 and 1209600 seconds." }
if ($dlqRetention -lt $retention -or $dlqRetention -gt 1209600) { Fail "DLQ retention must be at least main queue retention and at most 1209600 seconds." }

Write-Host 'Platform versioned configuration is valid.'

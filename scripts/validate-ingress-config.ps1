# Validates config/ingress-routes.json without AWS or Kubernetes access.
# Targets PowerShell 7 (CI runs it with pwsh) and also runs under Windows PowerShell 5.1.
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $root = Split-Path -Parent $PSScriptRoot
    $ConfigPath = Join-Path $root 'config/ingress-routes.json'
}

$script:Failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:Failures.Add($Message) }

# Expected, non-sensitive contract values for the shared internal ALB.
$expectedServices = @{
    cadastro = 'oficina-cadastro'
    estoque  = 'oficina-estoque'
    ordens   = 'oficina-ordens-servico'
}
# Routes that must never be reachable through the ALB. A public prefix that is an
# ancestor of any of these (or that starts with any of these) is a hard failure.
$forbiddenPrefixes = @('/api/internal', '/api/dev')
$forbiddenExact = @('/ready', '/api')

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Ingress config validation failed: missing $ConfigPath."
}

$raw = Get-Content -LiteralPath $ConfigPath -Raw
try {
    $config = $raw | ConvertFrom-Json
} catch {
    throw "Ingress config validation failed: invalid JSON. $($_.Exception.Message)"
}

# --- Ingress identity ------------------------------------------------------
$ingress = $config.ingress
if ($null -eq $ingress) { Add-Failure 'Missing ingress section.' }
else {
    if ($ingress.name -ne 'oficina') { Add-Failure "ingress.name must be 'oficina' (found '$($ingress.name)')." }
    if ($ingress.namespace -ne 'oficina') { Add-Failure "ingress.namespace must be 'oficina' (found '$($ingress.namespace)')." }
    if ($ingress.ingressClassName -ne 'alb') { Add-Failure "ingress.ingressClassName must be 'alb' (found '$($ingress.ingressClassName)')." }
    if ($ingress.loadBalancerName -ne 'oficina') { Add-Failure "ingress.loadBalancerName must be 'oficina' (found '$($ingress.loadBalancerName)')." }
    if ($ingress.scheme -ne 'internal') { Add-Failure "ingress.scheme must be 'internal' (found '$($ingress.scheme)')." }
    if ($ingress.targetType -ne 'ip') { Add-Failure "ingress.targetType must be 'ip' (found '$($ingress.targetType)')." }
    if ([int]$ingress.listenerPort -ne 80) { Add-Failure "ingress.listenerPort must be 80 (found '$($ingress.listenerPort)')." }
}

# --- Health check ----------------------------------------------------------
$health = $config.healthCheck
if ($null -eq $health) { Add-Failure 'Missing healthCheck section.' }
else {
    if ($health.path -ne '/health') { Add-Failure "healthCheck.path must be '/health' (found '$($health.path)')." }
    if ($health.successCodes -ne '200-399') { Add-Failure "healthCheck.successCodes must be '200-399' (found '$($health.successCodes)')." }
    foreach ($n in @('intervalSeconds', 'timeoutSeconds', 'healthyThreshold', 'unhealthyThreshold')) {
        if ($health.$n -isnot [int] -and -not ($health.$n -as [int])) { Add-Failure "healthCheck.$n must be an integer." }
    }
    if (($health.timeoutSeconds -as [int]) -ge ($health.intervalSeconds -as [int])) {
        Add-Failure 'healthCheck.timeoutSeconds must be smaller than intervalSeconds.'
    }
}

# --- Backends and routes ---------------------------------------------------
$backends = @($config.backends)
if ($backends.Count -ne 3) { Add-Failure "Exactly three backends are required (found $($backends.Count))." }

$allPaths = [System.Collections.Generic.List[string]]::new()
foreach ($backend in $backends) {
    $id = $backend.id
    $expected = $expectedServices[$id]
    if ($null -eq $expected) {
        Add-Failure "Unexpected backend id '$id'. Allowed: $($expectedServices.Keys -join ', ')."
    } elseif ($backend.serviceName -ne $expected) {
        Add-Failure "Backend '$id' serviceName must be '$expected' (found '$($backend.serviceName)')."
    }

    $port = $backend.servicePort -as [int]
    if ($null -eq $port -or $port -lt 1 -or $port -gt 65535) {
        Add-Failure "Backend '$id' servicePort must be between 1 and 65535 (found '$($backend.servicePort)')."
    }

    $paths = @($backend.paths)
    if ($paths.Count -lt 1) {
        Add-Failure "Backend '$id' must expose at least one route."
    }

    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { Add-Failure "Backend '$id' has an empty route."; continue }
        if (-not $p.StartsWith('/')) { Add-Failure "Route '$p' (backend '$id') must start with '/'." }
        if ($p -eq '/') { Add-Failure "Route '/' (catch-all) is not allowed (backend '$id')." }
        if ($forbiddenExact -contains $p) { Add-Failure "Route '$p' is forbidden (backend '$id')." }
        foreach ($f in $forbiddenPrefixes) {
            if ($p -eq $f -or $p.StartsWith("$f/")) { Add-Failure "Route '$p' exposes forbidden namespace '$f' (backend '$id')." }
        }
        if ($p -match '\*') { Add-Failure "Route '$p' must not contain a wildcard (backend '$id')." }
        $allPaths.Add($p)
    }
}

# --- Health header routing -------------------------------------------------
# Three internal actions select the backend by the trusted x-oficina-health-target
# header. The API Gateway rewrites external /health/<service> to /health and sets
# this header; the ALB never exposes a bare /health without it.
$healthRouting = $config.healthRouting
if ($null -eq $healthRouting) {
    Add-Failure 'Missing healthRouting section (header-based health routing is required).'
} else {
    if ($healthRouting.header -ne 'x-oficina-health-target') { Add-Failure "healthRouting.header must be 'x-oficina-health-target' (found '$($healthRouting.header)')." }
    if ($healthRouting.path -ne '/health') { Add-Failure "healthRouting.path must be '/health' (found '$($healthRouting.path)')." }
    if (@('ImplementationSpecific', 'Exact', 'Prefix') -notcontains $healthRouting.pathType) { Add-Failure "healthRouting.pathType must be ImplementationSpecific, Exact or Prefix (found '$($healthRouting.pathType)')." }

    $healthTargets = @($healthRouting.targets)
    $expectedTargets = @('cadastro', 'estoque', 'ordens')
    if ($healthTargets.Count -ne 3) { Add-Failure "healthRouting.targets must contain exactly three entries (found $($healthTargets.Count))." }
    foreach ($t in $expectedTargets) {
        if ($healthTargets -notcontains $t) { Add-Failure "healthRouting.targets must include '$t'." }
    }
    foreach ($t in $healthTargets) {
        if ($expectedServices.Keys -notcontains $t) { Add-Failure "healthRouting target '$t' has no matching backend id." }
    }
}

# --- Global route safety ---------------------------------------------------
# Duplicate detection across all backends.
$seen = @{}
foreach ($p in $allPaths) {
    if ($seen.ContainsKey($p)) { Add-Failure "Duplicate route '$p'." } else { $seen[$p] = $true }
}

# A public route must never be an ancestor of a forbidden route.
$forbiddenRoutes = @('/api/internal', '/api/dev', '/ready', '/api')
foreach ($p in $allPaths) {
    foreach ($f in $forbiddenRoutes) {
        if ($f -eq $p -or $f.StartsWith("$p/")) {
            Add-Failure "Public route '$p' is an ancestor of forbidden route '$f'."
        }
    }
}

# Overlap detection between public routes (one prefix of another). Legitimate only
# when both target the same backend service; otherwise it is a hard failure.
$pathToService = @{}
foreach ($backend in $backends) {
    foreach ($p in @($backend.paths)) { $pathToService[$p] = $backend.serviceName }
}
foreach ($a in $allPaths) {
    foreach ($b in $allPaths) {
        if ($a -eq $b) { continue }
        if ($b.StartsWith("$a/")) {
            if ($pathToService[$a] -ne $pathToService[$b]) {
                Add-Failure "Route '$a' overlaps '$b' across different services ($($pathToService[$a]) vs $($pathToService[$b]))."
            } else {
                Write-Host "Note: route '$b' is covered by '$a' on the same service ($($pathToService[$a])). Redundant but safe."
            }
        }
    }
}

# --- SSM contract paths ----------------------------------------------------
$ssmValues = [System.Collections.Generic.List[string]]::new()
if ($config.aws) { foreach ($k in $config.aws.PSObject.Properties.Name) { $ssmValues.Add([string]$config.aws.$k) } }
if ($config.ssmOutputs) { foreach ($k in $config.ssmOutputs.PSObject.Properties.Name) { $ssmValues.Add([string]$config.ssmOutputs.$k) } }
if ($ssmValues.Count -eq 0) { Add-Failure 'No SSM parameter paths declared.' }
foreach ($v in $ssmValues) {
    if (-not $v.StartsWith('/oficina/')) { Add-Failure "SSM parameter '$v' must start with '/oficina/'." }
}

# --- No real AWS values or environment markers -----------------------------
if ($raw -match 'subnet-[0-9a-fA-F]{8,}') { Add-Failure 'Configuration must not contain a real subnet ID.' }
if ($raw -match 'arn:aws') { Add-Failure 'Configuration must not contain a real ARN.' }
if ($raw -match '(?i)amazonaws\.com') { Add-Failure 'Configuration must not contain a real AWS DNS name.' }
if ($raw -match '(?i)internet-facing') { Add-Failure 'Configuration must not request an internet-facing scheme.' }
if ($raw -match '(?i)fase\s*-?\s*3') { Add-Failure 'Configuration must not reference the previous phase.' }
if ($raw -match '(?i)(-dev|-hml|-staging|-prod)(\b|["/])') { Add-Failure 'Configuration must not use dev/hml/staging/prod suffixes.' }
if ($raw -match '/dev/') { Add-Failure 'Configuration must not use a /dev/ path segment.' }

# --- Result ----------------------------------------------------------------
if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Ingress configuration is INVALID:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host " - $f" }
    throw "Ingress config validation failed with $($script:Failures.Count) issue(s)."
}

Write-Host "Ingress versioned configuration is valid. $($allPaths.Count) public route(s) across $($backends.Count) backend(s)."

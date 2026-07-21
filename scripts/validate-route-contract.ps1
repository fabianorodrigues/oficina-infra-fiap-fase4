# Cross-validates config/entrypoint.json against config/ingress-routes.json.
# No AWS access, no microservice runtime access. Exits non-zero on any issue and
# prints a sanitized route matrix.
# Targets PowerShell 7 (CI runs it with pwsh) and also runs under Windows PowerShell 5.1.
[CmdletBinding()]
param(
    [string]$EntrypointPath,
    [string]$IngressPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($EntrypointPath)) { $EntrypointPath = Join-Path $root 'config/entrypoint.json' }
if ([string]::IsNullOrWhiteSpace($IngressPath)) { $IngressPath = Join-Path $root 'config/ingress-routes.json' }

$script:Failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:Failures.Add($Message) }

foreach ($f in @($EntrypointPath, $IngressPath)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Route contract validation failed: missing $f." }
}

$entrypoint = Get-Content -LiteralPath $EntrypointPath -Raw | ConvertFrom-Json
$ingress = Get-Content -LiteralPath $IngressPath -Raw | ConvertFrom-Json

$validMethods = @('ANY', 'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD')
$validRoles = @('Cliente', 'Funcionario', 'Admin')
$albDestinations = @('ALB_PROTECTED', 'ALB_PUBLIC', 'ALB_HEALTH')

# Ingress prefixes per backend id.
$ingressPrefixes = @{}
foreach ($backend in $ingress.backends) {
    $ingressPrefixes[[string]$backend.id] = @($backend.paths)
}
$ingressHealthTargets = @()
if ($ingress.healthRouting) { $ingressHealthTargets = @($ingress.healthRouting.targets) }

$allowlist = @($entrypoint.publicAllowlist)

function Split-RouteKey([string]$RouteKey) {
    $parts = $RouteKey -split '\s+', 2
    if ($parts.Count -ne 2) { return $null }
    return [pscustomobject]@{ Method = $parts[0]; Path = $parts[1] }
}

function Get-BasePath([string]$Path) {
    # Strip a trailing greedy proxy segment for coverage checks.
    return ($Path -replace '/\{proxy\+\}$', '')
}

function Test-CoveredByPrefix([string]$Path, [string[]]$Prefixes) {
    $base = Get-BasePath $Path
    foreach ($p in $Prefixes) {
        if ($base -eq $p -or $base.StartsWith("$p/")) { return $true }
    }
    return $false
}

$matrix = [System.Collections.Generic.List[pscustomobject]]::new()
$routeKeys = [System.Collections.Generic.List[string]]::new()
$noneRoutePaths = [System.Collections.Generic.List[string]]::new()
$customRoutePaths = [System.Collections.Generic.List[string]]::new()

foreach ($r in @($entrypoint.routes)) {
    $key = [string]$r.routeKey
    $routeKeys.Add($key)
    $parsed = Split-RouteKey $key
    if ($null -eq $parsed) { Add-Failure "Route key '$key' is not '<METHOD> <path>'."; continue }

    $method = $parsed.Method
    $path = $parsed.Path
    if ($validMethods -notcontains $method) { Add-Failure "Route '$key' uses an unsupported method '$method'." }
    if (-not $path.StartsWith('/')) { Add-Failure "Route '$key' path must start with '/'." }

    $roles = @($r.requiredRoles)
    foreach ($role in $roles) {
        if ($validRoles -notcontains $role) { Add-Failure "Route '$key' declares unknown role '$role'." }
    }

    switch ($r.destination) {
        'AUTH_LAMBDA' {
            if ($r.backend -eq 'cadastro' -or $r.backend -eq 'estoque' -or $r.backend -eq 'ordens') {
                Add-Failure "Auth route '$key' must not target an ALB backend."
            }
            if ($allowlist -notcontains $key) { Add-Failure "Auth route '$key' must be in publicAllowlist." }
            $noneRoutePaths.Add((Get-BasePath $path))
        }
        'ALB_HEALTH' {
            $target = [string]$r.healthTarget
            $expectedPath = "/health/$target"
            if ($path -ne $expectedPath) { Add-Failure "Health route '$key' path must be '$expectedPath'." }
            if ($ingressHealthTargets -notcontains $target) { Add-Failure "Health route '$key' target '$target' is not declared in ingress healthRouting.targets." }
            if ($allowlist -notcontains $key) { Add-Failure "Health route '$key' must be in publicAllowlist." }
            $noneRoutePaths.Add((Get-BasePath $path))
        }
        'ALB_PUBLIC' {
            if (-not (Test-CoveredByPrefix $path $ingressPrefixes[[string]$r.backend])) {
                Add-Failure "Public route '$key' path is not covered by ingress prefixes of backend '$($r.backend)'."
            }
            if ($allowlist -notcontains $key) { Add-Failure "Public route '$key' must be in publicAllowlist." }
            $noneRoutePaths.Add((Get-BasePath $path))
        }
        'ALB_PROTECTED' {
            if ($null -eq $ingressPrefixes[[string]$r.backend]) {
                Add-Failure "Protected route '$key' backend '$($r.backend)' is not an ingress backend."
            } elseif (-not (Test-CoveredByPrefix $path $ingressPrefixes[[string]$r.backend])) {
                Add-Failure "Protected route '$key' path is not covered by ingress prefixes of backend '$($r.backend)'."
            }
            if ($r.authorizationType -ne 'CUSTOM') { Add-Failure "Protected route '$key' must use CUSTOM authorization." }
            if ($roles.Count -lt 1) { Add-Failure "Protected route '$key' must document requiredRoles." }
            $customRoutePaths.Add((Get-BasePath $path))
        }
        default { Add-Failure "Route '$key' has an unknown destination '$($r.destination)'." }
    }

    # ALB destinations must never point to the Lambda; auth must never use the ALB.
    if ($albDestinations -contains $r.destination -and $r.backend -eq 'auth') {
        Add-Failure "Route '$key' targets the ALB but is bound to the auth backend."
    }

    $matrix.Add([pscustomobject]@{
        RouteKey    = $key
        Destination = $r.destination
        Backend     = [string]$r.backend
        Auth        = $r.authorizationType
        Roles       = ($roles -join '|')
    })
}

# Duplicate route keys.
$seen = @{}
foreach ($k in $routeKeys) {
    if ($seen.ContainsKey($k)) { Add-Failure "Duplicate route key '$k'." } else { $seen[$k] = $true }
}

# A public (NONE) route must never be an ancestor of a protected (CUSTOM) route.
foreach ($pub in $noneRoutePaths) {
    foreach ($prot in $customRoutePaths) {
        if ($prot -eq $pub -or $prot.StartsWith("$pub/")) {
            Add-Failure "Public route path '$pub' is an ancestor of protected route path '$prot' (protected route could be shadowed)."
        }
    }
}

# Every allowlist entry must correspond to a declared NONE route.
$noneKeys = @($entrypoint.routes | Where-Object { $_.authorizationType -eq 'NONE' } | ForEach-Object { [string]$_.routeKey })
foreach ($a in $allowlist) {
    if ($noneKeys -notcontains $a) { Add-Failure "publicAllowlist entry '$a' does not match any NONE route." }
}

# --- Matrix ----------------------------------------------------------------
Write-Host ''
Write-Host 'Route matrix (sanitized):'
$matrix | Format-Table RouteKey, Destination, Backend, Auth, Roles -AutoSize | Out-String | Write-Host

# --- Result ----------------------------------------------------------------
if ($script:Failures.Count -gt 0) {
    Write-Host 'Route contract is INVALID:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host " - $f" }
    throw "Route contract validation failed with $($script:Failures.Count) issue(s)."
}

$protectedCount = @($matrix | Where-Object { $_.Auth -eq 'CUSTOM' }).Count
$publicCount = @($matrix | Where-Object { $_.Auth -eq 'NONE' }).Count
Write-Host "Route contract is valid. $($matrix.Count) route(s): $protectedCount protected, $publicCount public."

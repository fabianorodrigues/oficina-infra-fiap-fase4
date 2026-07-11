# Validates config/entrypoint.json without AWS access. Exits non-zero on any issue.
# Targets PowerShell 7 (CI runs it with pwsh) and also runs under Windows PowerShell 5.1.
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $root = Split-Path -Parent $PSScriptRoot
    $ConfigPath = Join-Path $root 'config/entrypoint.json'
}

$script:Failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:Failures.Add($Message) }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Entrypoint config validation failed: missing $ConfigPath."
}

$raw = Get-Content -LiteralPath $ConfigPath -Raw
try {
    $config = $raw | ConvertFrom-Json
} catch {
    throw "Entrypoint config validation failed: invalid JSON. $($_.Exception.Message)"
}

# --- API identity ----------------------------------------------------------
$api = $config.api
if ($null -eq $api) { Add-Failure 'Missing api section.' }
else {
    if ($api.name -ne 'oficina-api') { Add-Failure "api.name must be 'oficina-api' (found '$($api.name)')." }
    if ($api.protocolType -ne 'HTTP') { Add-Failure "api.protocolType must be 'HTTP' (found '$($api.protocolType)')." }
    if ($api.stageName -ne '$default') { Add-Failure "api.stageName must be '`$default' (found '$($api.stageName)')." }
    if ($api.disableExecuteApiEndpoint -ne $false) { Add-Failure 'api.disableExecuteApiEndpoint must be false (execute-api endpoint is the public entrypoint).' }
}

# --- VPC Link --------------------------------------------------------------
$vpcLink = $config.vpcLink
if ($null -eq $vpcLink) { Add-Failure 'Missing vpcLink section.' }
elseif ($vpcLink.name -ne 'oficina') { Add-Failure "vpcLink.name must be 'oficina' (found '$($vpcLink.name)')." }

# --- Integration payload formats -------------------------------------------
$integration = $config.integration
if ($null -eq $integration) { Add-Failure 'Missing integration section.' }
else {
    if ($integration.albPayloadFormatVersion -ne '1.0') { Add-Failure "integration.albPayloadFormatVersion must be '1.0' (found '$($integration.albPayloadFormatVersion)')." }
    if ($integration.lambdaPayloadFormatVersion -ne '2.0') { Add-Failure "integration.lambdaPayloadFormatVersion must be '2.0' (found '$($integration.lambdaPayloadFormatVersion)')." }
    if ($integration.overwritePath -ne '$request.path') { Add-Failure "integration.overwritePath must be '`$request.path' (found '$($integration.overwritePath)')." }
    $timeout = $integration.timeoutMilliseconds -as [int]
    if ($null -eq $timeout -or $timeout -lt 1 -or $timeout -gt 30000) { Add-Failure "integration.timeoutMilliseconds must be between 1 and 30000 (found '$($integration.timeoutMilliseconds)')." }
}

# --- Authorizer ------------------------------------------------------------
$auth = $config.auth
if ($null -eq $auth) { Add-Failure 'Missing auth section.' }
else {
    if ($auth.payloadFormatVersion -ne '2.0') { Add-Failure "auth.payloadFormatVersion must be '2.0' (found '$($auth.payloadFormatVersion)')." }
    if ($auth.enableSimpleResponses -ne $true) { Add-Failure 'auth.enableSimpleResponses must be true.' }
    if (($auth.resultTtlSeconds -as [int]) -ne 0) { Add-Failure "auth.resultTtlSeconds must be 0 (cache disabled) (found '$($auth.resultTtlSeconds)')." }
    if ($auth.alias -ne 'live') { Add-Failure "auth.alias must be 'live' (found '$($auth.alias)')." }
    $identitySources = @($auth.identitySources)
    if ($identitySources.Count -ne 1 -or $identitySources[0] -ne '$request.header.Authorization') {
        Add-Failure "auth.identitySources must be exactly ['`$request.header.Authorization']."
    }
}

# --- SSM parameter paths ---------------------------------------------------
$ssmPaths = [System.Collections.Generic.List[string]]::new()
foreach ($section in @($config.vpcLink, $config.auth)) {
    if ($null -eq $section) { continue }
    foreach ($prop in $section.PSObject.Properties) {
        if ($prop.Name -match 'Parameter$') { $ssmPaths.Add([string]$prop.Value) }
    }
}
if ($config.ssmOutputs) {
    foreach ($prop in $config.ssmOutputs.PSObject.Properties) { $ssmPaths.Add([string]$prop.Value) }
}
if ($config.logging -and $config.logging.logGroupName) {
    if (-not ([string]$config.logging.logGroupName).StartsWith('/aws/apigateway/')) {
        Add-Failure "logging.logGroupName must start with '/aws/apigateway/' (found '$($config.logging.logGroupName)')."
    }
}
foreach ($p in $ssmPaths) {
    if (-not $p.StartsWith('/oficina/')) { Add-Failure "SSM parameter '$p' must start with '/oficina/'." }
}

# --- Throttling ------------------------------------------------------------
$throttling = $config.throttling
if ($null -eq $throttling) { Add-Failure 'Missing throttling section.' }
else {
    if (($throttling.rateLimit -as [int]) -lt 1) { Add-Failure 'throttling.rateLimit must be a positive integer.' }
    if (($throttling.burstLimit -as [int]) -lt 1) { Add-Failure 'throttling.burstLimit must be a positive integer.' }
}

# --- CORS ------------------------------------------------------------------
$cors = $config.cors
if ($null -ne $cors -and $cors.enabled -eq $true) {
    if (@($cors.allowOrigins).Count -eq 0) { Add-Failure 'cors.enabled=true requires explicit allowOrigins.' }
    if (@($cors.allowOrigins) -contains '*' -and $cors.allowCredentials -eq $true) {
        Add-Failure 'cors must not combine wildcard origin with allowCredentials.'
    }
}

# --- Routes ----------------------------------------------------------------
$routes = @($config.routes)
if ($routes.Count -lt 1) { Add-Failure 'At least one route is required.' }

$allowlist = @($config.publicAllowlist)
$routeKeys = [System.Collections.Generic.List[string]]::new()
$authCount = 0
$healthCount = 0
$catchAll = @('$default', 'ANY /', 'ANY /{proxy+}', 'ANY /api/{proxy+}')

foreach ($r in $routes) {
    $key = [string]$r.routeKey
    $routeKeys.Add($key)

    if ($catchAll -contains $key) { Add-Failure "Catch-all/`$default route '$key' is not allowed." }
    if ($key -match '(?i)(^|\s|/)(ready)(/|$)') { Add-Failure "Readiness route '$key' must not be exposed." }
    if ($key -match '(?i)/api/internal(/|$)') { Add-Failure "Internal route '$key' must not be exposed." }
    if ($key -match '(?i)/api/dev(/|$)') { Add-Failure "Development route '$key' must not be exposed." }

    switch ($r.destination) {
        'AUTH_LAMBDA' {
            $authCount++
            if ($r.authorizationType -ne 'NONE') { Add-Failure "Auth route '$key' must use authorizationType NONE." }
        }
        'ALB_HEALTH' {
            $healthCount++
            if ($r.authorizationType -ne 'NONE') { Add-Failure "Health route '$key' must use authorizationType NONE." }
            if ([string]::IsNullOrWhiteSpace($r.healthTarget)) { Add-Failure "Health route '$key' must declare a healthTarget." }
        }
        'ALB_PUBLIC' {
            if ($r.authorizationType -ne 'NONE') { Add-Failure "Public route '$key' must use authorizationType NONE." }
        }
        'ALB_PROTECTED' {
            if ($r.authorizationType -ne 'CUSTOM') { Add-Failure "Protected route '$key' must use authorizationType CUSTOM." }
            if (@($r.requiredRoles).Count -lt 1) { Add-Failure "Protected route '$key' must document requiredRoles." }
        }
        default { Add-Failure "Route '$key' has an unknown destination '$($r.destination)'." }
    }

    # Any NONE route must be explicitly allow-listed as public.
    if ($r.authorizationType -eq 'NONE' -and ($allowlist -notcontains $key)) {
        Add-Failure "Unauthenticated route '$key' is not present in publicAllowlist (functional public routes are forbidden without justification)."
    }
    # Any CUSTOM route must attach a real authorizer (destination cannot be a Lambda/public one).
    if ($r.authorizationType -eq 'CUSTOM' -and $r.destination -ne 'ALB_PROTECTED') {
        Add-Failure "CUSTOM route '$key' must target ALB_PROTECTED."
    }
}

if ($authCount -lt 1) { Add-Failure 'At least one AUTH_LAMBDA route is required.' }
if ($healthCount -ne 3) { Add-Failure "Exactly three ALB_HEALTH routes are required (found $healthCount)." }

# Duplicate route keys.
$seen = @{}
foreach ($k in $routeKeys) {
    if ($seen.ContainsKey($k)) { Add-Failure "Duplicate route key '$k'." } else { $seen[$k] = $true }
}

# --- No secrets or real AWS values -----------------------------------------
if ($raw -match 'subnet-[0-9a-fA-F]{8,}') { Add-Failure 'Config must not contain a real subnet ID.' }
if ($raw -match 'sg-[0-9a-fA-F]{8,}') { Add-Failure 'Config must not contain a real security group ID.' }
if ($raw -match 'arn:aws') { Add-Failure 'Config must not contain a real ARN.' }
if ($raw -match '(?i)amazonaws\.com') { Add-Failure 'Config must not contain a real AWS DNS name.' }
if ($raw -match '(?i)execute-api') { Add-Failure 'Config must not contain a real execute-api endpoint.' }
if ($raw -match '(?i)(password|senha)\s*[:=]') { Add-Failure 'Config must not contain a password.' }
if ($raw -match '(?i)(secretstring|jwt_signing_key|signingkey)') { Add-Failure 'Config must not contain a secret or signing key.' }
if ($raw -match 'eyJ[A-Za-z0-9_-]{10,}') { Add-Failure 'Config must not contain a JWT.' }
if ($raw -match '(?i)fase\s*-?\s*3') { Add-Failure 'Config must not reference the previous phase.' }
if ($raw -match '(?i)(-dev|-hml|-staging|-prod)(\b|["/])') { Add-Failure 'Config must not use dev/hml/staging/prod environment suffixes.' }

# --- Result ----------------------------------------------------------------
if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Entrypoint configuration is INVALID:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host " - $f" }
    throw "Entrypoint config validation failed with $($script:Failures.Count) issue(s)."
}

Write-Host "Entrypoint configuration is valid. $($routes.Count) route(s): $authCount auth, $healthCount health, $([int]($routes.Count - $authCount - $healthCount)) ALB."

# Black-box smoke test for the public API Gateway entrypoint. HTTP only, no AWS
# calls, no secrets. Uses synthetic data. Exits non-zero on any failed assertion.
# Health probes retry briefly because API Gateway/VPC Link/ALB can return
# transient 5xx responses immediately after a fresh deployment.
# Targets PowerShell 7 (pwsh, uses -SkipHttpErrorCheck).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [int]$TimeoutSeconds = 15,
    [ValidateRange(1, 30)][int]$HealthMaxAttempts = 6,
    [ValidateRange(1, 120)][int]$HealthRetryDelaySeconds = 10,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config/entrypoint.json' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$base = $BaseUrl.TrimEnd('/')

$script:Failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:Failures.Add($Message); Write-Host "  FAIL $Message" }
function Add-Pass([string]$Message) { Write-Host "  PASS $Message" }

function Invoke-Http {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Headers,
        [string]$Body
    )
    $uri = "$base$Path"
    $params = @{
        Method             = $Method
        Uri                = $uri
        TimeoutSec         = $TimeoutSeconds
        SkipHttpErrorCheck = $true
        MaximumRedirection = 0
        ErrorAction        = 'Stop'
    }
    if ($Headers) { $params.Headers = $Headers }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = $Body
        $params.ContentType = 'application/json'
    }
    $resp = Invoke-WebRequest @params
    return [int]$resp.StatusCode
}

function Assert-Status {
    param([string]$Label, [int]$Actual, [int[]]$Expected)
    if ($Expected -contains $Actual) { Add-Pass "$Label -> $Actual" }
    else { Add-Failure "$Label -> $Actual (expected $($Expected -join '/'))" }
}

function Test-TransientStatus {
    param([int]$StatusCode)
    return @(0, 408, 425, 429, 500, 502, 503, 504) -contains $StatusCode
}

function Assert-HealthStatus {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lastCode = 0
    $lastError = ''
    $attemptsUsed = 0

    for ($attempt = 1; $attempt -le $HealthMaxAttempts; $attempt++) {
        $attemptsUsed = $attempt
        try {
            $lastCode = Invoke-Http -Method 'GET' -Path $Path
            $lastError = ''
        }
        catch {
            $lastCode = 0
            $lastError = $_.Exception.Message
        }

        if ($lastCode -eq 200) {
            if ($attempt -eq 1) { Add-Pass "GET $Path -> 200" }
            else { Add-Pass "GET $Path -> 200 (attempt $attempt/$HealthMaxAttempts)" }
            return
        }

        if (-not (Test-TransientStatus $lastCode) -or $attempt -eq $HealthMaxAttempts) { break }

        $detail = if ($lastCode -eq 0) { "exception: $lastError" } else { "status $lastCode" }
        Write-Host "  RETRY GET $Path -> $detail (attempt $attempt/$HealthMaxAttempts); waiting ${HealthRetryDelaySeconds}s"
        Start-Sleep -Seconds $HealthRetryDelaySeconds
    }

    if ($lastCode -eq 0) {
        Add-Failure "GET $Path -> exception '$lastError' (expected 200 after $attemptsUsed attempt(s))"
    }
    else {
        Add-Failure "GET $Path -> $lastCode (expected 200 after $attemptsUsed attempt(s))"
    }
}

Write-Host "Smoke testing $base"

# Health (public, expected 2xx)
foreach ($t in @('cadastro', 'estoque', 'ordens')) {
    Assert-HealthStatus -Path "/health/$t"
}

# Protected routes reject unauthenticated and malformed tokens
$protectedProbes = @(
    @{ Backend = 'cadastro'; Path = '/api/clientes' },
    @{ Backend = 'estoque'; Path = '/api/estoque' },
    @{ Backend = 'ordens'; Path = '/api/ordens-servico' }
)
foreach ($probe in $protectedProbes) {
    $noToken = Invoke-Http -Method 'GET' -Path $probe.Path
    Assert-Status "GET $($probe.Path) (no token)" $noToken @(401, 403)

    $badToken = Invoke-Http -Method 'GET' -Path $probe.Path -Headers @{ Authorization = 'Bearer not-a-real-jwt' }
    Assert-Status "GET $($probe.Path) (malformed token)" $badToken @(401, 403)
}

# Forbidden routes must not exist (404, NOT merely 401)
$forbidden = @('/ready', '/api/internal/clientes/documento/00000000000', '/api/dev/ordens-servico/00000000-0000-0000-0000-000000000000/reprocessar-reserva')
foreach ($f in $forbidden) {
    $code = Invoke-Http -Method 'GET' -Path $f
    if ($code -eq 404) { Add-Pass "GET $f -> 404 (not routed)" }
    else { Add-Failure "GET $f -> $code (expected 404; a published-but-protected internal route is still an exposure)" }
}

# Auth route returns a controlled error for a synthetic invalid payload
$authRoute = @($config.routes | Where-Object { $_.destination -eq 'AUTH_LAMBDA' })[0]
if ($null -ne $authRoute) {
    $parsed = ([string]$authRoute.routeKey) -split '\s+', 2
    $authMethod = $parsed[0]
    $authPath = $parsed[1]
    # Synthetic, non-real credentials. Password is never logged.
    $syntheticBody = '{"cpf":"00000000000","password":"invalid-smoke-test"}'
    $code = Invoke-Http -Method $authMethod -Path $authPath -Body $syntheticBody
    Assert-Status "$authMethod $authPath (synthetic invalid login)" $code @(400, 401)
}

# CORS (only when enabled)
if ($config.cors -and $config.cors.enabled -eq $true) {
    $origin = @($config.cors.allowOrigins)[0]
    $resp = Invoke-WebRequest -Method 'OPTIONS' -Uri "$base/health/cadastro" -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck -Headers @{
        'Origin'                         = $origin
        'Access-Control-Request-Method'  = 'GET'
    } -ErrorAction Stop
    if ($resp.Headers.ContainsKey('Access-Control-Allow-Origin')) { Add-Pass 'CORS preflight returns Access-Control-Allow-Origin' }
    else { Add-Failure 'CORS enabled but preflight did not return Access-Control-Allow-Origin' }
} else {
    Write-Host '  SKIP CORS disabled in config; preflight test skipped.'
}

# Result
if ($script:Failures.Count -gt 0) {
    throw "Smoke test failed with $($script:Failures.Count) issue(s)."
}
Write-Host ''
Write-Host 'Smoke test passed.'

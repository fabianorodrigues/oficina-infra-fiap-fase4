# Renders deploy/k8s/ingress/ingress.template.yaml into a temporary manifest.
# No AWS, no Kubernetes, no secrets. Deterministic output.
# Targets PowerShell 7 (CI runs it with pwsh) and also runs under Windows PowerShell 5.1.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TemplatePath,
    [string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$PrivateSubnet1,
    [Parameter(Mandatory = $true)][string]$PrivateSubnet2
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config/ingress-routes.json' }
if ([string]::IsNullOrWhiteSpace($TemplatePath)) { $TemplatePath = Join-Path $root 'deploy/k8s/ingress/ingress.template.yaml' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'oficina-ingress' }

# 1. Validate the versioned configuration first (no AWS, no Kubernetes).
#    The validator throws on any problem; ErrorActionPreference=Stop aborts render.
& (Join-Path $PSScriptRoot 'validate-ingress-config.ps1') -ConfigPath $ConfigPath

if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Missing template: $TemplatePath." }

# 2. Validate subnet IDs syntactically. Real subnets are not required locally;
#    synthetic values such as subnet-00000000000000001 are accepted.
$subnetPattern = '^subnet-[0-9a-f]{8}([0-9a-f]{9})?$'
foreach ($s in @($PrivateSubnet1, $PrivateSubnet2)) {
    if ($s -notmatch $subnetPattern) {
        throw "Invalid subnet ID '$s'. Expected 'subnet-' followed by 8 or 17 hex characters."
    }
}
if ($PrivateSubnet1 -eq $PrivateSubnet2) {
    throw "The two private subnets must be different (got '$PrivateSubnet1' twice)."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# 3. Build the ordered path rules (most specific first for deterministic output).
$rules = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($backend in $config.backends) {
    foreach ($p in @($backend.paths)) {
        $rules.Add([pscustomobject]@{
            Path     = $p
            Service  = $backend.serviceName
            Port     = [int]$backend.servicePort
            Segments = ($p.Trim('/') -split '/').Count
        })
    }
}
$ordered = $rules | Sort-Object -Property @{Expression = 'Segments'; Descending = $true}, @{Expression = { $_.Path.Length }; Descending = $true}, @{Expression = 'Path'; Descending = $false}

$sb = [System.Text.StringBuilder]::new()
foreach ($r in $ordered) {
    [void]$sb.AppendLine("          - path: $($r.Path)")
    [void]$sb.AppendLine('            pathType: Prefix')
    [void]$sb.AppendLine('            backend:')
    [void]$sb.AppendLine('              service:')
    [void]$sb.AppendLine("                name: $($r.Service)")
    [void]$sb.AppendLine('                port:')
    [void]$sb.AppendLine("                  number: $($r.Port)")
}
$functionalPathsBlock = $sb.ToString().TrimEnd("`r", "`n")

# 3b. Build the header-based health routing (three annotation actions + rules).
#     The API Gateway rewrites external /health/<service> to /health and sets the
#     trusted header x-oficina-health-target. Each action forwards to its Service
#     only when that header matches, so it never affects the /api/* rules.
$backendById = @{}
foreach ($backend in $config.backends) {
    $backendById[[string]$backend.id] = $backend
}

$health = $config.healthRouting
if ($null -eq $health) { throw 'Missing healthRouting section in configuration.' }
$healthHeader = [string]$health.header
$healthPath = [string]$health.path
$healthPathType = [string]$health.pathType
$healthTargets = @($health.targets)
if ($healthTargets.Count -ne 3) { throw "healthRouting.targets must contain exactly three entries (found $($healthTargets.Count))." }

$annBuilder = [System.Text.StringBuilder]::new()
$healthBuilder = [System.Text.StringBuilder]::new()
foreach ($target in $healthTargets) {
    $backend = $backendById[[string]$target]
    if ($null -eq $backend) { throw "healthRouting target '$target' has no matching backend." }
    $service = [string]$backend.serviceName
    $port = [int]$backend.servicePort
    $action = "health-$target"

    $forward = ('{{"type":"forward","forwardConfig":{{"targetGroups":[{{"serviceName":"{0}","servicePort":"{1}","weight":100}}]}}}}' -f $service, $port)
    $condition = ('[{{"field":"http-header","httpHeaderConfig":{{"httpHeaderName":"{0}","values":["{1}"]}}}}]' -f $healthHeader, $target)

    [void]$annBuilder.AppendLine("    alb.ingress.kubernetes.io/actions.$($action): '$forward'")
    [void]$annBuilder.AppendLine("    alb.ingress.kubernetes.io/conditions.$($action): '$condition'")

    [void]$healthBuilder.AppendLine("          - path: $healthPath")
    [void]$healthBuilder.AppendLine("            pathType: $healthPathType")
    [void]$healthBuilder.AppendLine('            backend:')
    [void]$healthBuilder.AppendLine('              service:')
    [void]$healthBuilder.AppendLine("                name: $action")
    [void]$healthBuilder.AppendLine('                port:')
    [void]$healthBuilder.AppendLine('                  name: use-annotation')
}
$healthAnnotations = $annBuilder.ToString().TrimEnd("`r", "`n")
$healthPathsBlock = $healthBuilder.ToString().TrimEnd("`r", "`n")

# Health rules first (they do not overlap /api/*), then the functional rules.
$pathsBlock = "$healthPathsBlock`n$functionalPathsBlock"

# 4. Assemble annotation values from config.
$tga = "deregistration_delay.timeout_seconds=$([int]$config.targetGroupAttributes.deregistrationDelaySeconds)"
$dropInvalid = [bool]$config.loadBalancerAttributes.dropInvalidHeaderFields
$lba = "routing.http.drop_invalid_header_fields.enabled=$($dropInvalid.ToString().ToLowerInvariant())"

$tokens = [ordered]@{
    '__LOAD_BALANCER_NAME__'     = $config.ingress.loadBalancerName
    '__SCHEME__'                 = $config.ingress.scheme
    '__TARGET_TYPE__'            = $config.ingress.targetType
    '__INGRESS_CLASS_NAME__'     = $config.ingress.ingressClassName
    '__LISTEN_PORTS__'           = ('[{{"HTTP":{0}}}]' -f [int]$config.ingress.listenerPort)
    '__HEALTHCHECK_PATH__'       = $config.healthCheck.path
    '__SUCCESS_CODES__'          = $config.healthCheck.successCodes
    '__HEALTHCHECK_INTERVAL__'   = [int]$config.healthCheck.intervalSeconds
    '__HEALTHCHECK_TIMEOUT__'    = [int]$config.healthCheck.timeoutSeconds
    '__HEALTHY_THRESHOLD__'      = [int]$config.healthCheck.healthyThreshold
    '__UNHEALTHY_THRESHOLD__'    = [int]$config.healthCheck.unhealthyThreshold
    '__TARGET_GROUP_ATTRIBUTES__' = $tga
    '__LOAD_BALANCER_ATTRIBUTES__' = $lba
    '__PRIVATE_SUBNETS__'        = "$PrivateSubnet1,$PrivateSubnet2"
    '__HEALTH_ANNOTATIONS__'     = $healthAnnotations
    '__INGRESS_PATHS__'          = $pathsBlock
}

# 5. Render (the template file is read-only; only the output is written).
$manifest = Get-Content -LiteralPath $TemplatePath -Raw
foreach ($token in $tokens.Keys) {
    $manifest = $manifest.Replace($token, [string]$tokens[$token])
}
$manifest = $manifest -replace "`r`n", "`n"

# 6. Guardrail: no placeholder may survive.
$leftover = [regex]::Matches($manifest, '__[A-Z0-9_]+__')
if ($leftover.Count -gt 0) {
    throw "Rendered manifest still contains placeholders: $($leftover.Value -join ', ')."
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
$outputPath = Join-Path $OutputDirectory 'ingress.rendered.yaml'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($outputPath, $manifest, $utf8NoBom)

Write-Host "Rendered ingress manifest: $outputPath"
Write-Host "Subnets: $PrivateSubnet1, $PrivateSubnet2"
Write-Host "Routes rendered: $($ordered.Count) functional + $($healthTargets.Count) health (header $healthHeader)"
$outputPath

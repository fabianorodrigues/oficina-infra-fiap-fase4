# Non-destructive smoke test for the shared internal ALB and backends.
# Runs in the deploy workflow after the ALB is active. Only safe GETs are used;
# no POST/PUT/PATCH/DELETE against the applications, no personal data, no sensitive
# bodies are printed. Targets PowerShell 7 (pwsh in CI).
#
# Modes:
#   port-forward : from the runner, port-forward each ClusterIP Service and probe
#                  /health internally (the internal ALB DNS is not reachable from a
#                  GitHub-hosted runner).
#   pod          : create a short-lived Pod inside the VPC to probe both the internal
#                  Service /health and the internal ALB routes, then delete the Pod.
[CmdletBinding()]
param(
    [string]$AlbDnsName,
    [string]$ConfigPath,
    [string]$Namespace = 'oficina',
    [ValidateSet('port-forward', 'pod')][string]$Mode = 'port-forward',
    [string]$Image = 'curlimages/curl:8.11.1',
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config/ingress-routes.json' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$healthPath = $config.healthCheck.path
# ALB responses that prove the request reached a healthy target and the app answered.
# Authenticated routes reply 401/403 without a token; that still proves ALB routing.
$routedCodes = @('200', '204', '301', '302', '400', '401', '403', '405')
$gatewayCodes = @('502', '503', '504')

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$m) { $failures.Add($m); Write-Host " FAIL: $m" -ForegroundColor Red }
function Add-Ok([string]$m) { Write-Host " OK:   $m" -ForegroundColor Green }

function Test-InternalHealthPortForward {
    foreach ($backend in $config.backends) {
        $svc = $backend.serviceName
        $port = [int]$backend.servicePort
        $local = Get-Random -Minimum 30000 -Maximum 39000
        $pf = Start-Process -FilePath 'kubectl' -ArgumentList @('port-forward', "svc/$svc", "${local}:${port}", '-n', $Namespace) -PassThru -NoNewWindow
        try {
            $code = $null
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $deadline) {
                try {
                    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$local$healthPath" -Method Get -TimeoutSec 5 -UseBasicParsing
                    $code = [int]$resp.StatusCode
                    break
                } catch {
                    Start-Sleep -Milliseconds 1000
                }
            }
            if ($code -eq 200) { Add-Ok "$svc $healthPath returned 200 (internal)." }
            else { Add-Failure "$svc $healthPath did not return 200 within ${TimeoutSeconds}s (got '$code')." }
        } finally {
            if ($pf -and -not $pf.HasExited) { Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Host 'Note: the internal ALB DNS is not reachable from a GitHub-hosted runner; use -Mode pod to exercise ALB routing.'
}

function Invoke-PodCurl {
    param([string]$PodName, [string]$Url)
    $code = & kubectl exec $PodName -n $Namespace -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 $Url
    return ("$code").Trim()
}

function Test-ViaTemporaryPod {
    if ([string]::IsNullOrWhiteSpace($AlbDnsName)) { throw 'AlbDnsName is required in pod mode.' }
    $suffix = -join ((48..57) + (97..102) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
    $podName = "oficina-ingress-smoke-$suffix"
    $overrides = @{
        apiVersion = 'v1'
        spec       = @{
            automountServiceAccountToken = $false
            restartPolicy                = 'Never'
            securityContext              = @{ runAsNonRoot = $true; seccompProfile = @{ type = 'RuntimeDefault' } }
            containers                   = @(@{
                    name            = 'smoke'
                    image           = $Image
                    command         = @('sleep', "$([int]$TimeoutSeconds + 120)")
                    securityContext = @{
                        allowPrivilegeEscalation = $false
                        readOnlyRootFilesystem   = $true
                        runAsNonRoot             = $true
                        capabilities             = @{ drop = @('ALL') }
                    }
                })
        }
    } | ConvertTo-Json -Depth 12 -Compress

    Write-Host "Creating temporary smoke Pod '$podName' (image $Image)."
    & kubectl run $podName -n $Namespace --image $Image --restart Never --overrides $overrides --command -- sleep "$([int]$TimeoutSeconds + 120)" | Out-Null
    try {
        & kubectl wait --for=condition=Ready "pod/$podName" -n $Namespace --timeout "${TimeoutSeconds}s" | Out-Null

        foreach ($backend in $config.backends) {
            $svc = $backend.serviceName
            $port = [int]$backend.servicePort
            $url = "http://$svc.$Namespace.svc.cluster.local:$port$healthPath"
            $code = Invoke-PodCurl -PodName $podName -Url $url
            if ($code -eq '200') { Add-Ok "$svc $healthPath returned 200 (internal, in-cluster)." }
            else { Add-Failure "$svc $healthPath returned '$code' (expected 200)." }
        }

        foreach ($backend in $config.backends) {
            $route = @($backend.paths)[0]
            $url = "http://$AlbDnsName$route"
            $code = Invoke-PodCurl -PodName $podName -Url $url
            if ($gatewayCodes -contains $code) { Add-Failure "ALB route '$route' returned gateway error $code (no healthy target?)." }
            elseif ($routedCodes -contains $code) { Add-Ok "ALB route '$route' reached $($backend.serviceName) (HTTP $code)." }
            else { Add-Failure "ALB route '$route' returned unexpected HTTP '$code'." }
        }
    } finally {
        Write-Host "Deleting temporary smoke Pod '$podName'."
        & kubectl delete pod $podName -n $Namespace --now --ignore-not-found | Out-Null
    }
}

switch ($Mode) {
    'port-forward' { Test-InternalHealthPortForward }
    'pod' { Test-ViaTemporaryPod }
}

if ($failures.Count -gt 0) {
    throw "Smoke test failed with $($failures.Count) issue(s)."
}
Write-Host "Smoke test completed successfully (mode: $Mode)."

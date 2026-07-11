# Read-only validation of the deployed shared internal ALB and Ingress.
# Runs in the deploy workflow AFTER apply, with AWS credentials and kubeconfig.
# It never mutates AWS or Kubernetes. Targets PowerShell 7 (pwsh in CI).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Region,
    [string]$Namespace = 'oficina',
    [string]$IngressName = 'oficina',
    [string]$LoadBalancerName = 'oficina',
    [string]$ConfigPath,
    [string]$AwsProfile
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config/ingress-routes.json' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Only read-only verbs are permitted. Any mutating verb is refused defensively so
# this script can never change infrastructure even if edited carelessly.
$blockedVerbs = 'create|put|update|delete|apply|install|upgrade|uninstall|destroy|attach|detach|register|deregister|modify|set-|add-'

function Invoke-ReadOnly {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $line = "$Command $($Arguments -join ' ')"
    if ($line -match "\b($blockedVerbs)") {
        throw "Refusing non-read-only command: $line"
    }
    $output = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $line" }
    return $output
}

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $full = @($Arguments) + @('--region', $Region, '--output', 'json')
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) { $full += @('--profile', $AwsProfile) }
    return (Invoke-ReadOnly aws $full | ConvertFrom-Json)
}

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$m) { $failures.Add($m); Write-Host " FAIL: $m" -ForegroundColor Red }
function Add-Ok([string]$m) { Write-Host " OK:   $m" -ForegroundColor Green }

# --- 1. STS identity (read-only) ------------------------------------------
Invoke-ReadOnly aws @('sts', 'get-caller-identity', '--output', 'json') | Out-Null

# --- 2. Ingress exists with the correct IngressClass ----------------------
$ingressJson = Invoke-ReadOnly kubectl @('get', 'ingress', $IngressName, '-n', $Namespace, '-o', 'json') | ConvertFrom-Json
if ($ingressJson.spec.ingressClassName -ne $config.ingress.ingressClassName) {
    Add-Failure "Ingress class is '$($ingressJson.spec.ingressClassName)', expected '$($config.ingress.ingressClassName)'."
} else { Add-Ok "Ingress '$IngressName' uses IngressClass '$($config.ingress.ingressClassName)'." }

$ingressAddress = $null
if ($ingressJson.status.loadBalancer.ingress) { $ingressAddress = $ingressJson.status.loadBalancer.ingress[0].hostname }
if ([string]::IsNullOrWhiteSpace($ingressAddress)) { Add-Failure 'Ingress has no load balancer address in status.' }
else { Add-Ok "Ingress status address: $ingressAddress" }

# --- 3. ALB exists, internal, active, two private subnets -----------------
$lbData = Invoke-Aws @('elbv2', 'describe-load-balancers', '--names', $LoadBalancerName)
$lb = $lbData.LoadBalancers | Select-Object -First 1
if ($null -eq $lb) { throw "Load balancer '$LoadBalancerName' not found." }
$lbArn = $lb.LoadBalancerArn

if ($lb.Scheme -ne 'internal') { Add-Failure "ALB scheme is '$($lb.Scheme)', expected 'internal'." } else { Add-Ok 'ALB scheme is internal.' }
if ($lb.State.Code -ne 'active') { Add-Failure "ALB state is '$($lb.State.Code)', expected 'active'." } else { Add-Ok 'ALB state is active.' }

$albSubnets = @($lb.AvailabilityZones | ForEach-Object { $_.SubnetId })
if ($albSubnets.Count -ne 2) { Add-Failure "ALB is attached to $($albSubnets.Count) subnet(s), expected exactly 2." } else { Add-Ok "ALB is attached to 2 subnets: $($albSubnets -join ', ')." }

# Expected private subnets come from SSM, never hardcoded.
$expectedSubnets = @()
foreach ($p in @($config.aws.privateSubnet1Parameter, $config.aws.privateSubnet2Parameter)) {
    $val = (Invoke-Aws @('ssm', 'get-parameter', '--name', $p)).Parameter.Value
    $expectedSubnets += $val
}
foreach ($s in $albSubnets) {
    if ($expectedSubnets -notcontains $s) { Add-Failure "ALB subnet '$s' is not one of the expected private subnets." }
}
if (($albSubnets | Where-Object { $expectedSubnets -contains $_ }).Count -eq 2) { Add-Ok 'ALB uses the two expected private subnets from SSM.' }

# --- 4. Listener HTTP 80 --------------------------------------------------
$listeners = (Invoke-Aws @('elbv2', 'describe-listeners', '--load-balancer-arn', $lbArn)).Listeners
$httpListener = $listeners | Where-Object { $_.Protocol -eq 'HTTP' -and [int]$_.Port -eq [int]$config.ingress.listenerPort } | Select-Object -First 1
if ($null -eq $httpListener) { Add-Failure "No HTTP:$($config.ingress.listenerPort) listener found." } else { Add-Ok "HTTP:$($config.ingress.listenerPort) listener present." }

# --- 5. Target groups: type ip, health path /health, targets healthy ------
$targetGroups = (Invoke-Aws @('elbv2', 'describe-target-groups', '--load-balancer-arn', $lbArn)).TargetGroups
if ($targetGroups.Count -lt 3) { Add-Failure "Found $($targetGroups.Count) target group(s), expected at least 3 (one per service)." } else { Add-Ok "$($targetGroups.Count) target group(s) present." }

foreach ($tg in $targetGroups) {
    if ($tg.TargetType -ne 'ip') { Add-Failure "Target group '$($tg.TargetGroupName)' type is '$($tg.TargetType)', expected 'ip'." }
    if ($tg.HealthCheckPath -ne $config.healthCheck.path) { Add-Failure "Target group '$($tg.TargetGroupName)' health path is '$($tg.HealthCheckPath)', expected '$($config.healthCheck.path)'." }
    $health = (Invoke-Aws @('elbv2', 'describe-target-health', '--target-group-arn', $tg.TargetGroupArn)).TargetHealthDescriptions
    $unhealthy = @($health | Where-Object { $_.TargetHealth.State -ne 'healthy' })
    if ($health.Count -eq 0) { Add-Failure "Target group '$($tg.TargetGroupName)' has no registered targets." }
    elseif ($unhealthy.Count -gt 0) { Add-Failure "Target group '$($tg.TargetGroupName)' has $($unhealthy.Count) non-healthy target(s)." }
    else { Add-Ok "Target group '$($tg.TargetGroupName)': $($health.Count) healthy target(s), health path $($tg.HealthCheckPath)." }
}

# --- 6. Listener rules cover exactly the versioned public routes ----------
if ($httpListener) {
    $rules = (Invoke-Aws @('elbv2', 'describe-rules', '--listener-arn', $httpListener.ListenerArn)).Rules
    $rulePatterns = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rules) {
        foreach ($c in @($r.Conditions | Where-Object { $_.Field -eq 'path-pattern' })) {
            foreach ($v in @($c.PathPatternConfig.Values)) { $rulePatterns.Add($v) }
        }
    }
    $expectedPaths = @()
    foreach ($b in $config.backends) { $expectedPaths += @($b.paths) }
    foreach ($p in $expectedPaths) {
        $covered = $rulePatterns | Where-Object { $_ -eq $p -or $_ -eq "$p/*" }
        if (-not $covered) { Add-Failure "No listener rule matches configured route '$p'." }
    }
    if (($expectedPaths | Where-Object { $rp = $_; ($rulePatterns | Where-Object { $_ -eq $rp -or $_ -eq "$rp/*" }) }).Count -eq $expectedPaths.Count) {
        Add-Ok "All $($expectedPaths.Count) configured routes are present as listener rules."
    }
    # Guard against a catch-all rule sneaking in.
    if ($rulePatterns | Where-Object { $_ -eq '/*' -or $_ -eq '/' }) { Add-Failure 'A catch-all listener rule ( / or /* ) is present.' }
}

# --- 7. SSM outputs published ---------------------------------------------
foreach ($p in @($config.ssmOutputs.loadBalancerArn, $config.ssmOutputs.listenerArn, $config.ssmOutputs.dnsName)) {
    $val = (Invoke-Aws @('ssm', 'get-parameter', '--name', $p)).Parameter.Value
    if ([string]::IsNullOrWhiteSpace($val)) { Add-Failure "SSM parameter '$p' is empty." } else { Add-Ok "SSM parameter '$p' is present." }
}

# --- Result ---------------------------------------------------------------
if ($failures.Count -gt 0) {
    throw "Ingress post-deploy validation failed with $($failures.Count) issue(s)."
}
Write-Host 'Read-only ingress validation completed successfully.'

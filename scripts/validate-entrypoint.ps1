# Read-only validation of the deployed Entrypoint stack. Performs describe/get
# calls only. It never creates, updates, deletes or puts any resource. Intended
# to run after Entrypoint Deploy, with AWS credentials configured. Exits
# non-zero on any discrepancy against config/entrypoint.json.
# Targets PowerShell 7 (pwsh).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Region,
    [string]$ApiName = 'oficina-api',
    [string]$VpcLinkName = 'oficina',
    [string]$AlbName = 'oficina',
    [string]$AwsProfile,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config/entrypoint.json' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$script:Failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:Failures.Add($Message) }
function Add-Ok([string]$Message) { Write-Host "  OK  $Message" }

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$AwsArgs)
    $common = @('--region', $Region, '--output', 'json')
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) { $common += @('--profile', $AwsProfile) }
    $out = & aws @AwsArgs @common 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws $($AwsArgs -join ' ') failed: $out" }
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    return ($out | ConvertFrom-Json)
}

function Get-Ssm([string]$Name) {
    return (Invoke-Aws @('ssm', 'get-parameter', '--name', $Name, '--query', 'Parameter.Value')).ToString()
}

Write-Host "Read-only Entrypoint validation in region $Region"

# 0. Identity.
$identity = Invoke-Aws @('sts', 'get-caller-identity')
Add-Ok "Caller account $($identity.Account)"

# 1. API exists, HTTP protocol, execute-api endpoint enabled.
$apis = Invoke-Aws @('apigatewayv2', 'get-apis')
$api = @($apis.Items | Where-Object { $_.Name -eq $ApiName })[0]
if ($null -eq $api) { throw "API '$ApiName' not found." }
$apiId = $api.ApiId
$partition = ([string]$identity.Arn -split ':')[1]
$apiExecutionArn = "arn:${partition}:execute-api:${Region}:$($identity.Account):${apiId}"
if ($api.ProtocolType -ne 'HTTP') { Add-Failure "API protocol is '$($api.ProtocolType)', expected HTTP." } else { Add-Ok 'API protocol HTTP' }
if ($api.DisableExecuteApiEndpoint -eq $true) { Add-Failure 'execute-api endpoint is disabled.' } else { Add-Ok 'execute-api endpoint enabled' }

# 2. Stage $default with access logs and throttling.
$stages = Invoke-Aws @('apigatewayv2', 'get-stages', '--api-id', $apiId)
$stage = @($stages.Items | Where-Object { $_.StageName -eq '$default' })[0]
if ($null -eq $stage) { Add-Failure 'Stage $default not found.' }
else {
    Add-Ok 'Stage $default present'
    if ([string]::IsNullOrWhiteSpace($stage.AccessLogSettings.DestinationArn)) { Add-Failure 'Stage access logs are not configured.' } else { Add-Ok 'Access logs configured' }
    if ($null -eq $stage.DefaultRouteSettings -or $null -eq $stage.DefaultRouteSettings.ThrottlingRateLimit) { Add-Failure 'Stage throttling is not configured.' } else { Add-Ok "Throttling rate $($stage.DefaultRouteSettings.ThrottlingRateLimit)" }
}

# 3. VPC Link AVAILABLE with private subnets and dedicated SG.
$vpcLinks = Invoke-Aws @('apigatewayv2', 'get-vpc-links')
$vpcLink = @($vpcLinks.Items | Where-Object { $_.Name -eq $VpcLinkName })[0]
if ($null -eq $vpcLink) { Add-Failure "VPC Link '$VpcLinkName' not found." }
else {
    if ($vpcLink.VpcLinkStatus -ne 'AVAILABLE') { Add-Failure "VPC Link status is '$($vpcLink.VpcLinkStatus)', expected AVAILABLE." } else { Add-Ok 'VPC Link AVAILABLE' }
    $expectedSubnets = @((Get-Ssm $config.vpcLink.privateSubnet1Parameter), (Get-Ssm $config.vpcLink.privateSubnet2Parameter))
    foreach ($s in $expectedSubnets) {
        if (@($vpcLink.SubnetIds) -notcontains $s) { Add-Failure "VPC Link is missing expected private subnet $s." }
    }
    Add-Ok "VPC Link subnets $($vpcLink.SubnetIds -join ',')"
}

# 4. Internal ALB, listener HTTP 80, listener ARN used by integrations. The ALB
#    is discovered by name and tags, not by an SSM handoff.
$lb = Invoke-Aws @('elbv2', 'describe-load-balancers', '--names', $AlbName)
$albArn = $lb.LoadBalancers[0].LoadBalancerArn
if ($lb.LoadBalancers[0].Scheme -ne 'internal') { Add-Failure "ALB scheme is '$($lb.LoadBalancers[0].Scheme)', expected internal." } else { Add-Ok 'ALB internal' }
$listeners = Invoke-Aws @('elbv2', 'describe-listeners', '--load-balancer-arn', $albArn)
$listener80 = @($listeners.Listeners | Where-Object { $_.Port -eq 80 -and $_.Protocol -eq 'HTTP' })[0]
if ($null -eq $listener80) { Add-Failure 'ALB HTTP 80 listener not found.' } else { Add-Ok 'ALB HTTP 80 listener present' }
$listenerArn = $listener80.ListenerArn

# 5. Integrations point to the listener ARN (private) or the Auth alias (lambda).
$integrations = Invoke-Aws @('apigatewayv2', 'get-integrations', '--api-id', $apiId)
$albIntegrations = @($integrations.Items | Where-Object { $_.ConnectionType -eq 'VPC_LINK' })
foreach ($i in $albIntegrations) {
    if ($i.IntegrationUri -ne $listenerArn) { Add-Failure "Private integration $($i.IntegrationId) URI is not the listener ARN." }
    if ($i.PayloadFormatVersion -ne '1.0') { Add-Failure "Private integration $($i.IntegrationId) payload is '$($i.PayloadFormatVersion)', expected 1.0." }
}
if ($albIntegrations.Count -ge 1) { Add-Ok "$($albIntegrations.Count) private integrations use the listener ARN, payload 1.0" }
$lambdaIntegrations = @($integrations.Items | Where-Object { $_.IntegrationType -eq 'AWS_PROXY' })
foreach ($i in $lambdaIntegrations) {
    if ($i.PayloadFormatVersion -ne '2.0') { Add-Failure "Auth integration payload is '$($i.PayloadFormatVersion)', expected 2.0." }
    if ($i.IntegrationUri -notmatch '^arn:[^:]+:apigateway:[^:]+:lambda:path/2015-03-31/functions/arn:[^:]+:lambda:[^:]+:[0-9]+:function:[^/]+:live/invocations$') {
        Add-Failure 'Auth integration does not use the live alias invoke URI.'
    }
}
if ($lambdaIntegrations.Count -ge 1) { Add-Ok 'Auth Lambda integration uses payload 2.0 and the live alias invoke URI' }

# 6. Authorizer: REQUEST, payload 2.0, simple responses, TTL 0, live alias.
$authorizers = Invoke-Aws @('apigatewayv2', 'get-authorizers', '--api-id', $apiId)
$authorizer = @($authorizers.Items)[0]
if ($null -eq $authorizer) { Add-Failure 'No authorizer found.' }
else {
    if ($authorizer.AuthorizerType -ne 'REQUEST') { Add-Failure "Authorizer type is '$($authorizer.AuthorizerType)', expected REQUEST." }
    if ($authorizer.AuthorizerPayloadFormatVersion -ne '2.0') { Add-Failure 'Authorizer payload is not 2.0.' }
    if ($authorizer.EnableSimpleResponses -ne $true) { Add-Failure 'Authorizer simple responses are not enabled.' }
    if (($authorizer.AuthorizerResultTtlInSeconds -as [int]) -ne 0) { Add-Failure 'Authorizer cache TTL is not 0.' }
    if ($authorizer.AuthorizerUri -notmatch ':live/invocations$') { Add-Failure 'Authorizer does not use the live alias ARN.' }
    if ($script:Failures.Count -eq 0) { Add-Ok 'Authorizer REQUEST/2.0/simple/TTL0/live' }
}

# 7. Routes: match the contract, no catch-all, protected use the authorizer.
$routes = Invoke-Aws @('apigatewayv2', 'get-routes', '--api-id', $apiId)
$deployedKeys = @($routes.Items | ForEach-Object { $_.RouteKey })
$expectedKeys = @($config.routes | ForEach-Object { [string]$_.routeKey })
foreach ($k in $expectedKeys) {
    if ($deployedKeys -notcontains $k) { Add-Failure "Contract route '$k' is not deployed." }
}
foreach ($rt in $routes.Items) {
    if (@('$default', 'ANY /{proxy+}', 'ANY /api/{proxy+}', 'ANY /') -contains $rt.RouteKey) { Add-Failure "Catch-all route '$($rt.RouteKey)' is deployed." }
    $expected = @($config.routes | Where-Object { [string]$_.routeKey -eq $rt.RouteKey })[0]
    if ($null -ne $expected -and $expected.authorizationType -eq 'CUSTOM') {
        if ($rt.AuthorizationType -ne 'CUSTOM' -or [string]::IsNullOrWhiteSpace($rt.AuthorizerId)) {
            Add-Failure "Protected route '$($rt.RouteKey)' is missing the authorizer."
        }
    }
}
Add-Ok "$($deployedKeys.Count) routes deployed"

# 8. Lambda permissions and live aliases exist.
foreach ($fnParam in @($config.auth.authCpfFunctionNameParameter, $config.auth.authorizerFunctionNameParameter)) {
    $fn = Get-Ssm $fnParam
    $alias = Invoke-Aws @('lambda', 'get-alias', '--function-name', $fn, '--name', $config.auth.alias)
    if ($null -eq $alias) { Add-Failure "Lambda $fn has no '$($config.auth.alias)' alias." } else { Add-Ok "Lambda $fn alias $($config.auth.alias) present" }
    $policy = Invoke-Aws @('lambda', 'get-policy', '--function-name', $fn, '--qualifier', $config.auth.alias)
    if ($null -eq $policy -or $policy.Policy -notmatch 'apigateway') {
        Add-Failure "Lambda $fn ($($config.auth.alias)) has no API Gateway invoke permission."
    } elseif (-not ([string]$policy.Policy).Contains("${apiExecutionArn}/*")) {
        Add-Failure "Lambda $fn ($($config.auth.alias)) is missing the API-scoped invoke permission ${apiExecutionArn}/*."
    } else {
        Add-Ok "Lambda $fn invoke permission present"
    }
}

# 9. Access log group exists.
$logGroup = Invoke-Aws @('logs', 'describe-log-groups', '--log-group-name-prefix', $config.logging.logGroupName)
if (@($logGroup.logGroups | Where-Object { $_.logGroupName -eq $config.logging.logGroupName }).Count -lt 1) { Add-Failure "Access log group '$($config.logging.logGroupName)' not found." } else { Add-Ok 'Access log group present' }

# 10. SSM outputs published.
foreach ($prop in $config.ssmOutputs.PSObject.Properties) {
    $val = Get-Ssm $prop.Value
    if ([string]::IsNullOrWhiteSpace($val)) { Add-Failure "SSM output '$($prop.Value)' is empty." } else { Add-Ok "SSM $($prop.Value) published" }
}

# --- Result ----------------------------------------------------------------
if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Entrypoint deployment is INVALID:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host " - $f" }
    throw "Read-only Entrypoint validation failed with $($script:Failures.Count) issue(s)."
}

Write-Host ''
Write-Host "Entrypoint deployment validated for API '$ApiName' ($apiId)."

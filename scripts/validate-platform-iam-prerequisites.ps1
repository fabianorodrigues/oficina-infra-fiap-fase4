[CmdletBinding()]
param(
    [string]$PlanJsonPath = 'tfplan.json',
    [string]$CallerArn = ''
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    throw "Platform IAM prerequisite validation failed: $Message"
}

function Add-RequiredAction {
    param(
        [System.Collections.Generic.HashSet[string]]$Actions,
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    if ($null -eq $Actions) {
        Fail 'Required actions collection was not initialized.'
    }

    [void]$Actions.Add($Action)
}

if (-not (Test-Path -LiteralPath $PlanJsonPath)) {
    Fail "Missing Terraform plan JSON at '$PlanJsonPath'. Run terraform show -json tfplan first."
}

$plan = Get-Content -LiteralPath $PlanJsonPath -Raw | ConvertFrom-Json
$resourceChanges = @($plan.resource_changes)
$creates = @($resourceChanges | Where-Object { @($_.change.actions) -contains 'create' })

$iamCreateTypes = @(
    'aws_iam_role',
    'aws_iam_policy',
    'aws_iam_role_policy_attachment',
    'aws_iam_openid_connect_provider'
)

$iamCreates = @($creates | Where-Object { $iamCreateTypes -contains $_.type })
if ($iamCreates.Count -eq 0) {
    Write-Host 'No IAM create actions found in platform plan.'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($CallerArn)) {
    $identityRaw = & aws sts get-caller-identity --output json
    if ($LASTEXITCODE -ne 0) {
        Fail 'Unable to resolve AWS caller identity.'
    }

    $identity = ([string]::Join("`n", $identityRaw)) | ConvertFrom-Json
    $CallerArn = [string]$identity.Arn
}

$requiredActions = [System.Collections.Generic.HashSet[string]]::new()
foreach ($change in $iamCreates) {
    switch ($change.type) {
        'aws_iam_role' { Add-RequiredAction $requiredActions 'iam:CreateRole' }
        'aws_iam_policy' { Add-RequiredAction $requiredActions 'iam:CreatePolicy' }
        'aws_iam_role_policy_attachment' { Add-RequiredAction $requiredActions 'iam:AttachRolePolicy' }
        'aws_iam_openid_connect_provider' { Add-RequiredAction $requiredActions 'iam:CreateOpenIDConnectProvider' }
    }
}

$eksPassRoleCreates = @($creates | Where-Object { @('aws_eks_cluster', 'aws_eks_node_group', 'aws_eks_pod_identity_association') -contains $_.type })
if ($eksPassRoleCreates.Count -gt 0) {
    Add-RequiredAction $requiredActions 'iam:PassRole'
}

$requiredActionsText = (@($requiredActions) | Sort-Object) -join ', '
$iamResourcesText = (@($iamCreates | ForEach-Object { "$($_.address) ($($_.type))" }) | Sort-Object) -join '; '

if ($CallerArn -match ':assumed-role/voclabs/') {
    Fail "AWS caller '$CallerArn' is the AWS Academy VocLabs role. This plan creates IAM resources: $iamResourcesText. The platform stack requires these IAM actions before apply: $requiredActionsText. Use GitHub Actions secrets for an IAM-capable deploy principal, or pre-create/import the IAM roles and policies before applying this stack."
}

Write-Host "Platform plan creates IAM resources: $iamResourcesText"
Write-Host "Ensure AWS caller '$CallerArn' allows these IAM actions before apply: $requiredActionsText"

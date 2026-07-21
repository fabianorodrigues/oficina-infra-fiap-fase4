[CmdletBinding()]
param(
    [string]$PlanJsonPath = 'tfplan.json',
    [string]$ExternalIamRolesJsonPath = 'platform.auto.tfvars.json',
    [string]$CallerArn = '',
    [string]$CallerAccountId = ''
)

$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    if (-not $script:failures.Contains($Message)) {
        [void]$script:failures.Add($Message)
    }
}

function Add-WarningMessage([string]$Message) {
    if (-not $script:warnings.Contains($Message)) {
        [void]$script:warnings.Add($Message)
    }
}

function ConvertTo-SafeLogText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $safeText = [regex]::Replace($Text, 'arn:[^\s''"]+', '<AWS_ARN>')
    $safeText = [regex]::Replace($safeText, '\b[0-9]{12}\b', '<ACCOUNT_ID>')
    $safeText = [regex]::Replace($safeText, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '<EMAIL>')
    $safeText = [regex]::Replace($safeText, '(--role-name\s+)\S+', '$1<ROLE_NAME>')
    $safeText = [regex]::Replace($safeText, '(--policy-arn\s+)\S+', '$1<AWS_ARN>')
    $safeText = [regex]::Replace($safeText, '(--resource-arns\s+)\S+', '$1<AWS_ARN>')
    return $safeText
}

function Complete-Validation {
    foreach ($warning in $script:warnings) {
        Write-Warning $warning
    }

    if ($script:failures.Count -gt 0) {
        foreach ($failure in $script:failures) {
            Write-Host "ERROR: $failure" -ForegroundColor Red
        }

        throw "Platform IAM prerequisite validation failed with $($script:failures.Count) error(s)."
    }
}

function Get-ArrayValue($Value) {
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $global:LASTEXITCODE = 0
        $ErrorActionPreference = 'Continue'
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Text     = ([string]::Join("`n", @($output))).Trim()
    }
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$Optional
    )

    $result = Invoke-NativeCommand -Command 'aws' -Arguments $Arguments
    $text = $result.Text

    if ($result.ExitCode -ne 0) {
        if ($Optional) {
            $safeCommand = ConvertTo-SafeLogText "aws $($Arguments -join ' ')"
            $safeText = ConvertTo-SafeLogText $text
            Add-WarningMessage "Unable to run read-only AWS CLI command '$safeCommand': $safeText"
            return $null
        }

        throw (ConvertTo-SafeLogText $text)
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json
}

function Add-RequiredAction {
    param(
        [System.Collections.Generic.HashSet[string]]$Actions,
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    [void]$Actions.Add($Action)
}

function Get-CallerPolicySourceArn([string]$Arn) {
    if ($Arn -match '^arn:(?<Partition>[^:]+):sts::(?<AccountId>[0-9]{12}):assumed-role/(?<RoleName>[^/]+)/.+$') {
        return "arn:$($Matches.Partition):iam::$($Matches.AccountId):role/$($Matches.RoleName)"
    }

    return $Arn
}

function Get-PartitionFromArn([string]$Arn) {
    if ($Arn -match '^arn:(?<Partition>[^:]+):') {
        return $Matches.Partition
    }

    return 'aws'
}

function Get-ExternalIamRoles {
    param([string]$Path)

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $result
    }

    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        Add-Failure "External IAM role config '$Path' must contain valid JSON."
        return $result
    }

    if ($json -isnot [System.Collections.IDictionary] -and $null -eq $json.PSObject.Properties) {
        Add-Failure "External IAM role config '$Path' must be a JSON object."
        return $result
    }

    $roles = $json
    $platformRoles = Get-PropertyValue $json 'platform_iam_roles'
    if ($null -ne $platformRoles) {
        $roles = $platformRoles
    }

    if ($roles -isnot [System.Collections.IDictionary] -and $null -eq $roles.PSObject.Properties) {
        Add-Failure "External IAM role config '$Path' must contain a platform_iam_roles object."
        return $result
    }

    $allowedKeys = @(
        'eks_cluster_role_arn',
        'eks_node_group_role_arn',
        'load_balancer_controller_role_arn',
        'workload_role_arn'
    )

    $roleKeys = if ($roles -is [System.Collections.IDictionary]) {
        @($roles.Keys)
    } else {
        @($roles.PSObject.Properties.Name)
    }

    foreach ($key in $roleKeys) {
        if ($allowedKeys -notcontains $key) {
            Add-Failure "Unsupported external IAM role key '$key'. Use PLATFORM_IAM_ROLES_JSON with supported role fields only."
            continue
        }

        $value = [string](Get-PropertyValue $roles $key)
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $result[$key] = $value.Trim()
    }

    return $result
}

function Get-RoleArnParts {
    param(
        [string]$Arn,
        [string]$Field,
        [string]$Component
    )

    if ($Arn -notmatch '^arn:(?<Partition>[^:]+):iam::(?<AccountId>[0-9]{12}):role/(?<RolePathAndName>.+)$') {
        Add-Failure "Component '$Component' uses field '$Field', but the value is not an IAM role ARN."
        return $null
    }

    $rolePathAndName = $Matches.RolePathAndName
    $roleName = @($rolePathAndName -split '/')[-1]

    return [pscustomobject]@{
        Partition       = $Matches.Partition
        AccountId       = $Matches.AccountId
        RolePathAndName = $rolePathAndName
        RoleName        = $roleName
    }
}

function Get-IamRole {
    param(
        [string]$RoleName,
        [string]$Field,
        [string]$Component
    )

    $result = Invoke-NativeCommand -Command 'aws' -Arguments @('iam', 'get-role', '--role-name', $RoleName, '--output', 'json')
    $text = $result.Text

    if ($result.ExitCode -ne 0) {
        if ($text -match 'NoSuchEntity') {
            Add-Failure "Component '$Component' uses field '$Field', but the configured role does not exist."
        } else {
            Add-WarningMessage "Could not confirm existence/trust for component '$Component' field '$Field': $(ConvertTo-SafeLogText $text)"
        }

        return $null
    }

    return ($text | ConvertFrom-Json).Role
}

function Test-ActionMatch {
    param(
        [object[]]$Patterns,
        [string]$ExpectedAction
    )

    foreach ($pattern in $Patterns) {
        $text = ([string]$pattern).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $wildcard = [System.Management.Automation.WildcardPattern]::new($text, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($wildcard.IsMatch($ExpectedAction)) {
            return $true
        }
    }

    return $false
}

function Test-TrustPolicy {
    param(
        [object]$Role,
        [string]$ExpectedService,
        [bool]$RequireTagSession,
        [string]$Field,
        [string]$Component
    )

    if ($null -eq $Role) {
        return
    }

    $assumeAllowed = $false
    $tagAllowed = -not $RequireTagSession

    foreach ($statement in @(Get-ArrayValue $Role.AssumeRolePolicyDocument.Statement)) {
        if ([string](Get-PropertyValue $statement 'Effect') -ne 'Allow') {
            continue
        }

        $principal = Get-PropertyValue $statement 'Principal'
        $servicePrincipal = Get-PropertyValue $principal 'Service'
        $services = @(Get-ArrayValue $servicePrincipal | ForEach-Object { [string]$_ })
        if ($services -notcontains $ExpectedService -and $services -notcontains '*') {
            continue
        }

        $actions = @(Get-ArrayValue (Get-PropertyValue $statement 'Action'))
        if (Test-ActionMatch $actions 'sts:AssumeRole') {
            $assumeAllowed = $true
        }

        if ($RequireTagSession -and (Test-ActionMatch $actions 'sts:TagSession')) {
            $tagAllowed = $true
        }
    }

    if (-not $assumeAllowed) {
        Add-Failure "Component '$Component' uses field '$Field', but the role trust policy must allow sts:AssumeRole for $ExpectedService."
    }

    if (-not $tagAllowed) {
        Add-Failure "Component '$Component' uses field '$Field', but the role trust policy must allow sts:TagSession for $ExpectedService."
    }
}

function Assert-AttachedPolicyNames {
    param(
        [string]$RoleName,
        [string[]]$ExpectedPolicyNames,
        [string]$Field,
        [string]$Component
    )

    if ($ExpectedPolicyNames.Count -eq 0) {
        return
    }

    $attached = Invoke-AwsJson -Arguments @('iam', 'list-attached-role-policies', '--role-name', $RoleName, '--output', 'json') -Optional
    if ($null -eq $attached) {
        return
    }

    $policyNames = @($attached.AttachedPolicies | ForEach-Object { $_.PolicyName })
    $missing = @($ExpectedPolicyNames | Where-Object { $policyNames -notcontains $_ })
    if ($missing.Count -gt 0) {
        Add-Failure "Component '$Component' uses field '$Field', but the role is missing attached policies: $($missing -join ', ')."
    }
}

function Add-PolicyDocumentActions {
    param(
        [object]$Document,
        [System.Collections.Generic.HashSet[string]]$Actions
    )

    foreach ($statement in @(Get-ArrayValue $Document.Statement)) {
        if ([string](Get-PropertyValue $statement 'Effect') -ne 'Allow') {
            continue
        }

        foreach ($action in @(Get-ArrayValue (Get-PropertyValue $statement 'Action'))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$action)) {
                [void]$Actions.Add([string]$action)
            }
        }
    }
}

function Get-RequiredActionName {
    param([object]$RequiredAction)

    if ($RequiredAction -is [string]) {
        return $RequiredAction
    }

    $action = [string](Get-PropertyValue $RequiredAction 'Action')
    if ([string]::IsNullOrWhiteSpace($action)) {
        return [string]$RequiredAction
    }

    return $action
}

function Add-MissingPermissionResult {
    param(
        [object]$RequiredAction,
        [string]$RoleName,
        [string]$Component,
        [string]$Field,
        [bool]$AsWarning
    )

    $action = Get-RequiredActionName -RequiredAction $RequiredAction
    $consumer = [string](Get-PropertyValue $RequiredAction 'Consumer')
    $impact = [string](Get-PropertyValue $RequiredAction 'Impact')

    if ([string]::IsNullOrWhiteSpace($consumer)) {
        $consumer = $Component
    }

    if ([string]::IsNullOrWhiteSpace($impact)) {
        $impact = "The component may fail when it calls $action."
    }

    $message = @(
        "Permissao ausente: $action"
        "Componente consumidor: $consumer"
        "Role que precisa possuir a permissao: configured by $Field"
        "Impacto esperado: $impact"
        "Campo de configuracao: $Field"
    ) -join ' | '

    if ($AsWarning) {
        Add-WarningMessage $message
    } else {
        Add-Failure $message
    }
}

function Test-RolePolicyActions {
    param(
        [string]$RoleName,
        [object[]]$RequiredActions,
        [string]$Field,
        [string]$Component
    )

    if ($RequiredActions.Count -eq 0) {
        return
    }

    $actions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unreadablePolicies = 0

    $attached = Invoke-AwsJson -Arguments @('iam', 'list-attached-role-policies', '--role-name', $RoleName, '--output', 'json') -Optional
    if ($null -ne $attached) {
        foreach ($policy in @($attached.AttachedPolicies)) {
            $policyDetails = Invoke-AwsJson -Arguments @('iam', 'get-policy', '--policy-arn', $policy.PolicyArn, '--output', 'json') -Optional
            if ($null -eq $policyDetails) {
                $unreadablePolicies++
                continue
            }

            $version = Invoke-AwsJson -Arguments @('iam', 'get-policy-version', '--policy-arn', $policy.PolicyArn, '--version-id', $policyDetails.Policy.DefaultVersionId, '--output', 'json') -Optional
            if ($null -eq $version) {
                $unreadablePolicies++
                continue
            }

            Add-PolicyDocumentActions -Document $version.PolicyVersion.Document -Actions $actions
        }
    }

    $inline = Invoke-AwsJson -Arguments @('iam', 'list-role-policies', '--role-name', $RoleName, '--output', 'json') -Optional
    if ($null -ne $inline) {
        foreach ($policyName in @($inline.PolicyNames)) {
            $policy = Invoke-AwsJson -Arguments @('iam', 'get-role-policy', '--role-name', $RoleName, '--policy-name', $policyName, '--output', 'json') -Optional
            if ($null -eq $policy) {
                $unreadablePolicies++
                continue
            }

            Add-PolicyDocumentActions -Document $policy.PolicyDocument -Actions $actions
        }
    }

    $missing = @()
    foreach ($requiredAction in $RequiredActions) {
        $required = Get-RequiredActionName -RequiredAction $requiredAction
        if (-not (Test-ActionMatch @($actions) $required)) {
            $missing += $requiredAction
        }
    }

    if ($missing.Count -gt 0 -and $unreadablePolicies -eq 0) {
        foreach ($missingAction in $missing) {
            $severity = [string](Get-PropertyValue $missingAction 'Severity')
            Add-MissingPermissionResult -RequiredAction $missingAction -RoleName $RoleName -Component $Component -Field $Field -AsWarning:($severity -eq 'Warning')
        }
    } elseif ($missing.Count -gt 0) {
        $missingText = (@($missing | ForEach-Object { Get-RequiredActionName -RequiredAction $_ }) | Sort-Object -Unique) -join ', '
        Add-WarningMessage "Could not fully confirm policy actions for component '$Component' field '$Field' because one or more policies were not readable. Missing actions from readable policies: $missingText."
    }
}

function Test-RoleEffectiveActions {
    param(
        [string]$RoleArn,
        [string]$RoleName,
        [object[]]$RequiredActions,
        [string]$Field,
        [string]$Component
    )

    if ($RequiredActions.Count -eq 0) {
        return
    }

    $requiredByAction = @{}
    foreach ($requiredAction in $RequiredActions) {
        $action = Get-RequiredActionName -RequiredAction $requiredAction
        if (-not [string]::IsNullOrWhiteSpace($action)) {
            $requiredByAction[$action.ToLowerInvariant()] = $requiredAction
        }
    }

    $actionNames = @($requiredByAction.Keys | Sort-Object)
    for ($i = 0; $i -lt $actionNames.Count; $i += 90) {
        $end = [Math]::Min($i + 89, $actionNames.Count - 1)
        $chunk = @($actionNames[$i..$end])

        $result = Invoke-AwsJson -Arguments @(
            @('iam', 'simulate-principal-policy', '--policy-source-arn', $RoleArn, '--action-names') +
            $chunk +
            @('--resource-arns', '*', '--output', 'json')
        ) -Optional

        if ($null -eq $result) {
            Add-WarningMessage "Could not confirm effective policy decisions for component '$Component' field '$Field'."
            continue
        }

        foreach ($evaluation in @($result.EvaluationResults)) {
            if ([string]$evaluation.EvalDecision -eq 'allowed') {
                continue
            }

            $action = ([string]$evaluation.EvalActionName).ToLowerInvariant()
            if (-not $requiredByAction.ContainsKey($action)) {
                continue
            }

            $requiredAction = $requiredByAction[$action]
            $severity = [string](Get-PropertyValue $requiredAction 'Severity')
            Add-MissingPermissionResult -RequiredAction $requiredAction -RoleName $RoleName -Component $Component -Field $Field -AsWarning:($severity -eq 'Warning')
        }
    }
}

function Test-CallerPassRole {
    param(
        [string]$CallerPolicySourceArn,
        [string]$RoleArn,
        [string]$PassedToService,
        [string]$Field,
        [string]$Component
    )

    if ([string]::IsNullOrWhiteSpace($CallerPolicySourceArn)) {
        Add-WarningMessage "Could not simulate iam:PassRole for component '$Component' field '$Field' because caller policy source ARN is unavailable."
        return
    }

    $result = Invoke-AwsJson -Arguments @(
        'iam', 'simulate-principal-policy',
        '--policy-source-arn', $CallerPolicySourceArn,
        '--action-names', 'iam:PassRole',
        '--resource-arns', $RoleArn,
        '--context-entries', "ContextKeyName=iam:PassedToService,ContextKeyType=string,ContextKeyValues=$PassedToService",
        '--output', 'json'
    ) -Optional

    if ($null -eq $result) {
        return
    }

    $decision = [string]$result.EvaluationResults[0].EvalDecision
    if ($decision -ne 'allowed') {
        Add-Failure "Component '$Component' uses field '$Field', but the deploy principal is not allowed to run iam:PassRole for $PassedToService."
    }
}

function Test-CallerRequiredActions {
    param(
        [string]$CallerPolicySourceArn,
        [string[]]$RequiredActions,
        [object[]]$IamCreates
    )

    if ($RequiredActions.Count -eq 0) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($CallerPolicySourceArn)) {
        Add-WarningMessage "Could not simulate IAM create/update actions because caller policy source ARN is unavailable."
        return
    }

    $result = Invoke-AwsJson -Arguments @(
        @('iam', 'simulate-principal-policy', '--policy-source-arn', $CallerPolicySourceArn, '--action-names') +
        $RequiredActions +
        @('--resource-arns', '*', '--output', 'json')
    ) -Optional

    if ($null -eq $result) {
        return
    }

    $denied = @($result.EvaluationResults | Where-Object { [string]$_.EvalDecision -ne 'allowed' } | ForEach-Object { $_.EvalActionName } | Sort-Object -Unique)
    if ($denied.Count -eq 0) {
        return
    }

    $fieldHints = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($change in $IamCreates) {
        $address = [string]$change.address
        if ($address -match 'eks_cluster') {
            [void]$fieldHints.Add('eks_cluster_role_arn')
        } elseif ($address -match 'node_group') {
            [void]$fieldHints.Add('eks_node_group_role_arn')
        } elseif ($address -match 'load_balancer_controller') {
            [void]$fieldHints.Add('load_balancer_controller_role_arn')
        } elseif ($address -match 'workload') {
            [void]$fieldHints.Add('workload_role_arn')
        }
    }

    $hintText = (@($fieldHints) | Sort-Object) -join ', '
    if ([string]::IsNullOrWhiteSpace($hintText)) {
        $hintText = 'the role field for the affected component'
    }

    Add-Failure "Terraform plan creates or changes IAM resources, but the deploy principal is missing actions: $($denied -join ', '). Configure PLATFORM_IAM_ROLES_JSON fields ($hintText) or use a deploy principal with these permissions."
}

function Get-PlannedRoleArn {
    param(
        [object]$Change,
        [string]$Partition,
        [string]$AccountId
    )

    $after = Get-PropertyValue $Change.change 'after'
    $name = [string](Get-PropertyValue $after 'name')
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    return "arn:${Partition}:iam::$($AccountId):role/$name"
}

if (-not (Test-Path -LiteralPath $PlanJsonPath)) {
    Add-Failure "Missing Terraform plan JSON at '$PlanJsonPath'. Run terraform show -json tfplan first."
    Complete-Validation
}

$plan = Get-Content -LiteralPath $PlanJsonPath -Raw | ConvertFrom-Json
$resourceChanges = @($plan.resource_changes)
$creates = @($resourceChanges | Where-Object { @($_.change.actions) -contains 'create' })
$externalRoles = Get-ExternalIamRoles -Path $ExternalIamRolesJsonPath

if ([string]::IsNullOrWhiteSpace($CallerArn) -or [string]::IsNullOrWhiteSpace($CallerAccountId)) {
    $identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity', '--output', 'json')
    if ([string]::IsNullOrWhiteSpace($CallerArn)) {
        $CallerArn = [string]$identity.Arn
    }
    if ([string]::IsNullOrWhiteSpace($CallerAccountId)) {
        $CallerAccountId = [string]$identity.Account
    }
}

$callerPolicySourceArn = Get-CallerPolicySourceArn -Arn $CallerArn
$callerPartition = Get-PartitionFromArn -Arn $CallerArn

function New-RequiredAction {
    param(
        [string]$Action,
        [string]$Consumer,
        [string]$Impact,
        [string]$Severity = 'Error'
    )

    @{
        Action   = $Action
        Consumer = $Consumer
        Impact   = $Impact
        Severity = $Severity
    }
}

$nodeBaseRequiredActions = @(
    New-RequiredAction 'eks:DescribeCluster' 'EKS nodes' 'Nodes may fail to join or operate in the cluster.'
    New-RequiredAction 'ec2:DescribeInstances' 'EKS nodes' 'Node and pod networking discovery may fail.'
    New-RequiredAction 'ec2:DescribeNetworkInterfaces' 'EKS nodes' 'VPC CNI may fail to inspect pod network interfaces.'
    New-RequiredAction 'ec2:DescribeInstanceTypes' 'EKS nodes' 'VPC CNI may fail to inspect ENI and IP capacity.'
    New-RequiredAction 'ec2:DescribeTags' 'EKS nodes' 'VPC CNI may fail to inspect required network tags.'
    New-RequiredAction 'ec2:CreateNetworkInterface' 'EKS nodes' 'VPC CNI may fail to allocate pod networking.'
    New-RequiredAction 'ec2:AttachNetworkInterface' 'EKS nodes' 'VPC CNI may fail to attach pod networking.'
    New-RequiredAction 'ec2:DeleteNetworkInterface' 'EKS nodes' 'VPC CNI may fail to release pod networking.'
    New-RequiredAction 'ec2:DetachNetworkInterface' 'EKS nodes' 'VPC CNI may fail to detach pod networking.'
    New-RequiredAction 'ec2:ModifyNetworkInterfaceAttribute' 'EKS nodes' 'VPC CNI may fail to configure pod network interfaces.'
    New-RequiredAction 'ec2:AssignPrivateIpAddresses' 'EKS nodes' 'VPC CNI may fail to assign pod IP addresses.'
    New-RequiredAction 'ec2:UnassignPrivateIpAddresses' 'EKS nodes' 'VPC CNI may fail to release pod IP addresses.'
    New-RequiredAction 'ec2:CreateTags' 'EKS nodes' 'VPC CNI may fail to tag pod network interfaces.'
    New-RequiredAction 'ecr:GetAuthorizationToken' 'EKS nodes' 'Nodes may fail to authenticate to ECR.'
    New-RequiredAction 'ecr:BatchCheckLayerAvailability' 'EKS nodes' 'Image pulls from ECR may fail.'
    New-RequiredAction 'ecr:GetDownloadUrlForLayer' 'EKS nodes' 'Image pulls from ECR may fail.'
    New-RequiredAction 'ecr:BatchGetImage' 'EKS nodes' 'Image pulls from ECR may fail.'
)

$loadBalancerControllerRequiredActions = @(
    New-RequiredAction 'ec2:DescribeAccountAttributes' 'AWS Load Balancer Controller' 'The controller may fail account and networking discovery.'
    New-RequiredAction 'ec2:DescribeAddresses' 'AWS Load Balancer Controller' 'The controller may fail address discovery.'
    New-RequiredAction 'ec2:DescribeAvailabilityZones' 'AWS Load Balancer Controller' 'The controller may fail subnet and zone discovery.'
    New-RequiredAction 'ec2:DescribeInternetGateways' 'AWS Load Balancer Controller' 'The controller may fail VPC discovery.'
    New-RequiredAction 'ec2:DescribeVpcs' 'AWS Load Balancer Controller' 'The controller may fail VPC discovery.'
    New-RequiredAction 'ec2:DescribeVpcPeeringConnections' 'AWS Load Balancer Controller' 'The controller may fail VPC peering discovery.'
    New-RequiredAction 'ec2:DescribeSubnets' 'AWS Load Balancer Controller' 'The controller may fail subnet discovery for ALB placement.'
    New-RequiredAction 'ec2:DescribeSecurityGroups' 'AWS Load Balancer Controller' 'The controller may fail security group discovery.'
    New-RequiredAction 'ec2:DescribeInstances' 'AWS Load Balancer Controller' 'The controller may fail instance target discovery.'
    New-RequiredAction 'ec2:DescribeNetworkInterfaces' 'AWS Load Balancer Controller' 'The controller may fail network interface discovery.'
    New-RequiredAction 'ec2:DescribeTags' 'AWS Load Balancer Controller' 'The controller may fail tag-based resource discovery.'
    New-RequiredAction 'ec2:GetCoipPoolUsage' 'AWS Load Balancer Controller' 'The controller may fail customer-owned IP pool discovery.'
    New-RequiredAction 'ec2:DescribeCoipPools' 'AWS Load Balancer Controller' 'The controller may fail customer-owned IP pool discovery.'
    New-RequiredAction 'ec2:GetSecurityGroupsForVpc' 'AWS Load Balancer Controller' 'The controller may fail VPC security group discovery.'
    New-RequiredAction 'ec2:DescribeIpamPools' 'AWS Load Balancer Controller' 'The controller may fail IPAM pool discovery.'
    New-RequiredAction 'ec2:DescribeRouteTables' 'AWS Load Balancer Controller' 'The controller may fail route table discovery.'
    New-RequiredAction 'ec2:CreateSecurityGroup' 'AWS Load Balancer Controller' 'The controller may fail to create ALB security groups.'
    New-RequiredAction 'ec2:AuthorizeSecurityGroupIngress' 'AWS Load Balancer Controller' 'The controller may fail to open required security group ingress.'
    New-RequiredAction 'ec2:RevokeSecurityGroupIngress' 'AWS Load Balancer Controller' 'The controller may fail to reconcile security group ingress.'
    New-RequiredAction 'ec2:DeleteSecurityGroup' 'AWS Load Balancer Controller' 'The controller may fail to clean up ALB security groups.'
    New-RequiredAction 'ec2:CreateTags' 'AWS Load Balancer Controller' 'The controller may fail to tag ALB security groups.'
    New-RequiredAction 'ec2:DeleteTags' 'AWS Load Balancer Controller' 'The controller may fail to reconcile ALB security group tags.'
    New-RequiredAction 'elasticloadbalancing:DescribeLoadBalancers' 'AWS Load Balancer Controller' 'The controller may fail ALB discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeLoadBalancerAttributes' 'AWS Load Balancer Controller' 'The controller may fail ALB attribute discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeListeners' 'AWS Load Balancer Controller' 'The controller may fail listener discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeListenerCertificates' 'AWS Load Balancer Controller' 'The controller may fail listener certificate discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeSSLPolicies' 'AWS Load Balancer Controller' 'The controller may fail listener policy discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeRules' 'AWS Load Balancer Controller' 'The controller may fail listener rule discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeTargetGroups' 'AWS Load Balancer Controller' 'The controller may fail target group discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeTargetGroupAttributes' 'AWS Load Balancer Controller' 'The controller may fail target group attribute discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeTargetHealth' 'AWS Load Balancer Controller' 'The controller may fail target health discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeTags' 'AWS Load Balancer Controller' 'The controller may fail tag-based ALB discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeTrustStores' 'AWS Load Balancer Controller' 'The controller may fail trust store discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeListenerAttributes' 'AWS Load Balancer Controller' 'The controller may fail listener attribute discovery.'
    New-RequiredAction 'elasticloadbalancing:DescribeCapacityReservation' 'AWS Load Balancer Controller' 'The controller may fail ALB capacity reservation discovery.'
    New-RequiredAction 'elasticloadbalancing:CreateLoadBalancer' 'AWS Load Balancer Controller' 'Ingress may fail to provision an ALB.'
    New-RequiredAction 'elasticloadbalancing:CreateTargetGroup' 'AWS Load Balancer Controller' 'Ingress may fail to create target groups.'
    New-RequiredAction 'elasticloadbalancing:CreateListener' 'AWS Load Balancer Controller' 'Ingress may fail to create ALB listeners.'
    New-RequiredAction 'elasticloadbalancing:DeleteListener' 'AWS Load Balancer Controller' 'Listener cleanup may fail.'
    New-RequiredAction 'elasticloadbalancing:CreateRule' 'AWS Load Balancer Controller' 'Ingress may fail to create route listener rules.'
    New-RequiredAction 'elasticloadbalancing:DeleteRule' 'AWS Load Balancer Controller' 'Listener rule cleanup may fail.'
    New-RequiredAction 'elasticloadbalancing:AddTags' 'AWS Load Balancer Controller' 'The controller may fail to tag ALB resources.'
    New-RequiredAction 'elasticloadbalancing:RemoveTags' 'AWS Load Balancer Controller' 'The controller may fail to reconcile ALB tags.'
    New-RequiredAction 'elasticloadbalancing:ModifyLoadBalancerAttributes' 'AWS Load Balancer Controller' 'The controller may fail to apply ALB attributes.'
    New-RequiredAction 'elasticloadbalancing:SetIpAddressType' 'AWS Load Balancer Controller' 'The controller may fail to reconcile ALB address type.'
    New-RequiredAction 'elasticloadbalancing:SetSecurityGroups' 'AWS Load Balancer Controller' 'The controller may fail to attach security groups to the ALB.'
    New-RequiredAction 'elasticloadbalancing:SetSubnets' 'AWS Load Balancer Controller' 'The controller may fail to attach subnets to the ALB.'
    New-RequiredAction 'elasticloadbalancing:DeleteLoadBalancer' 'AWS Load Balancer Controller' 'ALB cleanup may fail.'
    New-RequiredAction 'elasticloadbalancing:ModifyTargetGroup' 'AWS Load Balancer Controller' 'Target group reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:ModifyTargetGroupAttributes' 'AWS Load Balancer Controller' 'Target group attribute reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:DeleteTargetGroup' 'AWS Load Balancer Controller' 'Target group cleanup may fail.'
    New-RequiredAction 'elasticloadbalancing:ModifyListenerAttributes' 'AWS Load Balancer Controller' 'Listener attribute reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:ModifyCapacityReservation' 'AWS Load Balancer Controller' 'ALB capacity reservation reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:ModifyIpPools' 'AWS Load Balancer Controller' 'ALB IP pool reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:RegisterTargets' 'AWS Load Balancer Controller' 'Pods may not be registered in target groups.'
    New-RequiredAction 'elasticloadbalancing:DeregisterTargets' 'AWS Load Balancer Controller' 'Pods may not be removed from target groups.'
    New-RequiredAction 'elasticloadbalancing:ModifyListener' 'AWS Load Balancer Controller' 'Listener reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:ModifyRule' 'AWS Load Balancer Controller' 'Listener rule reconciliation may fail.'
    New-RequiredAction 'elasticloadbalancing:SetRulePriorities' 'AWS Load Balancer Controller' 'Listener rule priority reconciliation may fail.'
)

$workloadRequiredActions = @(
    New-RequiredAction 'secretsmanager:DescribeSecret' 'Application workloads and database bootstrap' 'Pods may fail to inspect required Secrets Manager secrets.'
    New-RequiredAction 'secretsmanager:GetSecretValue' 'Application workloads and database bootstrap' 'Pods may fail to read database and runtime secrets.'
    New-RequiredAction 'sqs:ReceiveMessage' 'Estoque and Ordens workloads' 'Workers may fail to consume queue messages.'
    New-RequiredAction 'sqs:DeleteMessage' 'Estoque and Ordens workloads' 'Workers may reprocess messages because deletes fail.'
    New-RequiredAction 'sqs:ChangeMessageVisibility' 'Estoque and Ordens workloads' 'Workers may fail to extend message processing visibility.'
    New-RequiredAction 'sqs:GetQueueAttributes' 'Estoque and Ordens workloads' 'Workers may fail queue validation or SDK setup.'
    New-RequiredAction 'sqs:GetQueueUrl' 'Estoque and Ordens workloads' 'Workers may fail queue URL discovery.'
    New-RequiredAction 'sqs:SendMessage' 'Estoque and Ordens workloads' 'Services may fail to publish commands or events.'
    New-RequiredAction 'ssm:GetParameter' 'Application workloads and bootstrap' 'Pods may fail to read platform parameters.'
    New-RequiredAction 'ssm:GetParameters' 'Application workloads and bootstrap' 'Pods may fail to read grouped platform parameters.'
    New-RequiredAction 'kms:Decrypt' 'Application workloads and bootstrap' 'Pods may fail to read customer-managed encrypted secrets or parameters.' 'Warning'
)

$nodeRoleRequiredActions = @($nodeBaseRequiredActions + $loadBalancerControllerRequiredActions + $workloadRequiredActions)

$nodeRoleRequiredActions = @($nodeRoleRequiredActions | Where-Object {
    $consumer = [string](Get-PropertyValue $_ 'Consumer')
    $include = $true

    if ($externalRoles.ContainsKey('load_balancer_controller_role_arn') -and $consumer -eq 'AWS Load Balancer Controller') {
        $include = $false
    } elseif ($externalRoles.ContainsKey('workload_role_arn') -and $consumer -notin @('EKS nodes', 'AWS Load Balancer Controller')) {
        $include = $false
    }

    $include
})

if ($externalRoles.ContainsKey('eks_cluster_role_arn') -xor $externalRoles.ContainsKey('eks_node_group_role_arn')) {
    Add-Failure "PLATFORM_IAM_ROLES_JSON must configure eks_cluster_role_arn and eks_node_group_role_arn together when external cluster or node roles are used."
}

$usesNodeRoleForPlatformPods = -not $externalRoles.ContainsKey('load_balancer_controller_role_arn') -or -not $externalRoles.ContainsKey('workload_role_arn')
if ($usesNodeRoleForPlatformPods -and -not $externalRoles.ContainsKey('eks_node_group_role_arn')) {
    Add-Failure "Platform pods are configured to use node role credentials, but eks_node_group_role_arn is not configured. Provide an external node role with the required permissions."
}

$components = @(
    @{
        Field                  = 'eks_cluster_role_arn'
        Component              = 'EKS cluster'
        TrustService           = 'eks.amazonaws.com'
        PassService            = 'eks.amazonaws.com'
        RequireTagSession      = $false
        AttachedPolicyNames    = @('AmazonEKSClusterPolicy')
        RequiredPolicyActions  = @()
    },
    @{
        Field                  = 'eks_node_group_role_arn'
        Component              = 'EKS node group'
        TrustService           = 'ec2.amazonaws.com'
        PassService            = 'ec2.amazonaws.com'
        RequireTagSession      = $false
        AttachedPolicyNames    = @()
        RequiredPolicyActions  = $nodeRoleRequiredActions
    },
    @{
        Field                  = 'load_balancer_controller_role_arn'
        Component              = 'AWS Load Balancer Controller'
        TrustService           = 'pods.eks.amazonaws.com'
        PassService            = 'pods.eks.amazonaws.com'
        RequireTagSession      = $true
        AttachedPolicyNames    = @()
        RequiredPolicyActions  = $loadBalancerControllerRequiredActions
    },
    @{
        Field                  = 'workload_role_arn'
        Component              = 'application workloads'
        TrustService           = 'pods.eks.amazonaws.com'
        PassService            = 'pods.eks.amazonaws.com'
        RequireTagSession      = $true
        AttachedPolicyNames    = @()
        RequiredPolicyActions  = $workloadRequiredActions
    }
)

$rolePartsByField = @{}

foreach ($component in $components) {
    $field = [string]$component.Field
    if (-not $externalRoles.ContainsKey($field)) {
        continue
    }

    $roleArn = [string]$externalRoles[$field]
    $parts = Get-RoleArnParts -Arn $roleArn -Field $field -Component $component.Component
    if ($null -eq $parts) {
        continue
    }

    $rolePartsByField[$field] = $parts

    if ($parts.AccountId -ne $CallerAccountId) {
        Add-Failure "Component '$($component.Component)' uses field '$field', but the role account must match the deploy account."
        continue
    }

    $role = Get-IamRole -RoleName $parts.RoleName -Field $field -Component $component.Component
    Test-TrustPolicy -Role $role -ExpectedService $component.TrustService -RequireTagSession $component.RequireTagSession -Field $field -Component $component.Component
    Assert-AttachedPolicyNames -RoleName $parts.RoleName -ExpectedPolicyNames $component.AttachedPolicyNames -Field $field -Component $component.Component
    Test-RolePolicyActions -RoleName $parts.RoleName -RequiredActions $component.RequiredPolicyActions -Field $field -Component $component.Component
    Test-RoleEffectiveActions -RoleArn $roleArn -RoleName $parts.RoleName -RequiredActions $component.RequiredPolicyActions -Field $field -Component $component.Component
    Test-CallerPassRole -CallerPolicySourceArn $callerPolicySourceArn -RoleArn $roleArn -PassedToService $component.PassService -Field $field -Component $component.Component
}

if (-not $externalRoles.ContainsKey('load_balancer_controller_role_arn') -and $rolePartsByField.ContainsKey('eks_node_group_role_arn')) {
    $serviceLinkedRole = Invoke-NativeCommand -Command 'aws' -Arguments @('iam', 'get-role', '--role-name', 'AWSServiceRoleForElasticLoadBalancing', '--output', 'json')
    if ($serviceLinkedRole.ExitCode -eq 0) {
        Write-Host 'Elastic Load Balancing service-linked role exists.'
    } elseif ($serviceLinkedRole.Text -match 'NoSuchEntity') {
        Add-WarningMessage "Elastic Load Balancing service-linked role was not found. Entrypoint Deploy may need iam:CreateServiceLinkedRole on the node role when the first ALB is provisioned."
        Test-RolePolicyActions `
            -RoleName $rolePartsByField['eks_node_group_role_arn'].RoleName `
            -RequiredActions @(New-RequiredAction 'iam:CreateServiceLinkedRole' 'AWS Load Balancer Controller' 'If the Elastic Load Balancing service-linked role is absent, ALB provisioning may fail until that role exists.' 'Warning') `
            -Field 'eks_node_group_role_arn' `
            -Component 'Elastic Load Balancing service-linked role'
    } else {
        Add-WarningMessage "Could not confirm Elastic Load Balancing service-linked role existence: $(ConvertTo-SafeLogText $serviceLinkedRole.Text)"
    }
}

$managedRolePassTargets = @(
    @{
        AddressPrefix   = 'aws_iam_role.eks_cluster'
        Field           = 'eks_cluster_role_arn'
        Component       = 'EKS cluster'
        PassedToService = 'eks.amazonaws.com'
    },
    @{
        AddressPrefix   = 'aws_iam_role.node_group'
        Field           = 'eks_node_group_role_arn'
        Component       = 'EKS node group'
        PassedToService = 'ec2.amazonaws.com'
    }
)

foreach ($target in $managedRolePassTargets) {
    $roleChanges = @($creates | Where-Object {
        [string]$_.type -eq 'aws_iam_role' -and [string]$_.address -like "$($target.AddressPrefix)*"
    })

    foreach ($roleChange in $roleChanges) {
        $roleArn = Get-PlannedRoleArn -Change $roleChange -Partition $callerPartition -AccountId $CallerAccountId
        if ([string]::IsNullOrWhiteSpace($roleArn)) {
            Add-WarningMessage "Could not derive planned role ARN for component '$($target.Component)' field '$($target.Field)' from Terraform plan."
            continue
        }

        Test-CallerPassRole -CallerPolicySourceArn $callerPolicySourceArn -RoleArn $roleArn -PassedToService $target.PassedToService -Field $target.Field -Component $target.Component
    }
}

$iamActionByType = @{
    aws_iam_role                    = 'iam:CreateRole'
    aws_iam_policy                  = 'iam:CreatePolicy'
    aws_iam_role_policy             = 'iam:PutRolePolicy'
    aws_iam_role_policy_attachment  = 'iam:AttachRolePolicy'
    aws_iam_openid_connect_provider = 'iam:CreateOpenIDConnectProvider'
    aws_iam_instance_profile        = 'iam:CreateInstanceProfile'
    aws_iam_service_linked_role     = 'iam:CreateServiceLinkedRole'
}

$iamCreates = @($creates | Where-Object { $iamActionByType.ContainsKey([string]$_.type) })
$iamManagementActions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$planRequiredActions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($change in $iamCreates) {
    Add-RequiredAction $iamManagementActions $iamActionByType[[string]$change.type]
    Add-RequiredAction $planRequiredActions $iamActionByType[[string]$change.type]
}

$passRoleCreates = @($creates | Where-Object { @('aws_eks_cluster', 'aws_eks_node_group', 'aws_eks_pod_identity_association') -contains [string]$_.type })
if ($passRoleCreates.Count -gt 0) {
    Add-RequiredAction $planRequiredActions 'iam:PassRole'
}

$unexpectedIdentityCreates = @($creates | Where-Object {
    $address = [string]$_.address
    $type = [string]$_.type
    $include = $false

    if ($type -eq 'aws_iam_openid_connect_provider') {
        $include = $true
    }

    if ($type -in @('aws_iam_role', 'aws_iam_policy', 'aws_iam_role_policy', 'aws_iam_role_policy_attachment') -and
        ($address -like '*load_balancer_controller*' -or $address -like '*workload*')) {
        $include = $true
    }

    if ($type -eq 'aws_eks_pod_identity_association' -and
        $address -like '*load_balancer_controller*' -and
        -not $externalRoles.ContainsKey('load_balancer_controller_role_arn')) {
        $include = $true
    }

    if ($type -eq 'aws_eks_pod_identity_association' -and
        $address -like '*workload*' -and
        -not $externalRoles.ContainsKey('workload_role_arn')) {
        $include = $true
    }

    if ($type -eq 'aws_eks_addon') {
        $after = Get-PropertyValue $_.change 'after'
        $addonName = [string](Get-PropertyValue $after 'addon_name')
        if ($addonName -eq 'eks-pod-identity-agent' -and -not $externalRoles.ContainsKey('load_balancer_controller_role_arn') -and -not $externalRoles.ContainsKey('workload_role_arn')) {
            $include = $true
        }
    }

    $include
})

if ($unexpectedIdentityCreates.Count -gt 0) {
    $details = (@($unexpectedIdentityCreates | ForEach-Object { "$($_.address) ($($_.type))" }) | Sort-Object) -join '; '
    Add-Failure "Terraform plan creates identity resources that should be avoided for node role credential mode: $details"
}

Test-CallerRequiredActions -CallerPolicySourceArn $callerPolicySourceArn -RequiredActions @($iamManagementActions) -IamCreates $iamCreates

$protectedTypes = @(
    'aws_eks_cluster',
    'aws_eks_node_group',
    'aws_eks_addon',
    'aws_eks_pod_identity_association',
    'aws_ecr_repository',
    'aws_ecr_lifecycle_policy',
    'aws_sqs_queue',
    'aws_sqs_queue_redrive_allow_policy',
    'aws_iam_role',
    'aws_iam_policy',
    'aws_iam_role_policy',
    'aws_iam_role_policy_attachment',
    'aws_iam_openid_connect_provider',
    'aws_launch_template',
    'aws_ssm_parameter',
    'aws_secretsmanager_secret'
)

$dangerousChanges = @($resourceChanges | Where-Object {
    $protectedTypes -contains [string]$_.type -and
    @($_.change.actions) -contains 'delete' -and
    [string]$_.address -ne 'aws_eks_addon.managed["eks-pod-identity-agent"]'
})

if ($dangerousChanges.Count -gt 0) {
    $details = (@($dangerousChanges | ForEach-Object { "$($_.address) [$(@($_.change.actions) -join ',')]" }) | Sort-Object) -join '; '
    Add-Failure "Terraform plan contains delete or replacement actions for protected platform resources: $details"
}

if ($iamCreates.Count -eq 0) {
    Write-Host 'No IAM create/update resources found in platform plan.'
} else {
    $iamResourcesText = (@($iamCreates | ForEach-Object { "$($_.address) ($($_.type))" }) | Sort-Object) -join '; '
    Write-Host "Platform plan includes Terraform-managed IAM resources: $iamResourcesText"
}

if ($planRequiredActions.Count -gt 0) {
    $requiredActionsText = (@($planRequiredActions) | Sort-Object) -join ', '
    Write-Host "IAM actions required by the current plan: $requiredActionsText"
}

if ($externalRoles.Count -gt 0) {
    $configured = (@($externalRoles.Keys) | Sort-Object) -join ', '
    Write-Host "External IAM role fields validated from PLATFORM_IAM_ROLES_JSON: $configured"
}

Complete-Validation

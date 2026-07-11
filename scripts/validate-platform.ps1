[CmdletBinding()]
param(
    [string]$ClusterName = 'oficina',
    [string]$Namespace = 'oficina',
    [string]$AwsRegion = $env:AWS_REGION
)

$ErrorActionPreference = 'Stop'

function Invoke-ReadOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $blocked = 'create|put|update|delete|apply|install|upgrade|destroy'
    $line = "$Command $($Arguments -join ' ')"
    if ($line -match "\b($blocked)\b") {
        throw "Refusing non-read-only command: $line"
    }

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $line"
    }
}

if ([string]::IsNullOrWhiteSpace($AwsRegion)) {
    throw 'AWS region must be provided through -AwsRegion or AWS_REGION.'
}

Invoke-ReadOnly aws @('sts', 'get-caller-identity')
Invoke-ReadOnly aws @('eks', 'describe-cluster', '--name', $ClusterName, '--region', $AwsRegion)
Invoke-ReadOnly aws @('eks', 'describe-nodegroup', '--cluster-name', $ClusterName, '--nodegroup-name', 'oficina', '--region', $AwsRegion)
Invoke-ReadOnly aws @('eks', 'list-addons', '--cluster-name', $ClusterName, '--region', $AwsRegion)

Invoke-ReadOnly kubectl @('get', 'nodes')
Invoke-ReadOnly kubectl @('get', 'namespace', $Namespace)
Invoke-ReadOnly kubectl @('get', 'serviceaccount', '-n', $Namespace)

foreach ($repo in @('oficina-cadastro', 'oficina-estoque', 'oficina-ordens-servico')) {
    Invoke-ReadOnly aws @('ecr', 'describe-repositories', '--repository-names', $repo, '--region', $AwsRegion)
}

foreach ($queue in @('oficina-estoque-comandos.fifo', 'oficina-estoque-comandos-dlq.fifo', 'oficina-ordens-eventos.fifo', 'oficina-ordens-eventos-dlq.fifo')) {
    $queueUrl = (& aws sqs get-queue-url --queue-name $queue --region $AwsRegion --query 'QueueUrl' --output text)
    if ($LASTEXITCODE -ne 0) { throw "Queue not found: $queue" }
    Invoke-ReadOnly aws @('sqs', 'get-queue-attributes', '--queue-url', $queueUrl, '--attribute-names', 'All', '--region', $AwsRegion)
}

foreach ($role in @('cadastro-runtime', 'cadastro-migrator', 'estoque-runtime', 'estoque-migrator', 'ordens-runtime', 'ordens-migrator', 'db-bootstrap')) {
    Invoke-ReadOnly aws @('iam', 'get-role', '--role-name', "$ClusterName-$role")
}

Invoke-ReadOnly aws @('secretsmanager', 'describe-secret', '--secret-id', '/oficina/observability/new-relic', '--region', $AwsRegion)
Invoke-ReadOnly aws @('ssm', 'get-parameters-by-path', '--path', '/oficina/infra', '--recursive', '--region', $AwsRegion)

Invoke-ReadOnly helm @('list', '-A')
Invoke-ReadOnly helm @('status', 'aws-load-balancer-controller', '-n', 'kube-system')
Invoke-ReadOnly helm @('status', 'secrets-store-csi-driver', '-n', 'kube-system')
Invoke-ReadOnly helm @('status', 'secrets-store-csi-driver-provider-aws', '-n', 'kube-system')

Write-Host 'Read-only platform validation completed.'

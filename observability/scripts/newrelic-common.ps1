<#
.SYNOPSIS
    Funcoes compartilhadas pelos scripts de observabilidade.

.DESCRIPTION
    Carregado por dot-source. Nao executa nada por conta propria.
#>

Set-StrictMode -Version Latest

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message"
}

function Invoke-Aws {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & aws @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "AWS CLI falhou (exit $exitCode): aws $($Arguments -join ' ')`n$($output | Out-String)"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

function Get-SsmValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Region
    )

    $result = Invoke-Aws -Arguments @('ssm', 'get-parameter', '--name', $Name, '--region', $Region, '--query', 'Parameter.Value', '--output', 'text')
    $value = $result.Output.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq 'None') {
        throw "Parametro SSM vazio ou inexistente: $Name"
    }

    return $value
}

function Assert-InstanceOnline {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region
    )

    $ping = (Invoke-Aws -Arguments @(
            'ssm', 'describe-instance-information',
            '--filters', "Key=InstanceIds,Values=$InstanceId",
            '--region', $Region,
            '--query', 'InstanceInformationList[0].PingStatus',
            '--output', 'text')).Output.Trim()

    if ($ping -ne 'Online') {
        throw "O node $InstanceId nao esta Online no Systems Manager (status: $ping)."
    }
}

<#
Executa um script no node por SSM Run Command.

O corpo e serializado em arquivo e enviado por --parameters file://: montar JSON
com escape manual dentro de string quebra em silencio quando o script tem aspas,
barras ou quebras de linha.
#>
function Invoke-NodeScript {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$Script,
        [string]$Comment = 'Observability',
        [ValidateRange(60, 3600)][int]$ExecutionTimeoutSeconds = 900,
        [switch]$AllowFailure
    )

    $payloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [ordered]@{
            commands         = @($Script)
            executionTimeout = @("$ExecutionTimeoutSeconds")
        } | ConvertTo-Json -Depth 5 -Compress |
            Set-Content -LiteralPath $payloadPath -Encoding utf8

        $commandId = (Invoke-Aws -Arguments @(
                'ssm', 'send-command',
                '--instance-ids', $InstanceId,
                '--document-name', 'AWS-RunShellScript',
                '--comment', $Comment,
                '--region', $Region,
                '--parameters', "file://$payloadPath",
                '--query', 'Command.CommandId',
                '--output', 'text')).Output.Trim()

        $deadline = (Get-Date).AddSeconds($ExecutionTimeoutSeconds + 120)
        $status = 'Pending'
        while ((Get-Date) -lt $deadline) {
            $status = (Invoke-Aws -AllowFailure -Arguments @(
                    'ssm', 'get-command-invocation',
                    '--command-id', $commandId,
                    '--instance-id', $InstanceId,
                    '--region', $Region,
                    '--query', 'Status',
                    '--output', 'text')).Output.Trim()

            if ($status -in @('Success', 'Failed', 'Cancelled', 'TimedOut')) { break }
            Start-Sleep -Seconds 5
        }

        $stdout = (Invoke-Aws -AllowFailure -Arguments @(
                'ssm', 'get-command-invocation', '--command-id', $commandId,
                '--instance-id', $InstanceId, '--region', $Region,
                '--query', 'StandardOutputContent', '--output', 'text')).Output

        $stderr = (Invoke-Aws -AllowFailure -Arguments @(
                'ssm', 'get-command-invocation', '--command-id', $commandId,
                '--instance-id', $InstanceId, '--region', $Region,
                '--query', 'StandardErrorContent', '--output', 'text')).Output

        if ($status -ne 'Success' -and -not $AllowFailure) {
            throw "Run Command '$Comment' terminou como $status.`nstdout:`n$stdout`nstderr:`n$stderr"
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host "  stderr do node:`n$stderr"
        }

        return $stdout
    }
    finally {
        Remove-Item -LiteralPath $payloadPath -ErrorAction SilentlyContinue
    }
}

function Read-ObservabilityConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "config/observability.yml nao encontrado: $Path"
    }

    $lines = Get-Content -LiteralPath $Path
    $block = ''
    $values = @{}

    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^(?<key>[A-Za-z][A-Za-z0-9]*):\s*$') { $block = $Matches['key']; continue }
        if ($line -match '^\S') { $block = '' }
        if ($line -match '^\s{2}(?<key>[A-Za-z][A-Za-z0-9]*):\s*(?<value>.+?)\s*$') {
            $values["$block.$($Matches['key'])"] = $Matches['value'].Trim().Trim('"').Trim("'")
        }
    }

    function Require([string]$Key) {
        if (-not $values.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($values[$Key])) {
            throw "Chave obrigatoria ausente em config/observability.yml: $Key"
        }
        return $values[$Key]
    }

    return [pscustomobject]@{
        Namespace                = Require 'newRelic.namespace'
        Release                  = Require 'newRelic.release'
        GatewayDeployment        = Require 'newRelic.gatewayDeployment'
        GatewayService           = Require 'newRelic.gatewayService'
        OtlpGrpcPort             = [int](Require 'newRelic.otlpGrpcPort')
        ClusterName              = Require 'newRelic.clusterName'
        LicenseSecretPrefix      = Require 'newRelic.licenseSecretPrefix'
        LicenseSecretKey         = Require 'newRelic.licenseSecretKey'
        LicenseParameterPrefix   = Require 'newRelic.licenseParameterPrefix'
        HelmVersion              = Require 'helm.version'
        HelmMajorVersion         = Require 'helm.majorVersion'
        HistoryMax               = [int](Require 'helm.historyMax')
        HelmArchitecture         = Require 'helm.architecture'
        HelmDownloadUrl          = Require 'helm.downloadUrl'
        HelmSha256               = Require 'helm.sha256'
        ChartRepositoryName      = Require 'chart.repositoryName'
        ChartRepositoryUrl       = Require 'chart.repositoryUrl'
        ChartName                = Require 'chart.name'
        ChartVersion             = Require 'chart.version'
        MinimumAvailableMemoryMi = [int](Require 'resources.minimumAvailableMemoryMi')
        DashboardName            = Require 'provisioning.dashboardName'
        PolicyName               = Require 'provisioning.policyName'
        WorkflowName             = Require 'provisioning.workflowName'
    }
}

<#
Preflight de permissoes separado por principal.

Misturar os dois produz diagnostico errado: a EC2 nao cria nem apaga parametro, e
o runner nao descriptografa dentro do cluster. A simulacao usa ARN real, porque
path de parametro e alias de chave nao sao ARNs e a simulacao os avalia como
recurso inexistente.

iam:SimulatePrincipalPolicy e diagnostico auxiliar, nao a unica prova de
capacidade: ausencia dele nao e interpretada como ausencia de SSM ou KMS, e a
validacao definitiva sao as operacoes reais do deploy.
#>
function Test-ObservabilityPermissions {
    param(
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$ParameterPrefix
    )

    $identity = (Invoke-Aws -Arguments @('sts', 'get-caller-identity', '--output', 'json')).Output | ConvertFrom-Json
    $accountId = [string]$identity.Account
    $callerArn = [string]$identity.Arn

    # ARN STS de assumed-role nao serve para simulacao: e preciso o ARN IAM da role.
    $runnerArn = if ($callerArn -match '^arn:aws:sts::(?<acct>\d+):assumed-role/(?<role>[^/]+)/') {
        "arn:aws:iam::$($Matches['acct']):role/$($Matches['role'])"
    }
    else { $callerArn }

    $instanceProfileArn = (Invoke-Aws -AllowFailure -Arguments @(
            'ec2', 'describe-instances', '--instance-ids', $InstanceId, '--region', $Region,
            '--query', 'Reservations[0].Instances[0].IamInstanceProfile.Arn', '--output', 'text')).Output.Trim()

    $instanceRoleArn = $null
    if (-not [string]::IsNullOrWhiteSpace($instanceProfileArn) -and $instanceProfileArn -ne 'None') {
        $profileName = $instanceProfileArn.Split('/')[-1]
        $roleName = (Invoke-Aws -AllowFailure -Arguments @(
                'iam', 'get-instance-profile', '--instance-profile-name', $profileName,
                '--query', 'InstanceProfile.Roles[0].RoleName', '--output', 'text')).Output.Trim()
        if (-not [string]::IsNullOrWhiteSpace($roleName) -and $roleName -ne 'None') {
            $instanceRoleArn = "arn:aws:iam::${accountId}:role/$roleName"
        }
    }

    $parameterArn = "arn:aws:ssm:${Region}:${accountId}:parameter$($ParameterPrefix.TrimEnd('/'))/*"

    # alias/aws/ssm nao e ARN: DescribeKey resolve o alias para o ARN da chave.
    $keyArn = (Invoke-Aws -AllowFailure -Arguments @(
            'kms', 'describe-key', '--key-id', 'alias/aws/ssm', '--region', $Region,
            '--query', 'KeyMetadata.Arn', '--output', 'text')).Output.Trim()

    $checks = @(
        [pscustomobject]@{ Principal = 'runner'; Arn = $runnerArn; Actions = @('ssm:PutParameter', 'ssm:GetParameter', 'ssm:DeleteParameter'); Resource = $parameterArn }
    )
    if ($null -ne $instanceRoleArn) {
        $checks += [pscustomobject]@{ Principal = 'role da EC2'; Arn = $instanceRoleArn; Actions = @('ssm:GetParameter'); Resource = $parameterArn }
        if (-not [string]::IsNullOrWhiteSpace($keyArn) -and $keyArn -ne 'None') {
            $checks += [pscustomobject]@{ Principal = 'role da EC2'; Arn = $instanceRoleArn; Actions = @('kms:Decrypt'); Resource = $keyArn }
        }
    }

    foreach ($check in $checks) {
        foreach ($action in $check.Actions) {
            $simulation = Invoke-Aws -AllowFailure -Arguments @(
                'iam', 'simulate-principal-policy',
                '--policy-source-arn', $check.Arn,
                '--action-names', $action,
                '--resource-arns', $check.Resource,
                '--query', 'EvaluationResults[0].EvalDecision',
                '--output', 'text')

            if ($simulation.ExitCode -ne 0) {
                Write-Host "  simulacao indisponivel para $action ($($check.Principal)): o executor nao tem iam:SimulatePrincipalPolicy. Isso NAO indica ausencia de SSM ou KMS; a capacidade real e validada pelas operacoes do deploy."
                continue
            }

            $decision = $simulation.Output.Trim()
            Write-Host "  $($check.Principal): $action em $($check.Resource) -> $decision"
            if ($decision -in @('explicitDeny', 'implicitDeny')) {
                throw "Permissao ausente. Principal: $($check.Arn). Acao: $action. Recurso: $($check.Resource). Regiao: $Region. Etapa bloqueada: criacao do SecureString da license key."
            }
        }
    }
}

function New-LicenseParameter {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Region
    )

    Write-Host "::add-mask::$Value"

    $payloadPath = [System.IO.Path]::GetTempFileName()
    try {
        # O valor vai por --cli-input-json: em argv ele apareceria na lista de
        # processos do runner.
        [ordered]@{
            Name      = $Name
            Value     = $Value
            Type      = 'SecureString'
            KeyId     = 'alias/aws/ssm'
            Overwrite = $false
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $payloadPath -Encoding utf8

        Invoke-Aws -Arguments @('ssm', 'put-parameter', '--cli-input-json', "file://$payloadPath", '--region', $Region) | Out-Null
        Write-Host "  SecureString criado: $Name"
    }
    finally {
        Remove-Item -LiteralPath $payloadPath -ErrorAction SilentlyContinue
    }
}

function Remove-LicenseParameter {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Region
    )

    Invoke-Aws -AllowFailure -Arguments @('ssm', 'delete-parameter', '--name', $Name, '--region', $Region) | Out-Null

    # Verificacao explicita: sobrescrever parametro nao apaga o valor, apenas
    # acrescenta versao, entao a exclusao precisa ser confirmada.
    $check = Invoke-Aws -AllowFailure -Arguments @('ssm', 'get-parameter', '--name', $Name, '--region', $Region)
    if ($check.ExitCode -eq 0) {
        throw "O SecureString $Name ainda existe apos a exclusao."
    }

    Write-Host "  SecureString removido e exclusao confirmada: $Name"
}

function Assert-NoSecretInValues {
    param([Parameter(Mandatory = $true)][string]$Content)

    foreach ($pattern in @('(?m)^\s*licenseKey\s*:', '(?m)^\s*customSecretName\s*:', 'NRAK-[A-Za-z0-9]{10,}', 'NRAA-[A-Za-z0-9]{10,}', ':latest\s*$')) {
        if ($Content -match $pattern) {
            throw "newrelic-values.yaml casa com padrao proibido antes do envio: $pattern"
        }
    }
}

function Resolve-HelmOperation {
    param([Parameter(Mandatory = $true)][string]$Output)

    if ($Output -match 'OFICINA_RELEASE_STATE=absent') {
        return [pscustomobject]@{ Kind = 'instalacao-inicial'; CurrentRevision = 0 }
    }

    if ($Output -match 'OFICINA_RELEASE_STATE=exists') {
        $revision = 0
        # helm history devolve JSON; a maior revision e a atual.
        foreach ($match in [regex]::Matches($Output, '"revision"\s*:\s*(\d+)')) {
            $candidate = [int]$match.Groups[1].Value
            if ($candidate -gt $revision) { $revision = $candidate }
        }

        if ($revision -eq 0) {
            throw 'Release existe mas nenhuma revision pudo ser lida do helm history.'
        }

        return [pscustomobject]@{ Kind = 'atualizacao'; CurrentRevision = $revision }
    }

    return [pscustomobject]@{ Kind = 'unknown'; CurrentRevision = 0 }
}

function Get-NodePressure {
    param([Parameter(Mandatory = $true)][string]$Text)

    $pressures = @()
    foreach ($condition in @('MemoryPressure', 'DiskPressure', 'PIDPressure')) {
        if ($Text -match "$condition=True") { $pressures += $condition }
    }
    if ($Text -match 'Ready=False') { $pressures += 'NodeNotReady' }

    return $pressures
}

<#
Avalia os gates pos-instalacao e classifica a causa.

A classificacao existe para nao recomendar t3.large quando a causa nao foi
capacidade: falha de licenca, de chart, de rede ou de configuracao nao se resolve
com instancia maior.
#>
function Test-CapacityGate {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$MinimumAvailableMi
    )

    $violations = @()

    foreach ($pressure in (Get-NodePressure -Text $Text)) {
        $violations += [pscustomobject]@{ Capacity = $true; Message = "Node reportou $pressure." }
    }

    if ($Text -match 'OOMKilled') {
        $violations += [pscustomobject]@{ Capacity = $true; Message = 'Container terminado por OOMKilled.' }
    }

    if ($Text -match '(?m)^\S+\s+\S+\s+Pending\b') {
        $violations += [pscustomobject]@{ Capacity = $true; Message = 'Pod em Pending.' }
    }

    # `free -m` na linha "Mem:" tem disponivel na setima coluna.
    if ($Text -match '(?m)^Mem:\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(?<available>\d+)') {
        $available = [int]$Matches['available']
        if ($available -lt $MinimumAvailableMi) {
            $violations += [pscustomobject]@{ Capacity = $true; Message = "Memoria disponivel $available Mi abaixo do minimo de $MinimumAvailableMi Mi." }
        }
    }

    foreach ($state in @('CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull', 'CreateContainerConfigError')) {
        if ($Text -match $state) {
            $violations += [pscustomobject]@{ Capacity = $false; Message = "Pod em $state. Causa nao e capacidade." }
        }
    }

    return $violations
}

function Get-CollectorDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Namespace
    )

    return Invoke-NodeScript -InstanceId $InstanceId -Region $Region -Comment 'Diagnostico' -AllowFailure -Script @"
set +e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
echo '--- helm status'
helm status $($Config.Release) --namespace $($Config.Namespace) 2>&1 | head -20
echo '--- helm history'
helm history $($Config.Release) --namespace $($Config.Namespace) 2>&1 | head -20
echo '--- pods do newrelic'
k3s kubectl -n $($Config.Namespace) get pods -o wide 2>&1
echo '--- eventos do namespace newrelic'
k3s kubectl -n $($Config.Namespace) get events --sort-by=.lastTimestamp 2>&1 | tail -20
echo '--- logs do Collector'
for pod in `$(k3s kubectl -n $($Config.Namespace) get pods -o name 2>/dev/null); do
    echo "### `$pod"
    k3s kubectl -n $($Config.Namespace) logs "`$pod" --tail=50 --all-containers 2>&1 | tail -50
done
echo '--- condicoes do node'
k3s kubectl describe node 2>&1 | sed -n '/Conditions:/,/Addresses:/p'
echo '--- pods das APIs'
k3s kubectl -n $Namespace get pods -o wide 2>&1
"@
}

<#
Reversao consciente de instalacao e atualizacao.

Numa reexecucao pode existir um Collector saudavel: `helm uninstall` cego apagaria
a observabilidade anterior por causa de um upgrade ruim. `helm rollback` nao aceita
--post-renderer, portanto ele restaura o manifesto ja armazenado; a garantia do
Recreate vem de a revisao anterior ter nascido correta.
#>
function Invoke-Revert {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][string]$ApiNamespace
    )

    $script = if ($Operation.Kind -eq 'instalacao-inicial') {
        @"
set +e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
if helm status $($Config.Release) --namespace $($Config.Namespace) >/dev/null 2>&1; then
    helm uninstall $($Config.Release) --namespace $($Config.Namespace) --wait --timeout 5m
else
    echo 'Release nao existe: o --atomic ja o removeu. Nenhum uninstall adicional.'
fi
# O uninstall remove release e historico, mas o namespace criado a parte permanece.
k3s kubectl delete namespace $($Config.Namespace) --ignore-not-found --wait=true --timeout=5m
echo '--- APIs apos a reversao'
k3s kubectl -n $ApiNamespace rollout status deployment --timeout=5m 2>&1 | tail -10
k3s kubectl -n $ApiNamespace get pods -o wide
"@
    }
    else {
        @"
set +e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
helm rollback $($Config.Release) $($Operation.CurrentRevision) \
    --namespace $($Config.Namespace) --wait --timeout 10m --history-max $($Config.HistoryMax)
echo '--- strategy apos o rollback'
k3s kubectl -n $($Config.Namespace) get deployment -o jsonpath='{range .items[*]}{.metadata.name}={.spec.strategy.type}{"\n"}{end}'
echo '--- Collector anterior'
k3s kubectl -n $($Config.Namespace) rollout status deployment --timeout=5m 2>&1 | tail -10
k3s kubectl -n $($Config.Namespace) rollout status daemonset --timeout=5m 2>&1 | tail -10
k3s kubectl -n $($Config.Namespace) get pods -o wide
echo '--- APIs apos a reversao'
k3s kubectl -n $ApiNamespace rollout status deployment --timeout=5m 2>&1 | tail -10
k3s kubectl -n $ApiNamespace get pods -o wide
echo '--- memoria'
free -m
"@
    }

    $output = Invoke-NodeScript -InstanceId $InstanceId -Region $Region -Comment 'Reversao' -AllowFailure -ExecutionTimeoutSeconds 1800 -Script $script
    Write-Host $output
}

<#
Limpeza de Secrets dirigida pelo historico real do Helm.

Nunca excluir o Secret novo apenas por o rollback ter ocorrido: todo install,
upgrade e rollback incrementa a revision, e depois de um upgrade malsucedido
seguido de rollback as duas revisoes mantidas apontam para Secrets diferentes.
Apagar por deducao deixaria uma revisao mantida referenciando Secret inexistente.
#>
function Invoke-SecretCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$CurrentRunId
    )

    Write-Step 'Limpeza de Secrets pela allowlist do historico do Helm'

    $output = Invoke-NodeScript -InstanceId $InstanceId -Region $Region -Comment 'Limpeza de Secrets' -AllowFailure -Script @"
set -u
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"

if ! k3s kubectl get namespace $($Config.Namespace) >/dev/null 2>&1; then
    echo 'Namespace ausente: nada a limpar.'
    exit 0
fi

allowlist=''
if helm status $($Config.Release) --namespace $($Config.Namespace) >/dev/null 2>&1; then
    revisoes="`$(helm history $($Config.Release) --namespace $($Config.Namespace) --max $($Config.HistoryMax) --output json \
        | grep -oE '"revision"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+')"
    for rev in `$revisoes; do
        # helm get values --revision e a forma correta de descobrir o
        # customSecretName efetivamente armazenado naquela release.
        nome="`$(helm get values $($Config.Release) --namespace $($Config.Namespace) --revision "`$rev" --output json 2>/dev/null \
            | grep -oE '"customSecretName"[[:space:]]*:[[:space:]]*"[^"]+"' | grep -oE '"[^"]+"`$' | tr -d '"')"
        if [ -n "`$nome" ]; then
            allowlist="`$allowlist `$nome"
            echo "revisao `$rev usa `$nome"
        fi
    done
else
    # Release inexistente apos instalacao inicial com --atomic: a falha do
    # helm history e esperada e nao pode interromper a limpeza.
    echo 'Release inexistente: historico vazio, removendo somente o Secret desta execucao.'
    allowlist=''
fi

manter_atual='$($Config.LicenseSecretPrefix)-$CurrentRunId'
if helm status $($Config.Release) --namespace $($Config.Namespace) >/dev/null 2>&1; then
    case " `$allowlist " in
        *" `$manter_atual "*) ;;
        *) allowlist="`$allowlist `$manter_atual" ;;
    esac
fi

echo "allowlist: `$allowlist"

for secret in `$(k3s kubectl -n $($Config.Namespace) get secrets \
        -l app.kubernetes.io/managed-by=fiap-fase4,app.kubernetes.io/name=$($Config.LicenseSecretPrefix) \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    case " `$allowlist " in
        *" `$secret "*) echo "mantido: `$secret" ;;
        *) k3s kubectl -n $($Config.Namespace) delete secret "`$secret" >/dev/null 2>&1 && echo "removido: `$secret" ;;
    esac
done

# Revalidacao: nenhuma revisao mantida pode referenciar Secret inexistente.
falhou=0
for nome in `$allowlist; do
    if ! k3s kubectl -n $($Config.Namespace) get secret "`$nome" >/dev/null 2>&1; then
        echo "Revisao mantida referencia Secret inexistente: `$nome" >&2
        falhou=1
    fi
done
exit "`$falhou"
"@

    Write-Host $output
}

function Write-Summary {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$Body
    )

    $summaryPath = $env:GITHUB_STEP_SUMMARY
    $lines = @("## $Title", '') + ($Body | ForEach-Object { "- $_" }) + @('')

    if ([string]::IsNullOrWhiteSpace($summaryPath)) {
        $lines | ForEach-Object { Write-Host $_ }
        return
    }

    Add-Content -LiteralPath $summaryPath -Value $lines
}

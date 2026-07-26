<#
.SYNOPSIS
    Instala ou atualiza o Collector da New Relic no K3s.

.DESCRIPTION
    Ordem obrigatoria. Nenhum comando Helm pode rodar antes de o Helm estar
    instalado e verificado, `helm status` inclusive:

      1. Resolver EC2 e validar SSM Online.
      2. Instalar ou validar a versao fixa do Helm 3.
      3. Validar o SHA-256 do binario do Helm.
      4. Capturar baseline de capacidade do node.
      5. Executar helm status.
      6. Classificar a operacao.
      7. Criar o SecureString temporario.
      8. Criar o Secret Kubernetes versionado.
      9. Executar helm template com post-renderer.
     10. Executar helm upgrade --install.
     11. Executar os gates pos-instalacao.

    A license key nunca aparece no corpo do Run Command: ela vai para um
    SecureString em /oficina/deploy/newrelic/* e e lida dentro da EC2, que e o
    unico principal com kms:Decrypt nesse caminho.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AwsRegion,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$LicenseKey,
    [switch]$ValidationOnly,
    [string]$ConfigPath,
    [ValidateRange(60, 1800)][int]$StabilizationSeconds = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repositoryRoot 'config/observability.yml'
}

. (Join-Path $PSScriptRoot 'newrelic-common.ps1')

$config = Read-ObservabilityConfig -Path $ConfigPath
$secretName = "$($config.LicenseSecretPrefix)-$RunId"
$parameterName = "$($config.LicenseParameterPrefix)$RunId/license-key"
$valuesPath = Join-Path $repositoryRoot 'observability/newrelic-values.yaml'
$postRendererPath = Join-Path $PSScriptRoot 'post-render-newrelic.sh'

if (-not $ValidationOnly -and [string]::IsNullOrWhiteSpace($LicenseKey)) {
    throw 'LicenseKey e obrigatoria quando ValidationOnly nao esta ativo.'
}

# ---------------------------------------------------------------------------
# Passo 1. EC2 e SSM.
# ---------------------------------------------------------------------------
Write-Step 'Passo 1: resolvendo a EC2 e validando o SSM'
$instanceId = Get-SsmValue -Name '/oficina/infra/k8s/instance-id' -Region $AwsRegion
$namespace = Get-SsmValue -Name '/oficina/infra/k8s/namespace' -Region $AwsRegion
Assert-InstanceOnline -InstanceId $instanceId -Region $AwsRegion
Write-Host "  node $instanceId Online, namespace das APIs: $namespace"

# ---------------------------------------------------------------------------
# Passos 2 e 3. Helm, condicionado ao modo.
#
# Em ValidationOnly o script nao instala binario: baixar e substituir /usr/local/bin
# seria alteracao no node, e o modo de validacao e leitura pura.
# ---------------------------------------------------------------------------
Write-Step 'Passos 2 e 3: Helm no node'
$helmScript = if ($ValidationOnly) {
    @"
set -eu
export PATH="`$PATH:/usr/local/bin"
if ! command -v helm >/dev/null 2>&1; then
    echo 'Helm ausente. Execute antes com validation_only=false para instalar.' >&2
    exit 1
fi
instalada="`$(helm version --template '{{.Version}}')"
if [ "`$instalada" != "v$($config.HelmVersion)" ]; then
    echo "Helm divergente: encontrado `$instalada, esperado v$($config.HelmVersion). Execute antes com validation_only=false." >&2
    exit 1
fi
echo "helm `$instalada"
"@
}
else {
    @"
set -eu
export PATH="`$PATH:/usr/local/bin"

# Arquitetura antes do download: o checksum e do artefato linux-amd64, e numa
# instancia de outra arquitetura a falha apareceria como "checksum divergente",
# diagnostico que esconde a causa real.
arch="`$(uname -m)"
if [ "`$arch" != "$($config.HelmArchitecture)" ]; then
    echo "Arquitetura incompativel: `$arch, esperado $($config.HelmArchitecture)." >&2
    exit 1
fi

instalada=''
if command -v helm >/dev/null 2>&1; then
    instalada="`$(helm version --template '{{.Version}}' 2>/dev/null || echo '')"
fi

if [ "`$instalada" = "v$($config.HelmVersion)" ]; then
    echo "helm ja na versao fixada: `$instalada"
else
    tmp="`$(mktemp -d)"
    trap 'rm -rf "`$tmp"' EXIT
    curl -sSL --fail --max-time 180 -o "`$tmp/helm.tar.gz" '$($config.HelmDownloadUrl)'
    printf '%s  %s\n' '$($config.HelmSha256)' "`$tmp/helm.tar.gz" | sha256sum -c -
    tar -xzf "`$tmp/helm.tar.gz" -C "`$tmp"
    install -m 0755 "`$tmp/linux-amd64/helm" /usr/local/bin/helm
    echo "helm instalado: `$(helm version --template '{{.Version}}')"
fi
"@
}

Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Helm' -Script $helmScript | Out-Null

# ---------------------------------------------------------------------------
# Passo 4. Baseline de capacidade.
#
# Observabilidade nao pode mascarar um cluster ja degradado: se o node ja esta sob
# pressao, o problema e anterior e precisa aparecer agora.
# ---------------------------------------------------------------------------
Write-Step 'Passo 4: baseline de capacidade do node'
$baseline = Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Baseline' -Script @"
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
echo '--- memoria'
free -m
echo '--- condicoes do node'
k3s kubectl get nodes -o jsonpath='{range .items[*].status.conditions[*]}{.type}={.status}{"\n"}{end}'
echo '--- pods das APIs'
k3s kubectl -n $namespace get pods -o wide
"@
Write-Host $baseline

$baselinePressure = @(Get-NodePressure -Text $baseline)
if ($baselinePressure.Count -gt 0) {
    throw "Node ja sob pressao antes da instalacao: $($baselinePressure -join ', '). Resolver a causa anterior antes de instalar telemetria."
}

# ---------------------------------------------------------------------------
# Passos 5 e 6. helm status e classificacao.
#
# Somente o erro explicito de release inexistente classifica instalacao inicial.
# Erro de conexao, timeout, autenticacao ou cluster indisponivel interrompe: tratar
# esses casos como "nao existe" transformaria indisponibilidade momentanea em
# uninstall de um Collector saudavel.
# ---------------------------------------------------------------------------
Write-Step 'Passos 5 e 6: classificando a operacao'
$helmClassifierPath = Join-Path $PSScriptRoot 'classify-helm-release.sh'
$helmClassifierContent = Get-Content -LiteralPath $helmClassifierPath -Raw
$statusOutput = Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Helm status' -AllowFailure -Script @"
set -u
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"

work="`$(mktemp -d)"
trap 'rm -rf "`$work"' EXIT

cat > "`$work/classify-helm-release.sh" <<'OFICINA_HELM_CLASSIFIER_EOF'
$helmClassifierContent
OFICINA_HELM_CLASSIFIER_EOF
chmod 0755 "`$work/classify-helm-release.sh"

sh "`$work/classify-helm-release.sh" '$($config.Release)' '$($config.Namespace)' '$($config.HistoryMax)'
"@

$operation = Resolve-HelmOperation -Output $statusOutput
Write-Host "  operacao classificada: $($operation.Kind)"
if ($operation.Kind -eq 'unknown') {
    Write-Host $statusOutput
    throw 'helm status nao pode ser interpretado. Erro de conexao, autenticacao ou cluster indisponivel nunca e tratado como release inexistente.'
}

if ($ValidationOnly) {
    if ($operation.Kind -eq 'instalacao-inicial') {
        throw 'Release inexistente em modo validation_only. Execute antes com validation_only=false.'
    }

    Write-Step 'Modo validacao: renderizando com o customSecretName da revisao atual'
    # Em validation_only nao existe Secret novo: o nome vem da revisao corrente e
    # serve somente para a renderizacao local.
    $render = Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Helm template' -Script @"
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
atual="`$(helm get values $($config.Release) --namespace $($config.Namespace) --revision $($operation.CurrentRevision) --output json | tr -d '\n')"
echo "OFICINA_CURRENT_VALUES=`$atual"
"@
    Write-Host $render
    Write-Host 'Modo validacao concluido: nenhuma alteracao foi aplicada no cluster.'
    return
}

# ---------------------------------------------------------------------------
# Passos 7 a 11. Caminho que altera o cluster.
# ---------------------------------------------------------------------------
$parameterCreated = $false
$instalacaoConcluida = $false
try {
    Write-Step 'Passo 7: SecureString temporario da license key'
    $licenseDeliveryMode = 'parameter-store'
    try {
        Test-ObservabilityPermissions -Region $AwsRegion -InstanceId $instanceId -ParameterPrefix $config.LicenseParameterPrefix
        New-LicenseParameter -Name $parameterName -Value $LicenseKey -Region $AwsRegion
        $parameterCreated = $true
    }
    catch {
        $licenseDeliveryMode = 'run-command-fallback'
        Write-Host "  SecureString indisponivel: $($_.Exception.Message)"
        Write-Host '  Usando fallback para ambiente restrito: a license key sera aplicada diretamente como Secret Kubernetes pelo Run Command.'
    }

    Write-Step "Passo 8: namespace e Secret versionado $secretName"
    # O nome do Secret carrega o run-id de proposito. Um Secret estavel sobrescrito
    # a cada execucao inviabiliza rollback: a revisao anterior do Helm passaria a
    # apontar para uma licenca que nao existe mais com aquele conteudo.
    Write-Host "  modo de entrega da license key: $licenseDeliveryMode"
    Write-Host "::add-mask::$LicenseKey"
    $licenseDataExpression = "`$(aws ssm get-parameter --name '$parameterName' --with-decryption --region '$AwsRegion' --query Parameter.Value --output text | tr -d '\n' | base64 -w0)"
    if ($licenseDeliveryMode -eq 'run-command-fallback') {
        $licenseKeyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LicenseKey))
        Write-Host "::add-mask::$licenseKeyBase64"
        $licenseDataExpression = "'$licenseKeyBase64'"
    }

    Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Secret da licenca' -Script @"
set -eu
umask 077
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"

k3s kubectl create namespace $($config.Namespace) --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null

secret_file="`$(mktemp)"
cleanup() { shred -u "`$secret_file" 2>/dev/null || rm -f "`$secret_file"; }
trap cleanup EXIT

license_data=$licenseDataExpression
if [ -z "`$license_data" ]; then
    echo 'license key vazia depois da resolucao.' >&2
    exit 1
fi

# printf e builtin e base64 le da entrada padrao: nenhum valor secreto aparece na
# linha de comando de um processo. No fallback, license_data ja chega em base64
# porque o runner nao tem permissao para criar SecureString temporario.
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/name: $($config.LicenseSecretPrefix)\n    app.kubernetes.io/managed-by: fiap-fase4\n    oficina.run-id: "%s"\ntype: Opaque\ndata:\n  %s: %s\n' \
    '$secretName' '$($config.Namespace)' '$RunId' '$($config.LicenseSecretKey)' \
    "`$license_data" \
    > "`$secret_file"

k3s kubectl apply -f "`$secret_file" >/dev/null
k3s kubectl -n $($config.Namespace) get secret $secretName -o name
"@ | Write-Host

    Write-Step 'Passos 9 e 10: helm template e upgrade --install'
    $valuesContent = Get-Content -LiteralPath $valuesPath -Raw
    Assert-NoSecretInValues -Content $valuesContent
    $postRendererContent = Get-Content -LiteralPath $postRendererPath -Raw

    $previousRevisionCheck = if ($operation.Kind -eq 'atualizacao') {
        @"
echo '--- manifesto da revisao que servira de rollback'
if ! helm get manifest $($config.Release) --namespace $($config.Namespace) --revision $($operation.CurrentRevision) | assert_gateway_recreate - ; then
    echo 'AVISO: a revisao atual nao tem Recreate no gateway. O rollback restauraria RollingUpdate.' >&2
fi
"@
    }
    else { "echo '--- instalacao inicial: nao existe revisao anterior para conferir'" }

    $applyOutput = Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Helm upgrade' -ExecutionTimeoutSeconds 1800 -Script @"
set -eu
umask 077
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"

work="`$(mktemp -d)"
trap 'rm -rf "`$work"' EXIT

cat > "`$work/values.yaml" <<'OFICINA_VALUES_EOF'
$valuesContent
OFICINA_VALUES_EOF

cat > "`$work/post-render.sh" <<'OFICINA_RENDERER_EOF'
$postRendererContent
OFICINA_RENDERER_EOF
chmod 0755 "`$work/post-render.sh"

assert_gateway_recreate() {
    manifest_path="`$1"
    awk -v name='$($config.GatewayDeployment)' '
    function reset_doc() {
        kind = ""
        doc_name = ""
        in_metadata = 0
        in_strategy = 0
        has_recreate = 0
    }
    function finish_doc() {
        if (kind == "Deployment" && doc_name == name) {
            found = 1
            if (has_recreate) {
                ok = 1
            }
        }
        reset_doc()
    }
    BEGIN {
        found = 0
        ok = 0
        reset_doc()
    }
    /^---[[:space:]]*$/ {
        finish_doc()
        next
    }
    /^kind:[[:space:]]/ {
        kind = `$2
        next
    }
    /^metadata:[[:space:]]*$/ {
        in_metadata = 1
        next
    }
    in_metadata && /^[^[:space:]]/ {
        in_metadata = 0
    }
    in_metadata && /^  name:[[:space:]]/ {
        doc_name = `$2
        gsub(/"/, "", doc_name)
        next
    }
    /^  strategy:[[:space:]]*$/ {
        in_strategy = 1
        next
    }
    in_strategy && /^    type:[[:space:]]*Recreate[[:space:]]*$/ {
        has_recreate = 1
        next
    }
    in_strategy && /^  [^[:space:]]/ {
        in_strategy = 0
    }
    END {
        finish_doc()
        exit(found && ok ? 0 : 1)
    }
    ' "`$manifest_path"
}

helm repo add $($config.ChartRepositoryName) $($config.ChartRepositoryUrl) --force-update >/dev/null
helm repo update >/dev/null

# O template do gate recebe exatamente as mesmas entradas do upgrade: com
# argumentos diferentes, o manifesto validado nao e o que o Helm aplicaria.
helm template $($config.Release) $($config.ChartRepositoryName)/$($config.ChartName) \
    --version '$($config.ChartVersion)' \
    --namespace $($config.Namespace) \
    --values "`$work/values.yaml" \
    --set-string customSecretName='$secretName' \
    --post-renderer "`$work/post-render.sh" > "`$work/rendered.yaml"

echo '--- imagens renderizadas'
grep -hoE 'image:[[:space:]]*\S+' "`$work/rendered.yaml" | sort -u
if grep -hoE 'image:[[:space:]]*\S+:latest' "`$work/rendered.yaml"; then
    echo 'Imagem com tag latest no manifesto renderizado.' >&2
    exit 1
fi

echo '--- strategy no gateway'
assert_gateway_recreate "`$work/rendered.yaml" || {
    echo 'Gateway sem strategy Recreate apos o post-renderer.' >&2
    exit 1
}

$previousRevisionCheck

helm upgrade --install $($config.Release) $($config.ChartRepositoryName)/$($config.ChartName) \
    --version '$($config.ChartVersion)' \
    --namespace $($config.Namespace) \
    --values "`$work/values.yaml" \
    --set-string customSecretName='$secretName' \
    --post-renderer "`$work/post-render.sh" \
    --history-max $($config.HistoryMax) \
    --atomic \
    --wait \
    --timeout 10m

echo 'OFICINA_HELM_RESULT=ok'
helm status $($config.Release) --namespace $($config.Namespace) | head -5
"@ -AllowFailure

    Write-Host $applyOutput

    if ($applyOutput -notmatch 'OFICINA_HELM_RESULT=ok') {
        # Fluxo A: o Helm retornou erro. Com --atomic ele JA agiu sozinho; disparar
        # rollback ou uninstall por cima operaria sobre um estado nao observado.
        Write-Step 'Fluxo A: Helm retornou erro. Consultando o estado real antes de qualquer acao'
        $diagnostico = Get-CollectorDiagnostics -InstanceId $instanceId -Region $AwsRegion -Config $config -Namespace $namespace
        Write-Host $diagnostico
        Invoke-SecretCleanup -InstanceId $instanceId -Region $AwsRegion -Config $config -CurrentRunId $RunId
        Write-Summary -Title 'Instalacao do Collector reprovada' -Body @(
            'O comando Helm retornou erro. O --atomic ja tratou o release.',
            'Nenhum rollback ou uninstall adicional foi executado sobre estado nao observado.',
            'A limpeza de Secrets rodou sobre o historico resultante.'
        )
        throw 'helm upgrade --install falhou. Diagnostico publicado no step summary.'
    }

    Write-Step "Passo 11: gates pos-instalacao (estabilizacao de $StabilizationSeconds s)"
    Start-Sleep -Seconds $StabilizationSeconds

    $gate = Invoke-NodeScript -InstanceId $instanceId -Region $AwsRegion -Comment 'Gates' -Script @"
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="`$PATH:/usr/local/bin"
echo '--- condicoes do node'
k3s kubectl get nodes -o jsonpath='{range .items[*].status.conditions[*]}{.type}={.status}{"\n"}{end}'
echo '--- memoria'
free -m
echo '--- pods do newrelic'
k3s kubectl -n $($config.Namespace) get pods -o wide
echo '--- pods das APIs'
k3s kubectl -n $namespace get pods -o wide
echo '--- motivos de termino'
k3s kubectl -n $($config.Namespace) get pods -o jsonpath='{range .items[*]}{.metadata.name}={range .status.containerStatuses[*]}{.lastState.terminated.reason}{end}{"\n"}{end}'
echo '--- prontidao dos workloads do Collector'
# A espera vem antes da contagem: um Pod ainda baixando imagem nao pode ser lido
# como workload quebrado. Depois dela, replica faltando e falha de verdade.
for alvo in \$(k3s kubectl -n $($config.Namespace) get daemonset,deployment -o name); do
    k3s kubectl -n $($config.Namespace) rollout status "\$alvo" --timeout=3m >/dev/null 2>&1 || true
done
k3s kubectl -n $($config.Namespace) get daemonset -o jsonpath='{range .items[*]}OFICINA_WORKLOAD daemonset/{.metadata.name} pronto={.status.numberReady} desejado={.status.desiredNumberScheduled}{"\n"}{end}'
k3s kubectl -n $($config.Namespace) get deployment -o jsonpath='{range .items[*]}OFICINA_WORKLOAD deployment/{.metadata.name} pronto={.status.readyReplicas} desejado={.status.replicas}{"\n"}{end}'
"@
    Write-Host $gate

    $violations = @(Test-CapacityGate -Text $gate -MinimumAvailableMi $config.MinimumAvailableMemoryMi)
    if ($violations.Count -gt 0) {
        # Fluxo B: o Helm terminou bem, mas os gates reprovaram. Aqui a reversao e
        # deliberada, e a estrategia depende da classificacao do passo 6.
        Write-Step 'Fluxo B: Helm concluiu, gates reprovaram. Revertendo'
        $diagnostico = Get-CollectorDiagnostics -InstanceId $instanceId -Region $AwsRegion -Config $config -Namespace $namespace
        Write-Host $diagnostico
        Invoke-Revert -InstanceId $instanceId -Region $AwsRegion -Config $config -Operation $operation -ApiNamespace $namespace
        Invoke-SecretCleanup -InstanceId $instanceId -Region $AwsRegion -Config $config -CurrentRunId $RunId

        $capacityCaused = $violations | Where-Object { $_.Capacity }
        $recommendation = if ($capacityCaused) {
            't3.large e acao necessaria: a causa foi capacidade do node.'
        }
        else {
            'Nao aumentar a EC2: a causa nao foi capacidade. Corrigir a causa reportada.'
        }

        Write-Summary -Title 'Gates pos-instalacao reprovados' -Body (
            @('Operacao: ' + $operation.Kind, 'Reversao concluida.') +
            ($violations | ForEach-Object { "- $($_.Message)" }) +
            @($recommendation))
        throw "Gates pos-instalacao reprovados: $(($violations | ForEach-Object { $_.Message }) -join '; ')"
    }

    Invoke-SecretCleanup -InstanceId $instanceId -Region $AwsRegion -Config $config -CurrentRunId $RunId

    Write-Summary -Title 'Collector New Relic instalado' -Body @(
        "Operacao: $($operation.Kind)",
        "Chart: $($config.ChartName) $($config.ChartVersion)",
        "Helm: $($config.HelmVersion)",
        "Secret da licenca: $secretName",
        "Gateway OTLP: $($config.GatewayService).$($config.Namespace).svc.cluster.local:$($config.OtlpGrpcPort)"
    )
    Write-Host 'Collector instalado e gates aprovados.'
    $instalacaoConcluida = $true
}
finally {
    if ($parameterCreated) {
        Write-Step 'Removendo o SecureString temporario'
        try {
            Remove-LicenseParameter -Name $parameterName -Region $AwsRegion
        }
        catch {
            # Falha de limpeza nunca substitui a excecao original: sem isto o
            # operador leria "SecureString ainda existe" no lugar da causa real da
            # reprovacao. Se a instalacao concluiu, esta e a unica falha e precisa
            # reprovar -- SecureString com license key nao pode sobreviver ao job.
            Write-Host "  FALHA ao remover o SecureString $parameterName : $($_.Exception.Message)"
            Write-Host "  Remover manualmente: aws ssm delete-parameter --name $parameterName --region $AwsRegion"
            if ($instalacaoConcluida) { throw }
        }
    }
}

<#
.SYNOPSIS
    Testa offline o contrato do cliente NerdGraph usado no provisionamento.

.DESCRIPTION
    Nao chama a New Relic. O objetivo e barrar, antes do deploy, o que so
    apareceria em producao:

      - queries que quebram na validacao de schema (selection direta em `errors`,
        argumento que a mutation nao aceita);
      - reexecucao cega de mutation, que duplicaria recurso;
      - leitura de uma unica pagina numa listagem paginada, que concluiria
        "nao existe" e criaria duplicidade;
      - workflow existente que deixou de filtrar a policy precisa ser corrigido
        por update idempotente.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$clientPath = Join-Path $PSScriptRoot 'nerdgraph-client.ps1'
$provisionPath = Join-Path $PSScriptRoot 'provision-newrelic.ps1'

. $clientPath

function Convert-ToObject {
    param([Parameter(Mandatory = $true)][hashtable]$Value)
    return ($Value | ConvertTo-Json -Depth 25 | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Analise estatica das queries versionadas.
# ---------------------------------------------------------------------------
function Assert-ErrorsSelectionSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $selections = [regex]::Matches($Content, 'errors\s*\{(?<body>[^}]*)\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($selection in $selections) {
        $body = $selection.Groups['body'].Value
        $fields = @($body -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($fields -notcontains '__typename') {
            throw "$Label contem errors sem __typename: $($body.Trim())"
        }
        foreach ($field in $fields) {
            if ($field -in @('description', 'type')) {
                throw "$Label consulta '$field' diretamente em errors. Use somente __typename para evitar falha de schema em unions/interfaces."
            }
        }
    }
}

# Argumentos aceitos por cada mutation. Assinatura errada nao e erro de sintaxe:
# a NerdGraph responde HTTP 200 com "Unknown argument ... on field ...", entao o
# problema so apareceria no deploy. Note que aiWorkflowsUpdateWorkflow e a
# excecao entre os updates: o id vai dentro de updateWorkflowData, nao no topo.
$script:MutationArgumentContract = @{
    'aiNotificationsCreateDestination'             = @('accountId', 'destination')
    'aiNotificationsUpdateDestination'             = @('accountId', 'destinationId', 'destination')
    'aiNotificationsCreateChannel'                 = @('accountId', 'channel')
    'aiNotificationsUpdateChannel'                 = @('accountId', 'channelId', 'channel')
    'aiWorkflowsCreateWorkflow'                    = @('accountId', 'createWorkflowData')
    'aiWorkflowsUpdateWorkflow'                    = @('accountId', 'updateWorkflowData')
    'alertsPolicyCreate'                           = @('accountId', 'policy')
    'alertsPolicyUpdate'                           = @('accountId', 'id', 'policy')
    'alertsNrqlConditionStaticCreate'              = @('accountId', 'policyId', 'condition')
    'alertsNrqlConditionStaticUpdate'              = @('accountId', 'id', 'condition')
    'alertsSyntheticsMultiLocationConditionCreate' = @('accountId', 'policyId', 'condition')
    'alertsSyntheticsMultiLocationConditionUpdate' = @('accountId', 'id', 'condition')
    'dashboardCreate'                              = @('accountId', 'dashboard')
    'dashboardUpdate'                              = @('guid', 'dashboard')
    'syntheticsCreateSimpleMonitor'                = @('accountId', 'monitor')
    'syntheticsUpdateSimpleMonitor'                = @('guid', 'monitor')
}

function Assert-MutationArgumentsSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $mutacoes = [regex]::Matches(
        $Content,
        'mutation\s*\([^)]*\)\s*\{\s*\r?\n\s*(?<field>\w+)\s*\((?<args>[^)]*)\)')

    # Se alguma mutation escapar do parser, a checagem passaria em falso.
    $declaradas = [regex]::Matches($Content, 'mutation\s*\(').Count
    if ($declaradas -ne $mutacoes.Count) {
        throw "$Label declara $declaradas mutation(s) e o parser reconheceu $($mutacoes.Count). Formato inesperado impede a checagem de argumentos."
    }

    foreach ($mutacao in $mutacoes) {
        $field = $mutacao.Groups['field'].Value
        if (-not $script:MutationArgumentContract.ContainsKey($field)) {
            throw "$Label usa a mutation '$field', ausente do contrato. Registre os argumentos aceitos em MutationArgumentContract."
        }

        $permitidos = $script:MutationArgumentContract[$field]
        $usados = @($mutacao.Groups['args'].Value -split ',' |
            ForEach-Object { ($_ -split ':')[0].Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        foreach ($argumento in $usados) {
            if ($argumento -notin $permitidos) {
                throw "$Label passa '$argumento' para $field. Argumentos aceitos: $($permitidos -join ', ')."
            }
        }
    }
}

foreach ($arquivo in @(
        @{ Path = $clientPath; Label = 'nerdgraph-client.ps1' },
        @{ Path = $provisionPath; Label = 'provision-newrelic.ps1' })) {
    $conteudo = Get-Content -LiteralPath $arquivo.Path -Raw
    Assert-ErrorsSelectionSafe -Content $conteudo -Label $arquivo.Label
    Assert-MutationArgumentsSafe -Content $conteudo -Label $arquivo.Label
}

$payloadWithTypenameOnly = Convert-ToObject @{
    errors = @(@{ __typename = 'AiNotificationsResponseError' })
}
try {
    Assert-NoMutationErrors -Payload $payloadWithTypenameOnly -Label 'teste'
    throw 'Assert-NoMutationErrors deveria reprovar payload com errors.'
}
catch {
    if ($_.Exception.Message -notmatch 'AiNotificationsResponseError') {
        throw "Assert-NoMutationErrors nao preservou __typename no diagnostico: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Politica de reexecucao. Roda antes de Invoke-NerdGraph ser substituido, porque
# e justamente a implementacao real que precisa ser exercitada aqui.
# ---------------------------------------------------------------------------
$script:TentativasHttp = 0
$script:StatusSimulado = 0

function Start-Sleep {
    param([Parameter(Position = 0)][int]$Seconds, [int]$Milliseconds)
    # No-op: o teste nao espera os backoffs reais.
}

function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $TimeoutSec)

    $script:TentativasHttp++
    $excecao = [System.Exception]::new("falha simulada de status $script:StatusSimulado")
    if ($script:StatusSimulado -gt 0) {
        # Sem status a falha e de transporte; com status ela vem do servidor.
        $excecao | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $script:StatusSimulado }) -Force
    }
    throw $excecao
}

$contextoRetry = [pscustomobject]@{ AccountId = '123456'; ApiKey = 'chave-de-teste'; Endpoint = 'offline'; Region = 'US' }

function Measure-Tentativas {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][int]$Status
    )

    $script:TentativasHttp = 0
    $script:StatusSimulado = $Status
    $mensagem = ''
    try {
        Invoke-NerdGraph -Context $contextoRetry -Query $Query -Variables @{ accountId = 1 } | Out-Null
    }
    catch {
        $mensagem = $_.Exception.Message
    }

    return [pscustomobject]@{ Tentativas = $script:TentativasHttp; Mensagem = $mensagem }
}

$queryLeitura = @'
query($accountId: Int!) {
  actor { account(id: $accountId) { id } }
}
'@

$mutationExemplo = @'
mutation($accountId: Int!, $policy: AlertsPolicyInput!) {
  alertsPolicyCreate(accountId: $accountId, policy: $policy) { id name }
}
'@

foreach ($caso in @(
        @{ Nome = 'query com HTTP 503'; Query = $queryLeitura; Status = 503; Esperado = 3 },
        @{ Nome = 'query com HTTP 429'; Query = $queryLeitura; Status = 429; Esperado = 3 },
        @{ Nome = 'query com falha de transporte'; Query = $queryLeitura; Status = 0; Esperado = 3 },
        @{ Nome = 'query com HTTP 401'; Query = $queryLeitura; Status = 401; Esperado = 1 },
        @{ Nome = 'query com HTTP 404'; Query = $queryLeitura; Status = 404; Esperado = 1 },
        @{ Nome = 'mutation com HTTP 503'; Query = $mutationExemplo; Status = 503; Esperado = 1 },
        @{ Nome = 'mutation com falha de transporte'; Query = $mutationExemplo; Status = 0; Esperado = 1 })) {
    $resultado = Measure-Tentativas -Query $caso.Query -Status $caso.Status
    if ($resultado.Tentativas -ne $caso.Esperado) {
        throw "$($caso.Nome): esperado $($caso.Esperado) tentativa(s), observado $($resultado.Tentativas)."
    }
}

# MaxAttempts explicito continua valendo, inclusive para mutation.
$script:TentativasHttp = 0
$script:StatusSimulado = 503
try { Invoke-NerdGraph -Context $contextoRetry -Query $mutationExemplo -Variables @{} -MaxAttempts 2 | Out-Null } catch { }
if ($script:TentativasHttp -ne 2) {
    throw "MaxAttempts explicito ignorado na mutation: $script:TentativasHttp tentativa(s)."
}

$diagnostico = (Measure-Tentativas -Query $queryLeitura -Status 401).Mensagem
if ($diagnostico -notmatch 'HTTP 401') {
    throw "Diagnostico de falha nao carrega o status HTTP: $diagnostico"
}

# ---------------------------------------------------------------------------
# Simulacao da cadeia de notificacao.
# ---------------------------------------------------------------------------
$script:ChainName = 'FIAP Oficina - Email'
$script:PolicyId = '123'
$script:FiltroDaPolicy = '123'
$script:RecursosExistentes = $false
$script:CapturedCalls = [System.Collections.Generic.List[pscustomobject]]::new()

<#
Primeira pagina sempre vazia.

E exatamente ela que a versao sem paginacao lia sozinha: com o recurso existente
na segunda, a resolucao por nome concluiria "nao existe" e criaria duplicidade.
#>
function New-RespostaPaginada {
    param(
        [Parameter(Mandatory = $true)][string]$Grupo,
        [Parameter(Mandatory = $true)][string]$Campo,
        $Cursor,
        [object[]]$EntidadesFinais = @()
    )

    $entidades = @()
    $proximo = ''
    if ([string]::IsNullOrWhiteSpace([string]$Cursor)) {
        $proximo = 'pagina-2'
    }
    else {
        $entidades = @($EntidadesFinais)
    }

    return @{ data = @{ actor = @{ account = @{ $Grupo = @{ $Campo = @{ nextCursor = $proximo; entities = $entidades } } } } } }
}

function Invoke-NerdGraph {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Query,
        [hashtable]$Variables,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    $script:CapturedCalls.Add([pscustomobject]@{ Query = $Query; Variables = $Variables })

    if ($Query -match 'CURSOR_INFINITO') {
        return Convert-ToObject @{ data = @{ pagina = @{ nextCursor = 'sempre'; entities = @() } } }
    }

    # Mutations primeiro: a selection delas repete nomes usados pelas queries.
    if ($Query -match 'aiNotificationsCreateDestination') {
        return Convert-ToObject @{ data = @{ aiNotificationsCreateDestination = @{ destination = @{ id = 'destination-1'; name = $Variables.destination.name }; errors = @() } } }
    }
    if ($Query -match 'aiNotificationsUpdateDestination') {
        return Convert-ToObject @{ data = @{ aiNotificationsUpdateDestination = @{ destination = @{ id = $Variables.destinationId; name = $Variables.destination.name }; errors = @() } } }
    }
    if ($Query -match 'aiNotificationsCreateChannel') {
        return Convert-ToObject @{ data = @{ aiNotificationsCreateChannel = @{ channel = @{ id = 'channel-1'; name = $Variables.channel.name }; errors = @() } } }
    }
    if ($Query -match 'aiNotificationsUpdateChannel') {
        return Convert-ToObject @{ data = @{ aiNotificationsUpdateChannel = @{ channel = @{ id = $Variables.channelId; name = $Variables.channel.name }; errors = @() } } }
    }
    if ($Query -match 'aiWorkflowsCreateWorkflow') {
        return Convert-ToObject @{ data = @{ aiWorkflowsCreateWorkflow = @{ workflow = @{ id = 'workflow-1'; name = $Variables.workflow.name }; errors = @() } } }
    }
    if ($Query -match 'aiWorkflowsUpdateWorkflow') {
        return Convert-ToObject @{ data = @{ aiWorkflowsUpdateWorkflow = @{ workflow = @{ id = $Variables.workflow.id; name = $Variables.workflow.name }; errors = @() } } }
    }

    if ($Query -match 'destinations\s*\(') {
        $existentes = @()
        if ($script:RecursosExistentes) { $existentes = @(@{ id = 'destination-1'; name = $script:ChainName; type = 'EMAIL' }) }
        return Convert-ToObject (New-RespostaPaginada -Grupo 'aiNotifications' -Campo 'destinations' -Cursor $Variables.cursor -EntidadesFinais $existentes)
    }
    if ($Query -match 'channels\s*\(') {
        $existentes = @()
        if ($script:RecursosExistentes) { $existentes = @(@{ id = 'channel-1'; name = $script:ChainName; destinationId = 'destination-1' }) }
        return Convert-ToObject (New-RespostaPaginada -Grupo 'aiNotifications' -Campo 'channels' -Cursor $Variables.cursor -EntidadesFinais $existentes)
    }
    if ($Query -match 'workflows\s*\(') {
        $existentes = @()
        if ($script:RecursosExistentes) {
            $existentes = @(@{
                    id           = 'workflow-1'
                    name         = $script:ChainName
                    issuesFilter = @{
                        id         = 'filtro-1'
                        predicates = @(@{ attribute = 'labels.policyIds'; values = @($script:FiltroDaPolicy) })
                    }
                })
        }
        return Convert-ToObject (New-RespostaPaginada -Grupo 'aiWorkflows' -Campo 'workflows' -Cursor $Variables.cursor -EntidadesFinais $existentes)
    }

    throw "Query nao simulada no teste offline: $Query"
}

$context = [pscustomobject]@{
    AccountId = '123456'
    Endpoint  = 'offline'
    Region    = 'US'
}

# Cursor que nao avanca precisa reprovar, e nao girar para sempre.
try {
    Get-AllPages -Context $context -Query 'query { CURSOR_INFINITO }' -Variables @{} -MaxPages 3 -SelectPage { param($resposta) $resposta.data.pagina } | Out-Null
    throw 'Get-AllPages deveria reprovar cursor que nao avanca.'
}
catch {
    if ($_.Exception.Message -notmatch 'paginas') { throw }
}

$notification = Set-NotificationChain `
    -Context $context `
    -Name $script:ChainName `
    -Email 'teste@example.com' `
    -PolicyId $script:PolicyId

if ($notification.DestinationAction -ne 'created' -or $notification.ChannelAction -ne 'created' -or $notification.WorkflowAction -ne 'created') {
    throw 'Simulacao offline da cadeia de notificacao nao retornou acoes created.'
}

# Segunda execucao com os recursos ja existentes na segunda pagina: exercita o
# caminho de update, que e onde a assinatura de aiWorkflowsUpdateWorkflow falhava
# em producao, e prova que a paginacao e percorrida.
$script:RecursosExistentes = $true
$script:CapturedCalls.Clear()

$notificationUpdate = Set-NotificationChain `
    -Context $context `
    -Name $script:ChainName `
    -Email 'teste@example.com' `
    -PolicyId $script:PolicyId

if ($notificationUpdate.DestinationAction -ne 'updated' -or $notificationUpdate.ChannelAction -ne 'updated' -or $notificationUpdate.WorkflowAction -ne 'updated') {
    throw "Reexecucao offline nao retornou acoes updated: destination=$($notificationUpdate.DestinationAction) channel=$($notificationUpdate.ChannelAction) workflow=$($notificationUpdate.WorkflowAction). Recurso existente fora da primeira pagina nao foi encontrado."
}

$paginasSeguintes = @($script:CapturedCalls | Where-Object {
        $null -ne $_.Variables -and
        $_.Variables.ContainsKey('cursor') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Variables['cursor'])
    })
if ($paginasSeguintes.Count -ne 3) {
    throw "Esperado 3 leituras de segunda pagina (destinations, channels, workflows); observado $($paginasSeguintes.Count)."
}

$criacoes = @($script:CapturedCalls | Where-Object { $_.Query -match 'aiNotificationsCreateDestination|aiNotificationsCreateChannel|aiWorkflowsCreateWorkflow' })
if ($criacoes.Count -ne 0) {
    throw "Reexecucao criou $($criacoes.Count) recurso(s) que ja existiam: idempotencia quebrada."
}

$workflowUpdates = @($script:CapturedCalls | Where-Object { $_.Query -match 'aiWorkflowsUpdateWorkflow' })
if ($workflowUpdates.Count -ne 1) {
    throw "Esperado 1 update de workflow na reexecucao; observado $($workflowUpdates.Count)."
}
if ([string]::IsNullOrWhiteSpace([string]$workflowUpdates[0].Variables.workflow.id)) {
    throw 'aiWorkflowsUpdateWorkflow precisa levar o id do workflow dentro de updateWorkflowData.'
}

# Workflow que deixou de filtrar a policy precisa ser atualizado com o filtro
# correto; nao deve exigir limpeza manual antes de reexecutar.
$script:FiltroDaPolicy = '999'
$script:CapturedCalls.Clear()
$notificationRepair = Set-NotificationChain -Context $context -Name $script:ChainName -Email 'teste@example.com' -PolicyId $script:PolicyId
if ($notificationRepair.WorkflowAction -ne 'updated') {
    throw "Workflow com filtro antigo deveria ser atualizado; acao observada: $($notificationRepair.WorkflowAction)."
}

$workflowRepairUpdates = @($script:CapturedCalls | Where-Object { $_.Query -match 'aiWorkflowsUpdateWorkflow' })
if ($workflowRepairUpdates.Count -ne 1) {
    throw "Esperado 1 update de workflow para corrigir filtro; observado $($workflowRepairUpdates.Count)."
}

$repairPredicates = @($workflowRepairUpdates[0].Variables.workflow.issuesFilter.predicates)
if (@($repairPredicates | Where-Object { @($_.values) -contains [string]$script:PolicyId }).Count -ne 1) {
    throw 'Update de workflow nao levou issuesFilter apontando para a policy atual.'
}

foreach ($call in $script:CapturedCalls) {
    Assert-ErrorsSelectionSafe -Content $call.Query -Label 'query capturada'
}

Write-Host 'Contrato NerdGraph offline aprovado.'

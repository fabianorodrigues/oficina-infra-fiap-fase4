<#
.SYNOPSIS
    Valida que a versao do K3s tem uma unica fonte e o mesmo valor literal em
    todos os lugares onde aparece.

.DESCRIPTION
    A asserção de formato em terraform/platform/validations.tf garante apenas
    que o valor parece uma versao de K3s. Arquivos coerentes em formato e
    divergentes em valor passariam por ela. Esta validacao compara o valor
    literal entre config/official.yml, a variavel TF_VAR_k3s_version exportada
    para o Terraform e o README do repositorio.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "config/official.yml",
    [string]$DocsPath = "README.md",
    [string]$TerraformVersion = $env:TF_VAR_k3s_version
)

$ErrorActionPreference = "Stop"
$errors = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:errors.Add($Message)
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Arquivo de configuracao oficial nao encontrado: $ConfigPath"
}
if (-not (Test-Path -LiteralPath $DocsPath)) {
    throw "Documentacao nao encontrada: $DocsPath"
}

$configRaw = Get-Content -LiteralPath $ConfigPath -Raw
$docsRaw = Get-Content -LiteralPath $DocsPath -Raw

# Leitura por expressao regular e deliberada: o modulo powershell-yaml nao e uma
# dependencia deste repositorio e o bloco kubernetes tem formato fixo.
function Get-YamlScalar([string]$Content, [string]$Key) {
    $match = [regex]::Match($Content, "(?m)^\s{2}$([regex]::Escape($Key)):\s*(\S+)\s*$")
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

$configVersion = Get-YamlScalar -Content $configRaw -Key "k3sVersion"
$installerCommit = Get-YamlScalar -Content $configRaw -Key "installerCommit"
$installerUrl = Get-YamlScalar -Content $configRaw -Key "installerUrl"
$installerSha = Get-YamlScalar -Content $configRaw -Key "installerSha256"
$binaryUrl = Get-YamlScalar -Content $configRaw -Key "binaryUrl"
$binarySha = Get-YamlScalar -Content $configRaw -Key "binarySha256"

if ([string]::IsNullOrWhiteSpace($configVersion)) {
    throw "kubernetes.k3sVersion ausente em $ConfigPath."
}

$versionPattern = '^v\d+\.\d+\.\d+\+k3s\d+$'
if ($configVersion -notmatch $versionPattern) {
    Add-Failure "kubernetes.k3sVersion fora do formato vX.Y.Z+k3sN: $configVersion"
}

if ([string]::IsNullOrWhiteSpace($TerraformVersion)) {
    Add-Failure "TF_VAR_k3s_version nao definida. O workflow deve exporta-la a partir de $ConfigPath."
}
elseif ($TerraformVersion -cne $configVersion) {
    Add-Failure "TF_VAR_k3s_version ('$TerraformVersion') diverge de kubernetes.k3sVersion ('$configVersion')."
}

# A documentacao precisa citar exatamente a mesma versao, sem aproximacao.
if ($docsRaw -notmatch [regex]::Escape($configVersion)) {
    Add-Failure "$DocsPath nao cita a versao '$configVersion'."
}

$docVersions = [regex]::Matches($docsRaw, 'v\d+\.\d+\.\d+\+k3s\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique
foreach ($docVersion in $docVersions) {
    if ($docVersion -cne $configVersion) {
        Add-Failure "$DocsPath cita a versao divergente '$docVersion'."
    }
}

if ([string]::IsNullOrWhiteSpace($installerCommit) -or $installerCommit -notmatch '^[0-9a-f]{40}$') {
    Add-Failure "kubernetes.installerCommit deve ser um commit SHA de 40 caracteres."
}
else {
    $expectedUrl = "https://raw.githubusercontent.com/k3s-io/k3s/$installerCommit/install.sh"
    if ($installerUrl -cne $expectedUrl) {
        Add-Failure "kubernetes.installerUrl deve apontar para o commit fixo declarado em installerCommit."
    }
}

foreach ($pair in @(@{ Name = "installerSha256"; Value = $installerSha }, @{ Name = "binarySha256"; Value = $binarySha })) {
    if ([string]::IsNullOrWhiteSpace($pair.Value) -or $pair.Value -notmatch '^[0-9a-f]{64}$') {
        Add-Failure "kubernetes.$($pair.Name) deve ser um digest SHA-256 de 64 caracteres hexadecimais."
    }
}

# O caractere '+' precisa vir percent-encoded na URL de download do binario.
$encodedVersion = $configVersion -replace '\+', '%2B'
$expectedBinaryUrl = "https://github.com/k3s-io/k3s/releases/download/$encodedVersion/k3s"
if ($binaryUrl -cne $expectedBinaryUrl) {
    Add-Failure "kubernetes.binaryUrl deve ser '$expectedBinaryUrl'."
}

# Nenhum outro arquivo pode fixar a versao: fonte unica significa uma ocorrencia
# de valor, e nao apenas um formato coerente.
$scanRoots = @("terraform", ".github", "scripts")
foreach ($root in $scanRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    # A comparacao de extensao e exata de proposito: o wildcard '*.tf' do
    # parametro -Include tambem casaria com '.tfvars' pela regra de nome curto
    # do Windows, e o inventario ficaria maior do que o pretendido.
    $extensions = @('.tf', '.tftpl', '.yml', '.yaml', '.ps1')
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension -and $_.FullName -notmatch '\\\.terraform\\' } |
        ForEach-Object {
            $content = Get-Content -LiteralPath $_.FullName -Raw
            if ($content -match 'v\d+\.\d+\.\d+\+k3s\d+') {
                Add-Failure "Versao do K3s fixada fora de $ConfigPath em $($_.FullName). Use TF_VAR_k3s_version."
            }
        }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Versao do K3s consistente: $configVersion"

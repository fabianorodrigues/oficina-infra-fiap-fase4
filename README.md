# oficina-infra-fiap-fase4

Infraestrutura compartilhada da FIAP Fase 4 para a plataforma Oficina.

## Recursos implementados

- EKS `oficina` com Managed Node Group `oficina`.
- Namespace Kubernetes `oficina`.
- Repositorios ECR `oficina-cadastro`, `oficina-estoque` e `oficina-ordens-servico`.
- Filas FIFO SQS e DLQs FIFO para comandos de estoque e eventos de ordens.
- IAM de menor privilegio para workloads.
- EKS Pod Identity como modo principal e IRSA como fallback configuravel.
- AWS Load Balancer Controller instalado sem criar Ingress ou ALB nesta etapa.
- Secrets Store CSI Driver e AWS Secrets and Configuration Provider.
- Container Secrets Manager `/oficina/observability/new-relic` sem versao de secret.
- Observabilidade New Relic condicional, iniciando desabilitada.
- Publicacao de outputs nao sensiveis no SSM Parameter Store.

## Dependencias

A plataforma depende de uma Infra DB ja provisionada, com backend Terraform remoto existente, parametros SSM publicados em `/oficina/infra/...` e secrets SQL existentes no Secrets Manager. Esta stack nao cria VPC, subnets, RDS, usuarios SQL nem bootstrap de banco.

## Configuracao

`config/official.yml` contem os nomes oficiais e parametros nao sensiveis da plataforma.

`config/resource-contract.yml` define os caminhos SSM de entrada e saida e os nomes dos secrets compartilhados. O arquivo nao contem valores gerados pela AWS.

O endpoint publico do EKS fica habilitado porque GitHub-hosted runners usam IPs dinamicos. Esse endpoint e apenas administrativo para Kubernetes; as aplicacoes nao sao expostas diretamente por ele. O acesso continua protegido por IAM e autorizacao Kubernetes. Em uso corporativo, a recomendacao e runner privado ou restricao de CIDR.

## GitHub

Secrets futuros do repositorio:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

Variables futuras do repositorio:

- `AWS_REGION`
- `TF_STATE_BUCKET`
- `TF_STATE_REGION`
- `TF_STATE_KEY_PLATFORM=oficina/platform/terraform.tfstate`

O deploy nao usa GitHub protected deployment feature.

## Execucao futura

Depois de PR aprovado e mergeado na `main`:

1. GitHub Actions
2. Platform Deploy
3. Run workflow
4. Branch `main`
5. confirmation `APPLY`

## Sem AWS Academy

A implementacao pode ser concluida sem acesso ao AWS Academy. Plan e apply reais ficam adiados para a pipeline manual. Falhas de autenticacao AWS nao devem reprovar a implementacao estatica.

## Limpeza

Nao existe pipeline de destroy neste repositorio. A limpeza integral do laboratorio ocorrera pelo reset do AWS Academy.

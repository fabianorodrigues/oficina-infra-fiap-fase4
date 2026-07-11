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

## Ingress compartilhado e ALB interno

Um unico Ingress compartilhado (`deploy/k8s/ingress/`) materializa um unico ALB
interno `oficina` para os tres microservicos. Fluxo: `API Gateway futuro -> VPC Link
futuro -> ALB interno -> Ingress -> Services ClusterIP -> Pods`.

- ALB `internal`, `target-type: ip`, Listener HTTP 80, sem endpoint publico e sem
  autenticacao no ALB (a autenticacao vira no API Gateway).
- Rotas publicas versionadas em `config/ingress-routes.json`; `/ready`,
  `/api/internal/*` e `/api/dev/*` nunca sao expostos.
- Health check dos Target Groups em `/health` (`traffic-port`, `200-399`).
- `config/resource-contract.yml` inclui os outputs `albArn`, `albListenerArn` e
  `albDnsName` em `/oficina/infra/alb/*`, publicados no SSM pelo `Ingress Deploy`.
- CI: `Ingress CI` (PR, sem AWS). Deploy: `Ingress Deploy` (`workflow_dispatch`,
  somente `main`, `confirmation = DEPLOY`).

Detalhes em `deploy/k8s/ingress/README.md`. A `IngressClass alb` pertence a Platform
(criada pelo chart do AWS Load Balancer Controller); este repositorio apenas a
referencia.

O Ingress inclui tres regras de health por header (`x-oficina-health-target`) para
`cadastro`, `estoque` e `ordens`, consumidas pelo API Gateway (Entrypoint).

## API Gateway (Entrypoint)

A stack `terraform/entrypoint/` cria a entrada publica oficial: `API Gateway HTTP
API -> Lambda Authorizer -> VPC Link -> ALB interno -> Services`. E o unico ponto
publico; o ALB continua interno.

- HTTP API v2 `oficina-api`, stage `$default`, endpoint `execute-api` padrao.
- VPC Link `oficina` em duas subnets privadas com SG dedicado; integracao privada
  pelo **Listener ARN** do ALB (`HTTP_PROXY`, `VPC_LINK`, payload `1.0`).
- Login `POST /api/auth/cpf` integra direto com `oficina-auth-cpf:live`
  (`AWS_PROXY`, payload `2.0`).
- Authorizer REQUEST `oficina-authorizer:live` (payload `2.0`, simple responses,
  cache TTL `0`) nas rotas protegidas.
- Headers de identidade `x-oficina-user-*` sobrescritos pelo contexto do Authorizer;
  removidos nas rotas publicas/health.
- Health por header interno; `/ready`, `/api/internal/*` e `/api/dev/*` nunca sao
  expostos; sem `$default` route e sem catch-all.
- Backend Terraform independente `oficina/entrypoint/terraform.tfstate`; sem
  `terraform_remote_state` (comunicacao por SSM). Outputs em `/oficina/infra/api/*`.
- CI: `Entrypoint CI` (PR, sem AWS). Deploy: `Entrypoint Deploy`
  (`workflow_dispatch`, somente `main`, `confirmation = APPLY`).

Contrato versionado em `config/entrypoint.json`. Detalhes em
`terraform/entrypoint/README.md`.

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
- `TF_STATE_KEY_ENTRYPOINT=oficina/entrypoint/terraform.tfstate`

Nenhuma Repository Variable e criada para VPC, subnets, ALB, Listener, Lambda ARNs,
API URL/ID ou VPC Link ID: esses valores vem de `config/entrypoint.json`, do SSM
Parameter Store e dos outputs do Terraform.

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

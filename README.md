# Oficina

DocumentaÃ§Ã£o de entrada da soluÃ§Ã£o Oficina (FIAP Fase 4): oficina de veÃ­culos com
cadastro de clientes, controle de estoque e ordens de serviÃ§o, expostos por um
Ãºnico ponto de entrada pÃºblico e orquestrados sobre EKS.

Este repositÃ³rio (`oficina-infra-fiap-fase4`) provisiona a plataforma
compartilhada (EKS, ECR, SQS, IAM, addons, observabilidade) e o ponto de
entrada pÃºblico (API Gateway, VPC Link, ALB interno, Ingress). Ã‰ o ponto
inicial de leitura da soluÃ§Ã£o.

## SumÃ¡rio

- [VisÃ£o geral](#visÃ£o-geral)
- [Arquitetura](#arquitetura)
- [RepositÃ³rios](#repositÃ³rios)
- [Responsabilidades](#responsabilidades)
- [Fluxos principais](#fluxos-principais)
- [PrÃ©-requisitos](#prÃ©-requisitos)
- [ConfiguraÃ§Ã£o](#configuraÃ§Ã£o)
- [Ordem de provisionamento](#ordem-de-provisionamento)
- [ValidaÃ§Ã£o](#validaÃ§Ã£o)
- [Observabilidade](#observabilidade)
- [Testes E2E](#testes-e2e)
- [SoluÃ§Ã£o de problemas](#soluÃ§Ã£o-de-problemas)

## VisÃ£o geral

A soluÃ§Ã£o Ã© composta por trÃªs microsserviÃ§os .NET independentes (Cadastro,
Estoque, Ordens de ServiÃ§o), autenticaÃ§Ã£o por Lambda (CPF/senha + JWT),
mensageria assÃ­ncrona via SQS FIFO com Inbox/Outbox e uma Saga orquestrando o
fluxo de ordem de serviÃ§o atÃ© a entrega, incluindo pagamento. O pagamento usa
um gateway mock determinÃ­stico; a integraÃ§Ã£o externa real (Mercado Pago) Ã© uma
pendÃªncia de contrato, nÃ£o uma dependÃªncia de execuÃ§Ã£o.

Cada microsserviÃ§o mantÃ©m banco lÃ³gico prÃ³prio no mesmo RDS SQL Server,
pipeline prÃ³pria e deploy independente. NÃ£o hÃ¡ uso de banco NoSQL nesta
soluÃ§Ã£o.

## Arquitetura

```mermaid
flowchart TB
    Client[Cliente] -->|HTTPS| APIGW[API Gateway HTTP API v2\noficina-api]
    APIGW -->|login| AuthCpf[Lambda oficina-auth-cpf]
    APIGW -->|REQUEST authorizer| Authorizer[Lambda oficina-authorizer]
    APIGW -->|VPC Link| ALB[ALB interno\noficina]
    ALB --> Ingress[Ingress compartilhado]
    Ingress --> Cadastro[oficina-cadastro]
    Ingress --> Estoque[oficina-estoque]
    Ingress --> Ordens[oficina-ordens-servico]
    AuthCpf -.-> CadastroDb[(OficinaCadastroDb)]
    Cadastro --> CadastroDb
    Estoque --> EstoqueDb[(OficinaEstoqueDb)]
    Ordens --> OrdensDb[(OficinaOrdensServicoDb)]
    Estoque <-->|SQS FIFO| Ordens
    Ordens -->|pagamento mock| Pagamento[IPaymentGateway / Mock]
```

Camadas de infraestrutura, cada uma com Terraform independente:

| Camada | RepositÃ³rio | Terraform state |
| ------ | ----------- | ---------------- |
| Rede e banco (VPC, RDS SQL Server) | `oficina-infra-db-fiap-fase4` | `oficina/infra-db/terraform.tfstate` |
| Plataforma (EKS, ECR, SQS, addons, observabilidade) | `oficina-infra-fiap-fase4` | `oficina/platform/terraform.tfstate` |
| Ponto de entrada (API Gateway, VPC Link, Ingress/ALB) | `oficina-infra-fiap-fase4` | `oficina/entrypoint/terraform.tfstate` |
| AutenticaÃ§Ã£o (Lambdas) | `oficina-auth-lambda-fiap-fase4` | `oficina/auth/terraform.tfstate` |

Recursos sÃ£o descobertos por nome ou tag entre states sempre que seguro (ex.:
ALB por nome, ECR por nome). SSM Parameter Store Ã© usado apenas para valores
que precisam atravessar workflows/execuÃ§Ãµes distintas (ex.: IDs de rede
publicados pela Infra DB). NÃ£o hÃ¡ uso de `terraform_remote_state` em nenhuma
stack.

## RepositÃ³rios

| RepositÃ³rio | Responsabilidade |
| ----------- | ----------------- |
| `oficina-infra-db-fiap-fase4` | VPC, subnets, RDS SQL Server, bootstrap dos bancos e usuÃ¡rios |
| `oficina-infra-fiap-fase4` | EKS, ECR, SQS, addons, observabilidade, entrypoint pÃºblico (este repositÃ³rio) |
| `oficina-auth-lambda-fiap-fase4` | Lambdas de autenticaÃ§Ã£o CPF/senha e Authorizer JWT |
| `oficina-cadastro-fiap-fase4` | DomÃ­nio de clientes, veÃ­culos e catÃ¡logo |
| `oficina-estoque-fiap-fase4` | DomÃ­nio de estoque, reservas e movimentaÃ§Ãµes |
| `oficina-ordens-servico-fiap-fase4` | DomÃ­nio de ordens de serviÃ§o, orÃ§amento, Saga e pagamento |

## Responsabilidades

- **Cadastro, Estoque e Ordens de ServiÃ§o** sÃ£o independentes: CI prÃ³pria,
  deploy prÃ³prio, banco lÃ³gico prÃ³prio, sem acoplamento de cÃ³digo entre si.
- **Auth** emite e valida JWT (HS256); nÃ£o hospeda regra de negÃ³cio de domÃ­nio.
- **Infra DB** possui rede e dados; nÃ£o conhece Kubernetes nem os
  microsserviÃ§os.
- **Platform** possui o cluster, os addons e a observabilidade; nÃ£o conhece
  cÃ³digo de aplicaÃ§Ã£o nem regras de negÃ³cio.
- **Entrypoint** (tambÃ©m neste repositÃ³rio) possui o ponto de entrada pÃºblico;
  nÃ£o processa regra de negÃ³cio, apenas roteia e autentica.

## Fluxos principais

### AutenticaÃ§Ã£o

```mermaid
sequenceDiagram
    participant C as Cliente
    participant GW as API Gateway
    participant Auth as Lambda oficina-auth-cpf
    participant DB as OficinaCadastroDb
    participant Authz as Lambda oficina-authorizer

    C->>GW: POST /api/auth/cpf
    GW->>Auth: invoke (AWS_PROXY, live)
    Auth->>DB: consulta Funcionarios (somente leitura)
    Auth-->>C: JWT (HS256, exp 60min)
    C->>GW: requisiÃ§Ã£o com Bearer JWT
    GW->>Authz: REQUEST authorizer (live)
    Authz-->>GW: policy + claims
    GW->>GW: injeta headers x-oficina-user-*
```

### Mensageria (Estoque â†” Ordens)

```mermaid
sequenceDiagram
    participant Ordens
    participant SQSCmd as SQS oficina-estoque-comandos.fifo
    participant Estoque
    participant SQSEvt as SQS oficina-ordens-eventos.fifo

    Ordens->>SQSCmd: comando (Outbox, mesma transaÃ§Ã£o)
    SQSCmd->>Estoque: consumo (Inbox, idempotente)
    Estoque->>Estoque: reserva/baixa de estoque
    Estoque->>SQSEvt: evento de resultado (Outbox)
    SQSEvt->>Ordens: consumo (Inbox, idempotente)
    Ordens->>Ordens: avanÃ§a a Saga
```

DLQs FIFO dedicadas para as duas filas; publicaÃ§Ã£o em SQS nunca ocorre dentro
da transaÃ§Ã£o de banco (Outbox garante entrega apÃ³s commit).

### Saga da ordem de serviÃ§o

```mermaid
stateDiagram-v2
    [*] --> AguardandoAprovacao
    AguardandoAprovacao --> ReservaSolicitada: aprovar orÃ§amento
    ReservaSolicitada --> ReservaRecusada: saldo insuficiente
    ReservaSolicitada --> PagamentoSolicitado: reserva confirmada
    PagamentoSolicitado --> Recusado: pagamento recusado
    PagamentoSolicitado --> EmExecucao: pagamento aprovado
    EmExecucao --> Concluida: finalizar + entregar
    ReservaRecusada --> [*]
    Recusado --> Compensada: compensaÃ§Ã£o
    Compensada --> [*]
    Concluida --> [*]
```

Pagamento usa `IPaymentGateway` com implementaÃ§Ã£o mock determinÃ­stica e
idempotente (`MockPaymentGateway`), sem chamada HTTP externa e sem dependÃªncia
de webhook. A integraÃ§Ã£o real (Mercado Pago) Ã© uma pendÃªncia de contrato.

## PrÃ©-requisitos

- Conta AWS com credenciais temporÃ¡rias configuradas nos Repository Secrets
  dos seis repositÃ³rios antes de executar qualquer workflow de provisionamento.
- `AWS_REGION` configurada como Repository Variable.
- Terraform 1.10+, .NET 10 SDK, Docker, kubectl e Helm para validaÃ§Ã£o local.

## ConfiguraÃ§Ã£o

- `config/official.yml`: nomes estÃ¡veis e nÃ£o sensÃ­veis da plataforma
  (cluster, namespace, ECR, addons).
- `config/resource-contract.yml`: caminhos SSM de entrada/saÃ­da e nomes dos
  secrets compartilhados, consumidos pelo Terraform.
- `config/solution.yml`: contrato humano da soluÃ§Ã£o (nomes de serviÃ§os,
  bancos, filas, entrypoint, sequÃªncia de provisionamento) â€” referÃªncia para
  documentaÃ§Ã£o e validaÃ§Ãµes; nenhuma aplicaÃ§Ã£o o lÃª em runtime.
- `config/entrypoint.json` e `config/ingress-routes.json`: contratos versionados
  do API Gateway e do Ingress compartilhado.

Nenhum destes arquivos contÃ©m senha, ARN gerado, URL real de fila/API ou
Account ID.

## Ordem de provisionamento

```mermaid
flowchart LR
    A[Database Infrastructure Deploy] --> B[Platform Deploy]
    B --> C[Database Bootstrap]
    C --> D[Auth Deploy]
    D --> E[Cadastro / Estoque / Ordens Deploy]
    E --> F[Entrypoint Deploy]
    F --> G[AWS E2E Validate]
    G --> H[Observability Validate]
```

1. **Database Infrastructure Deploy** (`oficina-infra-db-fiap-fase4`) cria ou
   reconcilia o backend Terraform, provisiona VPC/RDS/SSM/Secrets Manager e
   sincroniza os sete secrets SQL.
2. **Platform Deploy** (`oficina-infra-fiap-fase4`) provisiona EKS, ECR, SQS,
   add-ons e publica outputs em SSM.
3. **Database Bootstrap** (`oficina-infra-db-fiap-fase4`) executa o Job no EKS
   para criar bancos, logins, usuarios e permissoes.
4. **Auth Deploy** (`oficina-auth-lambda-fiap-fase4`) aplica Terraform,
   sincroniza `/oficina/auth/jwt` e publica as Lambdas com alias `live`.
5. **Cadastro Deploy**, **Estoque Deploy**, **Ordens Deploy** permanecem
   independentes e podem rodar em paralelo.
6. **Entrypoint Deploy** (`oficina-infra-fiap-fase4`) aplica o Ingress, aguarda o
   ALB interno e provisiona API Gateway/VPC Link.
7. **AWS E2E Validate** (`oficina-ordens-servico-fiap-fase4`) resolve a API por
   SSM e valida o fluxo principal na AWS com pagamento mock aprovado.
8. **Observability Validate** (`oficina-infra-fiap-fase4`) valida CloudWatch,
   EKS/add-ons e health endpoints sem alterar recursos.

Consulte o README de cada repositÃ³rio para os comandos especÃ­ficos de cada
etapa.

## ValidaÃ§Ã£o

ValidaÃ§Ãµes locais (sem acesso Ã  AWS): `terraform fmt`, `terraform validate`,
`terraform init -backend=false`, `helm lint`/`helm template`, `kubectl apply
--dry-run=client`, PowerShell AST, e as buscas estÃ¡ticas descritas em cada
workflow de CI.

ValidaÃ§Ãµes apÃ³s provisionamento real: workflows `*-deploy.yml` incluem passos
de validaÃ§Ã£o read-only (health, rotas, filas, Saga) antes de encerrar.

## Observabilidade

- **Logs de aplicacao**: stdout estruturado em pods, consultado via CloudWatch e
  `kubectl logs`.
- **Logs do entrypoint**: API Gateway access logs em CloudWatch.
- **Metricas AWS**: CloudWatch para API Gateway, EKS, RDS e SQS.
- **Saude operacional**: health/readiness dos tres microsservicos, EKS Ready,
  add-ons, ALB interno e VPC Link `AVAILABLE`.

New Relic permanece fora do caminho principal de provisionamento e validacao.

## Testes E2E

O workflow `AWS E2E Validate` (`oficina-ordens-servico-fiap-fase4`) resolve a
URL da API via SSM, gera token bootstrap sem imprimir o `SigningKey`, cria dados
sinteticos unicos, autentica via `/api/auth/cpf` e executa o fluxo principal:
Cadastro, Estoque, abertura de Ordem, aprovacao de Orcamento, pagamento mock
aprovado e reserva de estoque ate a Ordem chegar em `EmExecucao`.

```text
Pagamento mock aprovado: validado
SQS FIFO e health endpoints: validados
IntegraÃ§Ã£o externa de pagamentos: pendente de contrato
```

NÃ£o hÃ¡ exigÃªncia de NoSQL em nenhuma validaÃ§Ã£o, matriz ou README da soluÃ§Ã£o.

## SoluÃ§Ã£o de problemas

- **Terraform plan divergente**: confirme que nenhum recurso foi criado fora
  do Terraform (console, CLI manual); os states nÃ£o usam
  `terraform_remote_state`, entÃ£o divergÃªncias entre stacks costumam indicar
  um SSM parameter desatualizado.
- **ALB nÃ£o fica `active`**: verifique se o AWS Load Balancer Controller estÃ¡
  `Ready` (`Platform Deploy`) antes de rodar `Entrypoint Deploy`.
- **Rota protegida retorna 401/403**: confirme que o Authorizer estÃ¡ usando o
  alias `live` e que o JWT foi emitido pelo mesmo `SigningKey` publicado em
  `/oficina/auth/jwt`.
- **Mensagem presa no Inbox**: consulte `InboxMessages`/`OutboxMessages` no
  banco do serviÃ§o; o dispatcher do Outbox nÃ£o publica dentro da transaÃ§Ã£o
  original, entÃ£o uma falha de publicaÃ§Ã£o nÃ£o deixa o banco inconsistente.

## PrÃ³ximo componente

Siga para [oficina-infra-db-fiap-fase4](../oficina-infra-db-fiap-fase4/README.md)
para provisionar rede e banco.

# Oficina

Documentação de entrada da solução Oficina (FIAP Fase 4): oficina de veículos com
cadastro de clientes, controle de estoque e ordens de serviço, expostos por um
único ponto de entrada público e orquestrados sobre EKS.

Este repositório (`oficina-infra-fiap-fase4`) provisiona a plataforma
compartilhada (EKS, ECR, SQS, IAM, addons, observabilidade) e o ponto de
entrada público (API Gateway, VPC Link, ALB interno, Ingress). É o ponto
inicial de leitura da solução.

## Sumário

- [Visão geral](#visão-geral)
- [Arquitetura](#arquitetura)
- [Repositórios](#repositórios)
- [Responsabilidades](#responsabilidades)
- [Fluxos principais](#fluxos-principais)
- [Pré-requisitos](#pré-requisitos)
- [Configuração](#configuração)
- [Ordem de provisionamento](#ordem-de-provisionamento)
- [Validação](#validação)
- [Observabilidade](#observabilidade)
- [Testes E2E](#testes-e2e)
- [Solução de problemas](#solução-de-problemas)

## Visão geral

A solução é composta por três microsserviços .NET independentes (Cadastro,
Estoque, Ordens de Serviço), autenticação por Lambda (CPF/senha + JWT),
mensageria assíncrona via SQS FIFO com Inbox/Outbox e uma Saga orquestrando o
fluxo de ordem de serviço até a entrega, incluindo pagamento. O pagamento usa
um gateway mock determinístico; a integração externa real (Mercado Pago) é uma
pendência de contrato, não uma dependência de execução.

Cada microsserviço mantém banco lógico próprio no mesmo RDS SQL Server,
pipeline própria e deploy independente. Não há uso de banco NoSQL nesta
solução.

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

| Camada | Repositório | Terraform state |
| ------ | ----------- | ---------------- |
| Rede e banco (VPC, RDS SQL Server) | `oficina-infra-db-fiap-fase4` | `oficina/infra-db/terraform.tfstate` |
| Plataforma (EKS, ECR, SQS, addons, observabilidade) | `oficina-infra-fiap-fase4` | `oficina/platform/terraform.tfstate` |
| Ponto de entrada (API Gateway, VPC Link, Ingress/ALB) | `oficina-infra-fiap-fase4` | `oficina/entrypoint/terraform.tfstate` |
| Autenticação (Lambdas) | `oficina-auth-lambda-fiap-fase4` | `oficina/auth/terraform.tfstate` |

Recursos são descobertos por nome ou tag entre states sempre que seguro (ex.:
ALB por nome, ECR por nome). SSM Parameter Store é usado apenas para valores
que precisam atravessar workflows/execuções distintas (ex.: IDs de rede
publicados pela Infra DB). Não há uso de `terraform_remote_state` em nenhuma
stack.

## Repositórios

| Repositório | Responsabilidade |
| ----------- | ----------------- |
| `oficina-infra-db-fiap-fase4` | VPC, subnets, RDS SQL Server, bootstrap dos bancos e usuários |
| `oficina-infra-fiap-fase4` | EKS, ECR, SQS, addons, observabilidade, entrypoint público (este repositório) |
| `oficina-auth-lambda-fiap-fase4` | Lambdas de autenticação CPF/senha e Authorizer JWT |
| `oficina-cadastro-fiap-fase4` | Domínio de clientes, veículos e catálogo |
| `oficina-estoque-fiap-fase4` | Domínio de estoque, reservas e movimentações |
| `oficina-ordens-servico-fiap-fase4` | Domínio de ordens de serviço, orçamento, Saga e pagamento |

## Responsabilidades

- **Cadastro, Estoque e Ordens de Serviço** são independentes: CI própria,
  deploy próprio, banco lógico próprio, sem acoplamento de código entre si.
- **Auth** emite e valida JWT (HS256); não hospeda regra de negócio de domínio.
- **Infra DB** possui rede e dados; não conhece Kubernetes nem os
  microsserviços.
- **Platform** possui o cluster, os addons e a observabilidade; não conhece
  código de aplicação nem regras de negócio.
- **Entrypoint** (também neste repositório) possui o ponto de entrada público;
  não processa regra de negócio, apenas roteia e autentica.

## Fluxos principais

### Autenticação

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
    C->>GW: requisição com Bearer JWT
    GW->>Authz: REQUEST authorizer (live)
    Authz-->>GW: policy + claims
    GW->>GW: injeta headers x-oficina-user-*
```

### Mensageria (Estoque ↔ Ordens)

```mermaid
sequenceDiagram
    participant Ordens
    participant SQSCmd as SQS oficina-estoque-comandos.fifo
    participant Estoque
    participant SQSEvt as SQS oficina-ordens-eventos.fifo

    Ordens->>SQSCmd: comando (Outbox, mesma transação)
    SQSCmd->>Estoque: consumo (Inbox, idempotente)
    Estoque->>Estoque: reserva/baixa de estoque
    Estoque->>SQSEvt: evento de resultado (Outbox)
    SQSEvt->>Ordens: consumo (Inbox, idempotente)
    Ordens->>Ordens: avança a Saga
```

DLQs FIFO dedicadas para as duas filas; publicação em SQS nunca ocorre dentro
da transação de banco (Outbox garante entrega após commit).

### Saga da ordem de serviço

```mermaid
stateDiagram-v2
    [*] --> AguardandoAprovacao
    AguardandoAprovacao --> ReservaSolicitada: aprovar orçamento
    ReservaSolicitada --> ReservaRecusada: saldo insuficiente
    ReservaSolicitada --> PagamentoSolicitado: reserva confirmada
    PagamentoSolicitado --> Recusado: pagamento recusado
    PagamentoSolicitado --> EmExecucao: pagamento aprovado
    EmExecucao --> Concluida: finalizar + entregar
    ReservaRecusada --> [*]
    Recusado --> Compensada: compensação
    Compensada --> [*]
    Concluida --> [*]
```

Pagamento usa `IPaymentGateway` com implementação mock determinística e
idempotente (`MockPaymentGateway`), sem chamada HTTP externa e sem dependência
de webhook. A integração real (Mercado Pago) é uma pendência de contrato.

## Pré-requisitos

- Conta AWS com credenciais temporárias configuradas nos Repository Secrets
  dos seis repositórios antes de executar qualquer workflow de provisionamento.
- `AWS_REGION` configurada como Repository Variable.
- Terraform 1.10+, .NET 10 SDK, Docker, kubectl e Helm para validação local.

## Configuração

- `config/official.yml`: nomes estáveis e não sensíveis da plataforma
  (cluster, namespace, ECR, addons).
- `config/resource-contract.yml`: caminhos SSM de entrada/saída e nomes dos
  secrets compartilhados, consumidos pelo Terraform.
- `config/solution.yml`: contrato humano da solução (nomes de serviços,
  bancos, filas, entrypoint, sequência de provisionamento) — referência para
  documentação e validações; nenhuma aplicação o lê em runtime.
- `config/entrypoint.json` e `config/ingress-routes.json`: contratos versionados
  do API Gateway e do Ingress compartilhado.

Nenhum destes arquivos contém senha, ARN gerado, URL real de fila/API ou
Account ID.

## Ordem de provisionamento

```mermaid
flowchart LR
    A[Backend Bootstrap] --> B[Infra DB Deploy]
    B --> C[Observability Secret Sync]
    C --> D[Platform Deploy]
    D --> E[Database Secrets Sync]
    E --> F[Database Bootstrap]
    F --> G[Auth Secret Sync]
    G --> H[Auth Deploy]
    H --> I[Cadastro / Estoque / Ordens Deploy]
    I --> J[Entrypoint Deploy]
    J --> K[E2E Validate]
```

1. **Backend Bootstrap** (`oficina-infra-db-fiap-fase4`) — cria o bucket do
   Terraform state.
2. **Infra DB Deploy** (`oficina-infra-db-fiap-fase4`) — VPC, subnets, RDS.
3. **Observability Secret Sync** (`oficina-infra-fiap-fase4`) — sincroniza a
   licença New Relic no Secrets Manager antes do Platform Deploy.
4. **Platform Deploy** (`oficina-infra-fiap-fase4`) — EKS, ECR, SQS, addons e
   observabilidade (OpenTelemetry Collector e New Relic via Helm, gerenciados
   pelo próprio Terraform desta stack).
5. **Database Secrets Sync** + **Database Bootstrap**
   (`oficina-infra-db-fiap-fase4`) — sincroniza os secrets SQL e executa o Job
   Kubernetes que cria bancos, logins e usuários.
6. **Auth Secret Sync** + **Auth Deploy** (`oficina-auth-lambda-fiap-fase4`) —
   sincroniza a chave JWT e publica as duas Lambdas.
7. **Cadastro Deploy**, **Estoque Deploy**, **Ordens Deploy** — independentes
   entre si, podem rodar em paralelo após os passos anteriores.
8. **Entrypoint Deploy** (`oficina-infra-fiap-fase4`) — aplica o Ingress
   compartilhado, aguarda o ALB interno, e então provisiona API Gateway e VPC
   Link no mesmo workflow (sem handoff intermediário por SSM).
9. **E2E Validate** (`oficina-ordens-servico-fiap-fase4`) — valida o fluxo
   completo via Docker Compose (Cadastro, Estoque, Ordens, LocalStack,
   WireMock).

Consulte o README de cada repositório para os comandos específicos de cada
etapa.

## Validação

Validações locais (sem acesso à AWS): `terraform fmt`, `terraform validate`,
`terraform init -backend=false`, `helm lint`/`helm template`, `kubectl apply
--dry-run=client`, PowerShell AST, e as buscas estáticas descritas em cada
workflow de CI.

Validações após provisionamento real: workflows `*-deploy.yml` incluem passos
de validação read-only (health, rotas, filas, Saga) antes de encerrar.

## Observabilidade

- **Traces**: aplicações → OTLP → OpenTelemetry Collector → New Relic.
- **Logs**: stdout estruturado (JSON) → coleta padrão do cluster → New Relic.
- **Métricas Kubernetes**: New Relic Kubernetes Integration → New Relic.
- **Métricas AWS**: CloudWatch.

Cada sinal tem um único caminho de coleta; não há duplicidade de ferramentas
para o mesmo sinal. A licença New Relic é sincronizada pelo workflow
`Observability Secret Sync` e nunca é impressa em logs.

## Testes E2E

O workflow `E2E Validate` (`oficina-ordens-servico-fiap-fase4`) sobe Cadastro,
Estoque, Ordens, LocalStack e WireMock via Docker Compose e executa o fluxo
completo: orçamento aprovado, reserva de estoque, pagamento mock aprovado,
Saga concluída até a entrega, além dos cenários de saldo insuficiente,
pagamento recusado (com compensação) e mensagem fora de ordem.

```text
Pagamento mock aprovado: validado
Compensação mock: validada
Integração externa de pagamentos: pendente de contrato
```

Não há exigência de NoSQL em nenhuma validação, matriz ou README da solução.

## Solução de problemas

- **Terraform plan divergente**: confirme que nenhum recurso foi criado fora
  do Terraform (console, CLI manual); os states não usam
  `terraform_remote_state`, então divergências entre stacks costumam indicar
  um SSM parameter desatualizado.
- **ALB não fica `active`**: verifique se o AWS Load Balancer Controller está
  `Ready` (`Platform Deploy`) antes de rodar `Entrypoint Deploy`.
- **Rota protegida retorna 401/403**: confirme que o Authorizer está usando o
  alias `live` e que o JWT foi emitido pelo mesmo `SigningKey` publicado em
  `/oficina/auth/jwt`.
- **Mensagem presa no Inbox**: consulte `InboxMessages`/`OutboxMessages` no
  banco do serviço; o dispatcher do Outbox não publica dentro da transação
  original, então uma falha de publicação não deixa o banco inconsistente.

## Próximo componente

Siga para [oficina-infra-db-fiap-fase4](../oficina-infra-db-fiap-fase4/README.md)
para provisionar rede e banco.

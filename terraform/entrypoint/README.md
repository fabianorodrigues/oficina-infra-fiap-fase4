# Entrypoint — API Gateway HTTP API, VPC Link e integracoes

Stack Terraform independente que cria a entrada publica oficial da solucao Oficina.
E o unico ponto publico; o ALB continua interno.

## Arquitetura

```text
Internet
  -> API Gateway HTTP API (oficina-api, stage $default)
    -> Lambda Authorizer (oficina-authorizer:live)   [rotas protegidas]
    -> VPC Link (oficina, subnets privadas, SG dedicado)
      -> Listener HTTP 80 do ALB interno oficina
        -> Ingress oficina
          -> Services ClusterIP
            -> Pods
```

Fluxo de autenticacao (login), sem passar pelo ALB:

```text
POST /api/auth/cpf
  -> API Gateway
    -> oficina-auth-cpf:live (Lambda proxy, payload 2.0)
      -> OficinaCadastroDb
        -> JWT (HS256, issuer oficina, audience oficina-api)
```

## Rotas protegidas

Authorizer REQUEST (payload 2.0, simple responses, cache TTL 0). Roles apenas
documentais; a autorizacao funcional final permanece nos microservicos.

| Metodo | Path | Backend | Auth | Roles |
| ------ | ---- | ------- | ---- | ----- |
| ANY | `/api/clientes` (+ `/{proxy+}`) | cadastro | CUSTOM | Funcionario, Admin |
| ANY | `/api/veiculos` (+ `/{proxy+}`) | cadastro | CUSTOM | Funcionario, Admin |
| ANY | `/api/servicos` (+ `/{proxy+}`) | cadastro | CUSTOM | Funcionario, Admin |
| ANY | `/api/admin/funcionarios` (+ `/{proxy+}`) | cadastro | CUSTOM | Admin |
| ANY | `/api/estoque` (+ `/{proxy+}`) | estoque | CUSTOM | Funcionario, Admin |
| ANY | `/api/insumos` (+ `/{proxy+}`) | estoque | CUSTOM | Funcionario, Admin |
| ANY | `/api/pecas` (+ `/{proxy+}`) | estoque | CUSTOM | Funcionario, Admin |
| ANY | `/api/ordens-servico` (+ `/{proxy+}`) | ordens | CUSTOM | Funcionario, Admin |
| ANY | `/api/minhas-ordens-servico` (+ `/{proxy+}`) | ordens | CUSTOM | Cliente |
| ANY | `/api/orcamentos` (+ `/{proxy+}`) | ordens | CUSTOM | Funcionario, Admin |
| ANY | `/api/meus-orcamentos` (+ `/{proxy+}`) | ordens | CUSTOM | Cliente |
| ANY | `/api/relatorios` (+ `/{proxy+}`) | ordens | CUSTOM | Funcionario, Admin |

Cada prefixo cria a rota base e a rota `{proxy+}` para cobrir os sub-recursos.

## Rotas publicas (sem Authorizer)

| Metodo | Path | Destino | Justificativa |
| ------ | ---- | ------- | ------------- |
| POST | `/api/auth/cpf` | Lambda `oficina-auth-cpf:live` | Login (emite JWT) |
| GET | `/health/cadastro` | ALB `/health` (header cadastro) | Health publico |
| GET | `/health/estoque` | ALB `/health` (header estoque) | Health publico |
| GET | `/health/ordens` | ALB `/health` (header ordens) | Health publico |
| GET | `/api/orcamentos/acoes-externas/{proxy+}` | ALB ordens | `AllowAnonymous` no codigo (aprovar/recusar orcamento por link) |

Toda rota `NONE` esta na `publicAllowlist` de `config/entrypoint.json`. Qualquer
outra rota sem autenticacao reprova a validacao.

## Health por header interno

Os tres backends usam o mesmo path interno `/health`. O API Gateway reescreve o
path e injeta o header confiavel `x-oficina-health-target`; o ALB seleciona o
backend por condicao de header (acoes anotadas no Ingress).

| Rota externa | Path interno | Header | Backend |
| ------------ | ------------ | ------ | ------- |
| `GET /health/cadastro` | `/health` | `x-oficina-health-target: cadastro` | oficina-cadastro |
| `GET /health/estoque` | `/health` | `x-oficina-health-target: estoque` | oficina-estoque |
| `GET /health/ordens` | `/health` | `x-oficina-health-target: ordens` | oficina-ordens-servico |

`/health` nunca e exposto diretamente no API Gateway.

## Headers confiaveis de identidade

Nas integracoes protegidas os headers de identidade sao **sobrescritos** (nao
`append`) a partir do contexto do Authorizer, impedindo spoofing pelo cliente:

| Header | Origem |
| ------ | ------ |
| `x-oficina-user-id` | `$context.authorizer.sub` |
| `x-oficina-user-cpf` | `$context.authorizer.cpf` |
| `x-oficina-user-role` | `$context.authorizer.role` |
| `x-oficina-user-name` | `$context.authorizer.name` |
| `x-oficina-token-jti` | `$context.authorizer.jti` |
| `x-oficina-request-id` | `$context.requestId` |

Nas integracoes publicas e de health esses headers sao **removidos**. O header
`Authorization` continua encaminhado (os microservicos podem valida-lo).

> Dependencia bloqueante: hoje os microservicos, em producao, nao registram
> handler JWT nem consomem `x-oficina-*`. Ver `Limitacoes e dependencias`.

## Rotas proibidas (nunca publicadas)

```text
/ready
/api/internal/*
/api/dev/*
```

## Estado e comunicacao entre stacks

- Backend S3 independente: `oficina/entrypoint/terraform.tfstate`.
- Sem `terraform_remote_state`. A comunicacao com Infra DB, Platform, Auth e
  Ingress ocorre apenas por SSM Parameter Store e data sources AWS.

Entradas (SSM):

```text
/oficina/infra/vpc/id
/oficina/infra/subnets/private/1
/oficina/infra/subnets/private/2
/oficina/infra/alb/arn
/oficina/infra/alb/listener-arn
/oficina/auth/cpf/function-name
/oficina/auth/cpf/alias-arn
/oficina/auth/authorizer/function-name
/oficina/auth/authorizer/alias-arn
```

Saidas (SSM, String):

```text
/oficina/infra/api/id
/oficina/infra/api/url
/oficina/infra/api/execution-arn
/oficina/infra/api/stage
/oficina/infra/api/vpc-link-id
```

## Security Groups

- SG dedicado `oficina-api-vpc-link`: sem ingress; egress TCP 80 apenas para o SG
  frontend do ALB.
- Regra standalone de ingress adicionada ao SG frontend do ALB permitindo apenas o
  SG do VPC Link na porta 80. Nao assume ownership do SG gerenciado pelo AWS Load
  Balancer Controller.
- O SG frontend e detectado automaticamente excluindo o SG backend compartilhado
  (tag `elbv2.k8s.aws/resource=backend-sg`). Se houver ambiguidade, o plan falha e
  `alb_frontend_security_group_id` deve ser informado.

## Recursos

```text
aws_security_group.vpc_link
aws_vpc_security_group_egress_rule.vpc_link_to_alb
aws_vpc_security_group_ingress_rule.alb_from_vpc_link
aws_cloudwatch_log_group.api
aws_apigatewayv2_vpc_link.this
aws_apigatewayv2_api.this
aws_apigatewayv2_stage.default
aws_apigatewayv2_integration.alb_protected | alb_public | health[*] | auth_lambda
aws_apigatewayv2_authorizer.jwt
aws_apigatewayv2_route.this[*]
aws_lambda_permission.auth_cpf | authorizer
aws_ssm_parameter.outputs[*]
```

## Validacoes locais

```powershell
pwsh scripts/validate-entrypoint-config.ps1
pwsh scripts/validate-route-contract.ps1
pwsh scripts/validate-ingress-config.ps1

cd terraform/entrypoint
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform providers
```

Nao executar `terraform apply`, `terraform destroy`, workflows ou comandos AWS
mutantes localmente.

## Execucao futura

```text
GitHub -> Actions -> Entrypoint Deploy -> Run workflow -> Branch main -> confirmation APPLY
```

Ordem obrigatoria:

```text
1. Ingress Deploy atualizado (regras de health por header no ALB)
2. Confirmar ALB e targets saudaveis
3. Entrypoint Deploy
```

O `Entrypoint Deploy` falha antes do `terraform apply` se as tres regras de health
por header ainda nao existirem no listener do ALB.

## Dependencias

```text
Backend Terraform S3
Infra DB
Platform
Auth (oficina-auth-cpf, oficina-authorizer, aliases live)
Cadastro, Estoque, Ordens publicados
Ingress compartilhado atualizado (health por header)
ALB interno oficina + Listener HTTP 80 + targets saudaveis
```

## Limitacoes e dependencias academicas

- Sem dominio customizado, sem ACM, sem Route 53, sem WAF, sem API Key/Usage Plan.
- Sem TLS interno (HTTP dentro da VPC entre VPC Link e ALB).
- Cache do Authorizer desabilitado (TTL 0) nesta etapa.
- Um unico ambiente AWS (sem dev/hml/prod).
- Sem pipeline de destroy; a limpeza ocorre pelo reset do AWS Academy.
- **Bloqueante para E2E funcional**: em producao os microservicos usam
  `services.AddAuthentication()` sem esquema JWT e nao consomem `x-oficina-*`. O
  Authorizer e os headers confiaveis ja sao aplicados aqui, mas a autorizacao
  funcional real depende de os microservicos passarem a validar o JWT ou consumir
  a identidade confiavel. Nao remover o Authorizer para "passar" o E2E.

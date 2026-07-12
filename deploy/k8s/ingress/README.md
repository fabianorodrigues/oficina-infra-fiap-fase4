# Ingress compartilhado e ALB interno `oficina`

Este diretorio define o unico Ingress compartilhado da plataforma Oficina, que
materializa um unico ALB interno para os tres microservicos. O Ingress pertence a
este repositorio de infraestrutura. Os microservicos nao possuem Ingress proprio.

## Arquitetura

```text
API Gateway futuro
  -> VPC Link futuro
    -> ALB interno oficina
      -> Ingress oficina (IngressClass alb)
        -> Services ClusterIP
          -> Pods
```

Nesta etapa apenas o ALB interno, o Ingress, os Target Groups, o Listener HTTP 80,
as regras de roteamento, os health checks e os parametros SSM do ALB sao criados.
API Gateway, VPC Link, Lambda Authorizer, rotas externas, CORS, throttling e WAF
pertencem a etapas posteriores.

## Backends

| Servico                  | Service (ClusterIP) | Porta |
| ------------------------ | ------------------- | ----: |
| Cadastro                 | `oficina-cadastro`         | 8080 |
| Estoque                  | `oficina-estoque`          |   80 |
| Ordens de servico        | `oficina-ordens-servico`   |   80 |

> A porta do Service `oficina-cadastro` e `8080`; `oficina-estoque` e
> `oficina-ordens-servico` usam `80`. Todos os containers expoem `http` em `8080`
> (`targetPort: http`), portanto o health check do Target Group usa `traffic-port`.

## Seguranca

```text
ALB internal (scheme=internal)
Sem endpoint publico
Sem internet-facing
Sem NodePort
Sem Service LoadBalancer
Sem autenticacao no ALB
Autenticacao futura no API Gateway
```

O ALB e interno e nao deve ser acessivel diretamente da internet. Nao ha Cognito,
OIDC, JWT nem Lambda Authorizer no ALB. As aplicacoes mantem suas proprias regras
de autorizacao (`Authorize`/`AllowAnonymous`). O Security Group do ALB e gerenciado
automaticamente pelo AWS Load Balancer Controller; o endurecimento para permitir
somente o Security Group do VPC Link podera ser feito na etapa de Entrypoint.

Nesta solução, `API Gateway -> VPC Link -> ALB` usa HTTP dentro da VPC. Ambientes
corporativos devem avaliar TLS interno.

## Rotas expostas

Somente rotas publicas confirmadas no codigo dos microservicos entram no Ingress.
Todas usam `pathType: Prefix`. As regras sao ordenadas da mais especifica para a
mais ampla pelo renderer.

| Prefixo                       | Servico                  | Exposicao                          |
| ----------------------------- | ------------------------ | ---------------------------------- |
| `/api/admin/funcionarios`     | `oficina-cadastro`       | Publica (AdminOnly)                |
| `/api/clientes`               | `oficina-cadastro`       | Publica (FuncionarioOuAdmin)       |
| `/api/servicos`               | `oficina-cadastro`       | Publica (FuncionarioOuAdmin)       |
| `/api/veiculos`               | `oficina-cadastro`       | Publica (FuncionarioOuAdmin)       |
| `/api/estoque`                | `oficina-estoque`        | Publica (FuncionarioOuAdmin)       |
| `/api/insumos`                | `oficina-estoque`        | Publica (FuncionarioOuAdmin)       |
| `/api/pecas`                  | `oficina-estoque`        | Publica (FuncionarioOuAdmin)       |
| `/api/meus-orcamentos`        | `oficina-ordens-servico` | Publica (ClienteOnly)              |
| `/api/minhas-ordens-servico`  | `oficina-ordens-servico` | Publica (ClienteOnly)              |
| `/api/orcamentos`             | `oficina-ordens-servico` | Publica; inclui `/acoes-externas`  |
| `/api/ordens-servico`         | `oficina-ordens-servico` | Publica (FuncionarioOuAdmin)       |
| `/api/relatorios`             | `oficina-ordens-servico` | Publica (FuncionarioOuAdmin)       |

`/api/orcamentos/acoes-externas` (`AllowAnonymous`) e coberto pelo prefixo
`/api/orcamentos` no mesmo backend; por isso nao ha regra separada.

## Rotas nao expostas

```text
/ready                       (readiness, usado apenas pelo Kubernetes)
/api/internal/*              (cadastro e estoque - service-to-service)
/api/dev/*                   (ordens - habilitado apenas em Development)
```

Nenhum prefixo publico e ancestral de uma rota proibida, portanto nenhuma dessas
rotas e alcancavel pelo ALB. O `validate-ingress-config.ps1` falha se uma rota
publica mais ampla expuser qualquer uma delas, ou se houver `/`, `/api`,
`/api/internal*`, `/api/dev*` ou `/ready`.

## Health

```text
Target Groups usam /health (HTTP, traffic-port, success 200-399)
Intervalo 15s, timeout 5s, healthy 2, unhealthy 3
/ready NAO e exposto e continua exclusivo do Kubernetes
```

Os mapeamentos externos `/health/<servico> -> /health` sao criados no API Gateway
(stack Entrypoint). Como os tres backends usam o mesmo path interno `/health`, o
ALB nao consegue escolher o Target Group apenas pelo path. Por isso o Ingress
declara tres acoes anotadas que selecionam o backend por header confiavel.

## Health por header interno

O API Gateway reescreve `/health/<servico>` para `/health` e injeta o header
`x-oficina-health-target`. O Ingress usa `alb.ingress.kubernetes.io/actions.<nome>`
e `alb.ingress.kubernetes.io/conditions.<nome>` para tres acoes cujo forward so se
aplica quando o header casa. Assim a condicao afeta apenas a acao de health e nunca
as rotas funcionais `/api/*` do mesmo Service.

| Header | Valor | Path | Backend |
| ------ | ----- | ---- | ------- |
| `x-oficina-health-target` | `cadastro` | `/health` | `oficina-cadastro` |
| `x-oficina-health-target` | `estoque` | `/health` | `oficina-estoque` |
| `x-oficina-health-target` | `ordens` | `/health` | `oficina-ordens-servico` |

Continua existindo um unico Ingress. `/health` nao e exposto diretamente (sem o
header nenhuma regra casa) e `/ready` permanece exclusivo do Kubernetes.

## IngressClass

A `IngressClass alb` pertence a Platform: o chart Helm do AWS Load Balancer
Controller a cria por padrao (`createIngressClassResource: true`,
`ingressClass: alb`). Por isso este repositorio NAO cria uma segunda IngressClass
com o mesmo nome; o Ingress apenas referencia `alb`. O workflow de deploy aplica
uma IngressClass local somente se `deploy/k8s/ingress/ingress-class.yaml` existir
(ownership deste repositorio); caso contrario, apenas valida a existente.

## Renderizacao

`ingress.template.yaml` e um template com tokens. Nunca aplique o template
diretamente. O renderer preenche subnets privadas, regras dos backends e os valores
de health check a partir de `config/ingress-routes.json`:

```powershell
pwsh scripts/render-ingress.ps1 `
  -OutputDirectory ./out `
  -PrivateSubnet1 subnet-00000000000000001 `
  -PrivateSubnet2 subnet-00000000000000002
```

No modo local, subnets sinteticas sao aceitas. O deploy real usa as duas subnets
privadas lidas do SSM. O renderer e deterministico e falha se algum placeholder
permanecer.

## Descoberta pela stack Entrypoint

O ALB e o Listener HTTP 80 nao sao publicados no SSM. A stack Terraform de
Entrypoint (`terraform/entrypoint/`) os descobre por nome (`data "aws_lb"` +
`data "aws_lb_listener"`) no mesmo workflow que aplica este Ingress, logo apos
o ALB ficar ativo. Nenhum outro repositorio precisa copiar esses valores
manualmente.

## Execucao

```text
GitHub -> Actions -> Entrypoint Deploy -> Run workflow -> Branch main -> confirmation APPLY
```

O workflow `Entrypoint Deploy` aplica este Ingress e, na sequencia, a stack
Terraform de Entrypoint, no mesmo run. So executa em `refs/heads/main` com
`confirmation = APPLY`. Nao ha pipeline de destroy nem script de exclusao do
ALB; correcoes ocorrem por PR normal seguido de novo `Entrypoint Deploy`.

## Dependencias

```text
Infra DB provisionada
Platform provisionada
EKS oficina ativo
AWS Load Balancer Controller ativo (Deployment Ready + webhook)
IngressClass alb (Platform)
Subnets privadas com tag kubernetes.io/role/internal-elb=1
Cadastro, Estoque e Ordens publicados
Services ClusterIP com EndpointSlices e Pods saudaveis
/health saudavel nos tres servicos
```

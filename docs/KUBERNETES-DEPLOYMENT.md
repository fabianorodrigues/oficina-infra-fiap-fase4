# Deploy no Kubernetes (K3s single-node)

Como a plataforma e provisionada, como os microsservicos chegam ao cluster e o
que cada decisao protege.

---

## 1. Topologia

```
Postman
  -> API Gateway HTTP API
  -> Lambda Authorizer
  -> VPC Link
  -> ALB interno
  -> Target Groups (target_type = instance, health check /ready)
  -> EC2 privada
  -> K3s single-node
  -> NodePorts 30080, 30081 e 30082
  -> Pods
  -> RDS SQL Server e SQS
```

| Item | Decisao |
|---|---|
| Compute | Uma EC2 privada, `t3.medium`, Amazon Linux 2023, EBS `gp3` criptografado |
| Acesso operacional | Somente Systems Manager. Sem SSH, sem key pair, sem porta `6443` exposta |
| Orquestrador | K3s single-node. Sem Ingress Controller, sem Traefik, sem ServiceLB |
| Health | Target Group em `/ready`; `livenessProbe` em `/health`; `readinessProbe` em `/ready` |
| IMDS | IMDSv2 obrigatorio, hop limit `2` |
| IAM | Nenhum recurso IAM e criado ou alterado. O instance profile e externo e chega por `INSTANCE_PROFILE_NAME` |

> A topologia single-node atende ao escopo desta entrega, mas nao representa
> alta disponibilidade de producao.

---

## 2. Versao do K3s

**`v1.35.6+k3s1`**.

A fonte unica e `config/official.yml`, bloco `kubernetes`. O workflow exporta
`TF_VAR_k3s_version` a partir desse arquivo, e `variables.tf` **nao tem
default** — um default seria uma segunda fonte silenciosa, usada por qualquer
`terraform apply` fora do workflow.

`scripts/validate-k3s-version.ps1` compara o **valor literal** entre
`config/official.yml`, a variavel exportada e este documento, e ainda verifica
que nenhum outro arquivo de `terraform/`, `.github/` ou `scripts/` fixa uma
versao. A assercao de formato em `terraform/platform/validations.tf` e
complementar: sozinha ela aprovaria arquivos coerentes em formato e divergentes
em valor.

### Instalacao

```
install.sh de commit fixo
  -> download
  -> conferencia do SHA-256 do instalador
  -> download do binario da versao fixa
  -> conferencia do SHA-256 do binario
  -> instalacao com INSTALL_K3S_SKIP_DOWNLOAD=true
```

O instalador vem de um commit, nao do canal `stable` nem de uma branch:
conteudo de commit e imutavel, entao o par URL + checksum e reproduzivel.
Qualquer divergencia interrompe o bootstrap **antes** de instalar.

Detalhe que quebra em silencio se esquecido: o `+` da versao precisa vir
percent-encoded como `%2B` na URL de download do binario, embora
`INSTALL_K3S_VERSION` receba a string literal com `+`.

---

## 3. Bootstrap da EC2

`terraform/platform/user-data.sh.tftpl`, com `set -euo pipefail` e **sem
`set -x`**:

1. **SSM Agent** — presenca, instalacao se ausente, `enable --now`, restart e
   confirmacao de `is-active`. Sem ele nao existe caminho de acesso.
2. **NAT** — validacao da saida para a internet, com falha explicita. Falhar
   aqui produz uma mensagem clara; falhar adiante produziria timeout sem causa.
3. **firewalld** — desabilitado durante o bootstrap quando ativo. O isolamento
   de rede e responsabilidade dos security groups.
4. Dependencias (`jq`, `tar`, AWS CLI v2) e `/opt/oficina/{manifests,scripts,stage}`
   com `umask 077`.
5. `/etc/rancher/k3s/config.yaml` escrito **antes** da instalacao. O instalador
   e chamado sem `INSTALL_K3S_EXEC`: toda a configuracao vive no arquivo,
   auditavel em disco e preservada em upgrade do binario.
6. Validacao pos-bootstrap: `systemctl is-active k3s`, node `Ready` e versao
   instalada igual a esperada. So entao `/opt/oficina/BOOTSTRAP_COMPLETE` e
   escrito — e esse o sinal consumido pelo workflow.
7. Namespace `oficina` aplicado.

### Diagnostico quando o SSM nao responde

```
Timeout do SSM
  -> aws ec2 describe-instances        (state, subnet, instance profile)
  -> aws ec2 describe-instance-status  (system e instance checks)
  -> aws ec2 get-console-output        (log do cloud-init e do user data)
  -> publicar diagnostico no step summary
  -> interromper o workflow com erro
```

Sem SSH e sem SSM, o console output e a unica janela para o bootstrap: falta de
rota para o NAT, checksum divergente, `firewalld` ativo ou SSM Agent que nao
subiu.

---

## 4. Transporte dos manifests: Stage e Deploy

Os pacotes usam o bucket de Terraform State, **somente** no prefixo
`k8s-deploy/<servico>/<run-id>/`, e **nunca contem Secrets**.

```
GitHub Actions
  -> renderizar manifests sem secrets
  -> validar placeholders
  -> gerar tar.gz e SHA256SUMS
  -> calcular SHA-256 do pacote
  -> upload no S3
  -> gerar URL pre-assinada com TTL de 5 minutos
  -> armazenar a URL como SecureString temporario
  -> Comando SSM 1: Stage
  -> excluir objeto S3
  -> excluir SecureString
  -> Comando SSM 2: Deploy
```

A separacao em dois comandos existe para que a credencial temporaria **deixe de
existir antes de qualquer alteracao no cluster**. Se Stage e Deploy fossem um
so, a URL sobreviveria durante todo o rollout.

O Run Command do Stage recebe apenas **nome de parametro e hash** — nenhum dos
dois e credencial. A URL nunca e impressa, e mascarada com `::add-mask::`, fica
fora do step summary e sai da memoria logo apos o download.

### `ssm:DeleteParameter` e pre-requisito

Se a permissao nao estiver disponivel, **o SecureString nao e criado** e o
deploy usa o fallback por arquivo. Sobrescrever o parametro nao e forma de
limpeza: deixa historico de versoes e nao elimina o valor.

### Fallback

Um manifesto por Run Command, com tamanho e hash validados individualmente, e
aplicacao somente depois que todos foram recebidos. Pacote Base64 unico esta
proibido: o modo de falha e truncamento silencioso.

### Preflight de permissoes

| Principal | Acoes | Escopo |
|---|---|---|
| Executor | `s3:PutObject`, `GetObject`, `DeleteObject`, `DeleteObjectVersion` | `<bucket>/k8s-deploy/*` |
| Executor | `ssm:PutParameter`, `ssm:DeleteParameter` | `/oficina/deploy/*` |
| Role da EC2 | `ssm:GetParameter` com `kms:Decrypt` | `/oficina/deploy/*` |
| Role da EC2 | nenhuma permissao de S3 no fluxo padrao | download e pela URL pre-assinada |

O executor precisa de `s3:GetObject` porque e ele quem assina a URL: a
assinatura so vale para uma acao que o signatario poderia executar.

A simulacao de permissoes **sempre** informa `aws:RequestedRegion`. Sem essa
chave de contexto, politicas condicionadas por regiao devolvem `implicitDeny` e
o preflight reprovaria por falso negativo.

---

## 5. Deploy de um microsservico

Dentro do Comando SSM 2, na ordem:

```
revalidar os hashes locais (SHA256SUMS)
  -> pull da imagem de runtime
  -> pull da imagem de migration
  -> aplicar ConfigMaps
  -> criar Secret de aplicacao e Secret de migration
  -> aplicar o Migration Job com o commit SHA no nome
  -> aguardar conclusao e capturar logs
  -> interromper o deploy em falha
  -> aplicar Deployment e Service
  -> validar o rollout
  -> remover Migration Jobs anteriores por label
  -> validar a capacidade do node
```

Duas razoes para essa ordem: as **duas imagens** sao obtidas antes de qualquer
apply, senao um problema de registry viraria timeout de migration com o Job em
`ImagePullBackOff`; e os **Secrets vem antes do Job**, que precisa da credencial
de migration para rodar.

### Pull de imagem

O containerd do K3s nao tem credential helper de ECR:

```bash
TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")
k3s ctr --namespace k8s.io images pull --user "AWS:$TOKEN" "$IMAGE"
```

O token e obtido com a role da instancia, usado uma vez e limpo da memoria.

### Migration Jobs

Nome imutavel por deploy:

```
oficina-cadastro-migration-<short-sha>
oficina-estoque-migration-<short-sha>
oficina-ordens-servico-migration-<short-sha>
```

`spec.template` e campo imutavel de Job: `kubectl apply` sobre nome fixo com
imagem nova falha. A limpeza dos anteriores usa
`app.kubernetes.io/component=migration` combinado com `oficina.io/commit`.

**Migrations seguem Expand and Contract.** Proibido na mesma implantacao:
remocao de coluna, renomeacao destrutiva, alteracao incompativel e exclusao de
tabela ainda usada pela versao anterior. Motivo concreto: com `maxSurge: 0` o
Job roda antes do novo Deployment, entao o schema novo convive por instantes
com o Pod anterior.

---

## 6. Secrets

Dois Secrets Kubernetes por microsservico:

```
<servico>-database-app         -> Deployment
<servico>-database-migration   -> Migration Job
```

- o Deployment **nao recebe** credencial de migration;
- o Migration Job **nao recebe** credencial de aplicacao;
- o usuario de aplicacao **nao altera schema**;
- os valores sao lidos do Secrets Manager **dentro da EC2**, com a role da
  instancia;
- os valores **nao passam** pelo runner, pelo S3 nem por parametro do Run
  Command;
- o Secret de migration e removido logo apos o Job.

Os templates versionados contem apenas os placeholders
`__APP_CONNECTION_STRING_B64__` e `__MIGRATION_CONNECTION_STRING_B64__`, e sao
os unicos placeholders autorizados a sobreviver dentro do pacote.

---

## 7. Health checks e capacidade

| Ponto | Endpoint |
|---|---|
| Target Group do ALB | `/ready` |
| `livenessProbe` | `/health` |
| `readinessProbe` | `/ready` |

`/ready` consulta o banco proprio nos tres servicos: o ALB passa a considerar
saudavel apenas o servico pronto para receber trafego, e nao o processo apenas
de pe.

Deployment padronizado: `replicas: 1`, `containerPort: 8080`,
`terminationGracePeriodSeconds: 30`, `progressDeadlineSeconds: 600`,
`imagePullPolicy: IfNotPresent`, `maxSurge: 0` e `maxUnavailable: 1`.

| Workload | requests | limits |
|---|---|---|
| API (x3) | `150m` / `320Mi` | `500m` / `640Mi` |
| Migration Job | `100m` / `256Mi` | `500m` / `512Mi` |
| Bootstrap e isolamento | `100m` / `256Mi` | `500m` / `512Mi` |

Apos cada deploy o comando valida `free -m`, `df -h`, `k3s crictl stats`,
ausencia de Pod `Pending` e `MemoryPressure`, `DiskPressure` e `PIDPressure`
todos `False`. Qualquer pressao **falha o deploy**. Aumento de capacidade
somente por `k3s_instance_type`, nunca reduzindo requests e limits nem
alterando a instancia manualmente.

### Security groups

| Origem | Destino | Porta |
|---|---|---|
| SG do ALB | SG do K3s | `30080-30082` |
| SG do K3s | SG do RDS | `1433` |

Os NodePorts nao sao acessiveis de fora: a EC2 fica em subnet privada, sem IP
publico, e o unico ingress nessa faixa vem do SG do ALB.

---

## 8. Contratos SSM

Publicados pela plataforma:

```
/oficina/infra/k8s/{instance-id,security-group-id,namespace}
/oficina/infra/services/<svc>/{target-group-arn,node-port}
/oficina/infra/{vpc,subnets,rds,alb,ecr,sqs,api}/*
```

Aposentados com o runtime anterior e listados em `config/resource-contract.yml`
sob `retired`, apenas para orientar a limpeza operacional:

```
/oficina/infra/cluster/*
/oficina/infra/ecs/*
```

---

## 9. Ordem de execucao

| # | Repositorio | Workflow | Confirmacao |
|:---:|---|---|:---:|
| 1 | oficina-infra-db | Database Infrastructure Deploy | `APPLY` |
| 2 | oficina-infra | Platform Deploy | `APPLY` |
| 3 | oficina-infra-db | Database Bootstrap | `BOOTSTRAP` |
| 4 | oficina-auth-lambda | Auth Deploy | `DEPLOY` |
| 5 | oficina-cadastro | Cadastro Deploy | `DEPLOY` |
| 6 | oficina-estoque | Estoque Deploy | `DEPLOY` |
| 7 | oficina-ordens-servico | Ordens Deploy | `DEPLOY` |
| 8 | oficina-infra | Entrypoint Deploy | `APPLY` |

O **Platform Deploy** aceita `allow_replace` com **enderecos Terraform exatos**
liberados para substituicao. Tipos de recurso nunca sao liberados em bloco:
liberar `aws_lb_target_group` liberaria os tres de uma vez.

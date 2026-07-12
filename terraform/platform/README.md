# Terraform Platform

Stack Terraform da plataforma compartilhada `oficina`.

## O que esta stack cria

- Cluster EKS `oficina`.
- Managed Node Group `oficina`.
- Namespace `oficina`.
- Add-ons gerenciados `vpc-cni`, `coredns`, `kube-proxy` e `eks-pod-identity-agent`.
- ECR dos microservicos cadastro, estoque e ordens de servico.
- SQS FIFO com DLQs FIFO dedicadas.
- Roles IAM para `cadastro-runtime`, `cadastro-migrator`, `estoque-runtime`, `estoque-migrator`, `ordens-runtime`, `ordens-migrator` e `db-bootstrap`.
- EKS Pod Identity ou IRSA, conforme `config/official.yml`.
- AWS Load Balancer Controller, Secrets Store CSI Driver e ASCP via Helm.
- Container Secrets Manager da New Relic sem gravar valor.
- Parametros SSM de saida nao sensiveis.

## Backend

`backend.tf` declara somente:

```hcl
terraform {
  backend "s3" {}
}
```

A pipeline manual fornece bucket, key, region, encryption e `use_lockfile=true`.

## Validacoes locais

```powershell
terraform fmt -recursive
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform providers
pwsh ../../scripts/validate-platform-config.ps1
```

Nao execute `apply` localmente. A criacao oficial sera feita apenas pelo workflow manual apos merge na `main`.

## Identidade

O modo padrao e `pod-identity`. Para usar o fallback, altere `workloadIdentity.mode` em `config/official.yml` para `irsa`. A stack nao habilita os dois modos para a mesma ServiceAccount.

Se Pod Identity e IRSA estiverem indisponiveis, a Node Role compartilhada pode ser usada apenas como fallback manual temporario e documentado fora desta stack.

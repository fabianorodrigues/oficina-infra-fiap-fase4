data "tls_certificate" "eks_oidc" {
  count = local.workload_mode == "irsa" ? 1 : 0

  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count = local.workload_mode == "irsa" ? 1 : 0

  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc[0].certificates[0].sha1_fingerprint]
}

locals {
  oidc_provider_arn = local.workload_mode == "irsa" ? aws_iam_openid_connect_provider.eks[0].arn : ""
  oidc_provider_url = local.workload_mode == "irsa" ? replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "") : ""
}

data "aws_iam_policy_document" "workload_irsa_assume" {
  for_each = local.workload_service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${each.key}"]
    }
  }
}

data "aws_iam_policy_document" "addon_irsa_assume" {
  for_each = toset(["aws-load-balancer-controller"])

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:${each.key}"]
    }
  }
}

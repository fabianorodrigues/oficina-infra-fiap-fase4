resource "aws_iam_role" "eks_cluster" {
  provider = aws.iam

  name = "${local.cluster_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_38:Public EKS API endpoint is required for GitHub-hosted runners; access remains IAM/Kubernetes-authorized.
  #checkov:skip=CKV_AWS_39:Private endpoint is enabled; public endpoint is retained for GitHub-hosted runner operations.
  #checkov:skip=CKV_AWS_58:EKS 1.28+ encrypts Kubernetes API data by default; explicit lower versions are blocked by platform config validation.

  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = trimspace(local.official.cluster.kubernetesVersion) == "" ? null : local.official.cluster.kubernetesVersion

  enabled_cluster_log_types = var.cluster_enabled_log_types

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = [data.aws_ssm_parameter.private_subnet_1.value, data.aws_ssm_parameter.private_subnet_2.value]
    endpoint_public_access  = local.official.cluster.endpointPublicAccess
    endpoint_private_access = local.official.cluster.endpointPrivateAccess
    public_access_cidrs     = local.official.cluster.publicAccessCidrs
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "kubernetes_namespace" "oficina" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/name"       = local.namespace
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [aws_eks_node_group.this]
}

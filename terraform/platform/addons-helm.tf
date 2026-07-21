resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = trimspace(var.load_balancer_controller_chart_version) == "" ? null : var.load_balancer_controller_chart_version
  namespace        = "kube-system"
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true

  values = [
    templatefile("${path.module}/../../deploy/platform/aws-load-balancer-controller/values.yaml", {
      cluster_name = local.cluster_name
      region       = var.aws_region
      vpc_id       = data.aws_ssm_parameter.vpc_id.value
    })
  ]

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.load_balancer_controller,
    kubernetes_service_account.load_balancer_controller
  ]
}

resource "helm_release" "secrets_store_csi_driver" {
  name             = "secrets-store-csi-driver"
  repository       = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart            = "secrets-store-csi-driver"
  version          = trimspace(var.secrets_store_csi_driver_chart_version) == "" ? null : var.secrets_store_csi_driver_chart_version
  namespace        = "kube-system"
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true

  values = [file("${path.module}/../../deploy/platform/secrets-store-csi-driver/values.yaml")]

  depends_on = [aws_eks_node_group.this]
}

resource "helm_release" "ascp" {
  name             = "secrets-store-csi-driver-provider-aws"
  repository       = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart            = "secrets-store-csi-driver-provider-aws"
  version          = trimspace(var.ascp_chart_version) == "" ? null : var.ascp_chart_version
  namespace        = "kube-system"
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true

  values = [file("${path.module}/../../deploy/platform/ascp/values.yaml")]

  depends_on = [helm_release.secrets_store_csi_driver]
}

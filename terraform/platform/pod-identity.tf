resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.workload_mode == "pod-identity" ? local.workload_service_accounts : {}

  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.namespace
  service_account = each.key
  role_arn        = local.workload_role_arn_by_service_account[each.key]

  depends_on = [
    aws_eks_addon.managed,
    kubernetes_service_account.workload
  ]
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  count = local.workload_mode == "pod-identity" ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = kubernetes_service_account.load_balancer_controller.metadata[0].name
  role_arn        = local.load_balancer_controller_role_arn

  depends_on = [
    aws_eks_addon.managed,
    kubernetes_service_account.load_balancer_controller
  ]
}

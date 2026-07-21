resource "kubernetes_service_account" "workload" {
  for_each = local.workload_service_accounts

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.oficina.metadata[0].name
  }
}

resource "kubernetes_service_account" "load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }

  depends_on = [aws_eks_node_group.this]
}

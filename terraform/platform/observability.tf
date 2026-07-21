resource "helm_release" "opentelemetry_collector" {
  count = local.enable_new_relic ? 1 : 0

  name             = "opentelemetry-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = trimspace(var.opentelemetry_collector_chart_version) == "" ? null : var.opentelemetry_collector_chart_version
  namespace        = local.namespace
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true

  values = [
    templatefile("${path.module}/../../deploy/platform/opentelemetry-collector/values.yaml", {
      cluster_name = local.cluster_name
    })
  ]

  depends_on = [
    kubernetes_namespace.oficina,
    helm_release.secrets_store_csi_driver,
    helm_release.ascp
  ]
}

resource "helm_release" "newrelic" {
  count = local.enable_new_relic ? 1 : 0

  name             = "newrelic-bundle"
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  version          = trimspace(var.newrelic_chart_version) == "" ? null : var.newrelic_chart_version
  namespace        = "newrelic"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  wait             = true

  values = [
    templatefile("${path.module}/../../deploy/platform/newrelic/values.yaml", {
      cluster_name = local.cluster_name
      secret_name  = aws_secretsmanager_secret.new_relic.name
    })
  ]

  depends_on = [
    aws_secretsmanager_secret.new_relic,
    helm_release.opentelemetry_collector
  ]
}

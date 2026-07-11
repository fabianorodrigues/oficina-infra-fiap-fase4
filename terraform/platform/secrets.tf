resource "aws_secretsmanager_secret" "new_relic" {
  name        = local.official.observability.newRelicSecretName
  description = "Container for the New Relic license key used by the Oficina platform observability stack. The value is managed outside Terraform."
}

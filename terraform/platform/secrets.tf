resource "aws_secretsmanager_secret" "new_relic" {
  #checkov:skip=CKV_AWS_149:The AWS-managed Secrets Manager key is sufficient for this New Relic license container; no customer-managed KMS key is required.
  #checkov:skip=CKV2_AWS_57:The New Relic license is synced by workflow/script and has no safe automatic rotation target; no placeholder Lambda should be created for scanner compliance.

  name        = local.official.observability.newRelicSecretName
  description = "Container for the New Relic license key used by the Oficina platform observability stack. The value is managed outside Terraform."
}

# Contract assertions evaluated during plan. The authoritative hard gate is
# scripts/validate-entrypoint-config.ps1 (CI, non-zero exit). These checks give
# early plan-time signal and document the invariants.
check "entrypoint_contract" {
  assert {
    condition     = local.entrypoint.api.name == "oficina-api"
    error_message = "config/entrypoint.json api.name must be oficina-api."
  }

  assert {
    condition     = local.entrypoint.api.protocolType == "HTTP"
    error_message = "API protocol must be HTTP (HTTP API v2)."
  }

  assert {
    condition     = local.entrypoint.api.stageName == "$default"
    error_message = "Stage must be $default."
  }

  assert {
    condition     = local.vpc_link_name == "oficina"
    error_message = "VPC Link name must be oficina."
  }

  assert {
    condition     = local.entrypoint.integration.albPayloadFormatVersion == "1.0"
    error_message = "ALB integration payload format must be 1.0."
  }

  assert {
    condition     = local.entrypoint.integration.lambdaPayloadFormatVersion == "2.0"
    error_message = "Lambda integration payload format must be 2.0."
  }

  assert {
    condition     = local.entrypoint.auth.payloadFormatVersion == "2.0" && local.entrypoint.auth.enableSimpleResponses && local.entrypoint.auth.resultTtlSeconds == 0
    error_message = "Authorizer must use payload 2.0, simple responses enabled and TTL 0."
  }

  assert {
    condition     = length([for r in local.routes : r if r.destination == "ALB_HEALTH"]) == 3
    error_message = "Exactly three health routes are required."
  }

  assert {
    condition     = length([for r in local.routes : r if r.destination == "AUTH_LAMBDA"]) >= 1
    error_message = "At least one auth route is required."
  }

  assert {
    condition     = length([for r in local.routes : r if contains(["$default", "ANY /", "ANY /{proxy+}", "ANY /api/{proxy+}"], r.routeKey)]) == 0
    error_message = "No $default route and no catch-all routes are allowed."
  }

  assert {
    condition     = alltrue([for r in local.routes : r.authorizationType == "CUSTOM" ? true : contains(local.entrypoint.publicAllowlist, r.routeKey)])
    error_message = "Every NONE route must be present in publicAllowlist."
  }

  assert {
    condition     = length([for r in local.routes : r if length(regexall("(?i)/(ready|api/internal|api/dev)", r.routeKey)) > 0]) == 0
    error_message = "Internal, dev and readiness routes must not be exposed."
  }
}

locals {
  # Versioned, non-sensitive contract. Everything the stack builds derives from
  # this file plus SSM parameters resolved at plan time.
  entrypoint = jsondecode(file("${path.module}/../../config/entrypoint.json"))
  official   = yamldecode(file("${path.module}/../../config/official.yml"))

  project_name     = local.official.project.name
  academic_project = local.official.project.academicProject

  api_name      = local.entrypoint.api.name
  vpc_link_name = local.entrypoint.vpcLink.name

  routes       = local.entrypoint.routes
  routes_by_id = { for r in local.routes : r.id => r }

  # One private ALB integration per distinct health target (cadastro/estoque/ordens).
  health_targets = toset(local.entrypoint.health.targets)

  # Trusted identity headers overwritten from the authorizer context on protected
  # routes and stripped from client input on public/health routes.
  identity_headers    = local.entrypoint.trustedIdentity.headers
  request_id_header   = local.entrypoint.trustedIdentity.requestIdHeader
  request_id_source   = local.entrypoint.trustedIdentity.requestIdSource
  overwrite_path      = local.entrypoint.integration.overwritePath
  integration_timeout = local.entrypoint.integration.timeoutMilliseconds

  # Protected: overwrite backend path + inject trusted identity + request id.
  protected_request_parameters = merge(
    { "overwrite:path" = local.overwrite_path },
    { for header, source in local.identity_headers : "overwrite:header.${header}" => source },
    { "overwrite:header.${local.request_id_header}" = local.request_id_source },
  )

  # Public: overwrite path + REMOVE any client-sent identity header + request id.
  # remove operations use '' as documented for API Gateway parameter mapping.
  public_request_parameters = merge(
    { "overwrite:path" = local.overwrite_path },
    { for header, source in local.identity_headers : "remove:header.${header}" => "''" },
    { "overwrite:header.${local.request_id_header}" = local.request_id_source },
  )

  # Health: rewrite path to /health, strip client identity, request id. The
  # per-target trusted header is merged in the integration resource.
  health_base_request_parameters = merge(
    { "overwrite:path" = local.entrypoint.health.internalPath },
    { for header, source in local.identity_headers : "remove:header.${header}" => "''" },
    { "overwrite:header.${local.request_id_header}" = local.request_id_source },
  )

  # ALB frontend security group resolution. The AWS Load Balancer Controller may
  # attach a shared backend security group (tagged elbv2.k8s.aws/resource=backend-sg)
  # in addition to the per-LB frontend security group. We add the VPC Link ingress
  # rule only to the frontend group. If auto-detection is ambiguous, the plan fails
  # and var.alb_frontend_security_group_id must be set explicitly.
  alb_frontend_sg_candidates = [
    for id, sg in data.aws_security_group.alb : id
    if lookup(sg.tags, "elbv2.k8s.aws/resource", "") != "backend-sg"
  ]
  alb_frontend_sg_id = (
    var.alb_frontend_security_group_id != "" ? var.alb_frontend_security_group_id :
    length(local.alb_frontend_sg_candidates) == 1 ? local.alb_frontend_sg_candidates[0] : ""
  )

  common_tags = {
    Project         = local.project_name
    AcademicProject = local.academic_project
    ManagedBy       = "terraform"
    Repository      = "oficina-infra-fiap-fase4"
    Component       = "entrypoint"
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# --- Networking (Infra DB / Platform) resolved from SSM ---------------------
data "aws_ssm_parameter" "vpc_id" {
  name = local.entrypoint.vpcLink.vpcIdParameter
}

data "aws_ssm_parameter" "private_subnet_1" {
  name = local.entrypoint.vpcLink.privateSubnet1Parameter
}

data "aws_ssm_parameter" "private_subnet_2" {
  name = local.entrypoint.vpcLink.privateSubnet2Parameter
}

# --- Internal ALB (Ingress stack) resolved from SSM -------------------------
data "aws_ssm_parameter" "alb_arn" {
  name = local.entrypoint.vpcLink.albArnParameter
}

data "aws_ssm_parameter" "alb_listener_arn" {
  name = local.entrypoint.vpcLink.albListenerArnParameter
}

# The listener ARN is used directly as the private integration URI. The ALB
# object is read only to discover its security groups for the VPC Link rule.
data "aws_lb" "internal" {
  arn = data.aws_ssm_parameter.alb_arn.value
}

data "aws_security_group" "alb" {
  for_each = toset(data.aws_lb.internal.security_groups)
  id       = each.value
}

# --- Auth Lambdas (Auth stack) resolved from SSM ----------------------------
# The Auth stack publishes function-name and alias-arn (live). It does not
# publish a bare function ARN, so the integration and authorizer use the alias
# ARN and permissions use function-name + qualifier=live.
data "aws_ssm_parameter" "auth_cpf_alias_arn" {
  name = local.entrypoint.auth.authCpfAliasArnParameter
}

data "aws_ssm_parameter" "auth_cpf_function_name" {
  name = local.entrypoint.auth.authCpfFunctionNameParameter
}

data "aws_ssm_parameter" "authorizer_alias_arn" {
  name = local.entrypoint.auth.authorizerAliasArnParameter
}

data "aws_ssm_parameter" "authorizer_function_name" {
  name = local.entrypoint.auth.authorizerFunctionNameParameter
}

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

# --- Internal ALB (Platform stack) -----------------------------------------
# The platform stack creates the private ALB and listener consumed by the VPC
# Link integration.
data "aws_lb" "internal" {
  name = local.entrypoint.vpcLink.albName
}

data "aws_lb_listener" "internal" {
  load_balancer_arn = data.aws_lb.internal.arn
  port              = 80
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

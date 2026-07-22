resource "aws_security_group" "alb" {
  name        = "${local.project_name}-alb"
  description = "Internal ALB frontend for Oficina ECS services."
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  tags = merge(local.common_tags, { Name = "${local.project_name}-alb" })
}

resource "aws_security_group" "ecs_tasks" {
  #checkov:skip=CKV2_AWS_5:This shared task security group is intentionally published through SSM and attached by service deploys in separate repositories.

  name        = "${local.project_name}-ecs-tasks"
  description = "Shared security group for Oficina ECS Fargate tasks."
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  tags = merge(local.common_tags, { Name = "${local.project_name}-ecs-tasks" })
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to ECS tasks on application port"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.ecs_tasks.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-alb-egress-ecs" })
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.ecs_tasks.id
  description                  = "ECS tasks from internal ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-ecs-ingress-alb" })
}

resource "aws_vpc_security_group_egress_rule" "tasks_all_egress" {
  security_group_id = aws_security_group.ecs_tasks.id
  description       = "ECS tasks egress to AWS APIs, RDS and internal services"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.project_name}-ecs-egress" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_tasks" {
  security_group_id            = data.aws_ssm_parameter.rds_security_group_id.value
  description                  = "SQL Server from Oficina ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
  referenced_security_group_id = aws_security_group.ecs_tasks.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-rds-ingress-ecs" })
}

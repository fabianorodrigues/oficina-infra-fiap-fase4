# Dedicated security group for the API Gateway VPC Link ENIs. It has no ingress
# and a single egress rule to the internal ALB frontend on HTTP 80.
resource "aws_security_group" "vpc_link" {
  name        = "oficina-api-vpc-link"
  description = "oficina API Gateway VPC Link egress to the internal ALB listener"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  tags = merge(local.common_tags, { Name = "oficina-api-vpc-link" })
}

# Egress: VPC Link -> ALB frontend security group, TCP 80 only. No global egress.
resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  description                  = "VPC Link to internal ALB listener HTTP 80"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = local.alb_frontend_sg_id

  tags = merge(local.common_tags, { Name = "oficina-api-vpc-link-egress-alb-80" })

  lifecycle {
    precondition {
      condition     = local.alb_frontend_sg_id != ""
      error_message = "Could not resolve exactly one ALB frontend security group from the internal ALB. Set var.alb_frontend_security_group_id explicitly."
    }
  }
}

# Ingress rule added (standalone, no ownership of the controller-managed SG) to
# the ALB frontend security group: allow only the VPC Link security group on 80.
resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = local.alb_frontend_sg_id
  description                  = "Inbound HTTP 80 from the oficina API Gateway VPC Link"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.vpc_link.id

  tags = merge(local.common_tags, { Name = "oficina-alb-ingress-from-vpc-link-80" })

  lifecycle {
    precondition {
      condition     = local.alb_frontend_sg_id != ""
      error_message = "Could not resolve exactly one ALB frontend security group from the internal ALB. Set var.alb_frontend_security_group_id explicitly."
    }
  }
}

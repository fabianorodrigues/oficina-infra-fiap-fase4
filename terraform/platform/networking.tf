resource "aws_security_group" "alb" {
  name        = "${local.project_name}-alb"
  description = "Internal ALB frontend for the Oficina services."
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  tags = merge(local.common_tags, { Name = "${local.project_name}-alb" })
}

resource "aws_security_group" "k3s_node" {
  name        = "${local.project_name}-k3s-node"
  description = "Security group for the Oficina K3s node."
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  tags = merge(local.common_tags, { Name = "${local.project_name}-k3s-node" })
}

resource "aws_vpc_security_group_egress_rule" "alb_to_node_ports" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to K3s NodePorts"
  ip_protocol                  = "tcp"
  from_port                    = local.node_port_from
  to_port                      = local.node_port_to
  referenced_security_group_id = aws_security_group.k3s_node.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-alb-egress-nodeports" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_k3s_node_http" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP from K3s node for internal service calls"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.k3s_node.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-alb-ingress-k3s-http" })
}

# Unica origem de trafego para a faixa de NodePorts. A instancia fica em subnet
# privada e sem IP publico, portanto os NodePorts nao sao alcancaveis de fora.
resource "aws_vpc_security_group_ingress_rule" "node_ports_from_alb" {
  security_group_id            = aws_security_group.k3s_node.id
  description                  = "K3s NodePorts from the internal ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.node_port_from
  to_port                      = local.node_port_to
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-node-ingress-alb" })
}

resource "aws_vpc_security_group_egress_rule" "node_all_egress" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "K3s node egress to AWS APIs, RDS and container registry"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.project_name}-node-egress" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_node" {
  security_group_id            = data.aws_ssm_parameter.rds_security_group_id.value
  description                  = "SQL Server from the Oficina K3s node"
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
  referenced_security_group_id = aws_security_group.k3s_node.id

  tags = merge(local.common_tags, { Name = "${local.project_name}-rds-ingress-k3s" })
}

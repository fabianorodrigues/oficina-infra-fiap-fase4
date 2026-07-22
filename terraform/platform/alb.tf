resource "aws_lb" "internal" {
  #checkov:skip=CKV_AWS_91:Access logs are intentionally omitted for this low-cost internal ALB; CloudWatch platform metrics remain validated by the observability workflow.
  #checkov:skip=CKV_AWS_150:Deletion protection is intentionally not enabled for the low-cost internal entrypoint; protected resources are guarded by plan checks.
  #checkov:skip=CKV2_AWS_20:This ALB is private behind API Gateway VPC Link, so TLS terminates at the public API edge and internal forwarding stays HTTP.

  name               = local.official.loadBalancer.name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [data.aws_ssm_parameter.private_subnet_1.value, data.aws_ssm_parameter.private_subnet_2.value]

  drop_invalid_header_fields = true
  idle_timeout               = 60

  tags = merge(local.common_tags, { Name = local.official.loadBalancer.name })
}

resource "aws_lb_target_group" "service" {
  #checkov:skip=CKV_AWS_378:Targets receive private VPC traffic from the internal ALB; public TLS is terminated at API Gateway.

  for_each = local.services

  name                 = each.value.target_group_name
  port                 = local.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.aws_ssm_parameter.vpc_id.value
  deregistration_delay = local.official.loadBalancer.deregistrationDelaySeconds

  health_check {
    enabled             = true
    path                = local.official.loadBalancer.healthPath
    matcher             = "200"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = each.value.target_group_name })
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:This listener is internal only; public HTTPS is handled by API Gateway before traffic enters the VPC Link.
  #checkov:skip=CKV_AWS_103:TLS policies are not applicable to the intentionally HTTP-only internal listener.

  load_balancer_arn = aws_lb.internal.arn
  port              = local.official.loadBalancer.listenerPort
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"Not Found\"}"
      status_code  = "404"
    }
  }

  tags = merge(local.common_tags, { Name = "${local.official.loadBalancer.name}-http" })
}

resource "aws_lb_listener_rule" "service_paths" {
  for_each = local.service_path_rules

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.value.service_key].arn
  }

  condition {
    path_pattern {
      values = [each.value.path_pattern]
    }
  }
}

resource "aws_lb_listener_rule" "health" {
  for_each = local.services

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.priority_base + 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }

  condition {
    path_pattern {
      values = [local.official.loadBalancer.healthPath]
    }
  }

  condition {
    http_header {
      http_header_name = "x-oficina-health-target"
      values           = [each.value.health_target]
    }
  }
}

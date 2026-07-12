locals {
  queue_arn_by_key = {
    estoque_comandos     = aws_sqs_queue.main["estoque_comandos"].arn
    estoque_comandos_dlq = aws_sqs_queue.dlq["estoque_comandos"].arn
    ordens_eventos       = aws_sqs_queue.main["ordens_eventos"].arn
    ordens_eventos_dlq   = aws_sqs_queue.dlq["ordens_eventos"].arn
  }

  secret_arn_by_name = merge(
    { for key, secret in data.aws_secretsmanager_secret.sql : local.secret_names[key] => secret.arn },
    { (local.official.observability.newRelicSecretName) = aws_secretsmanager_secret.new_relic.arn },
    { (local.resource_contract.inputs.rdsMasterSecretArn) = data.aws_ssm_parameter.rds_master_secret_arn.value }
  )
}

data "aws_iam_policy_document" "workload_pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "workload_permissions" {
  for_each = local.workload_service_accounts

  dynamic "statement" {
    for_each = length(each.value.secret_names) > 0 ? [1] : []

    content {
      sid       = "ReadExpectedSecrets"
      actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
      resources = [for name in each.value.secret_names : local.secret_arn_by_name[name]]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.sqs_receive) > 0 ? [1] : []

    content {
      sid = "ReceiveQueues"
      actions = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ]
      resources = [for key in each.value.sqs_receive : local.queue_arn_by_key[key]]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.sqs_send) > 0 ? [1] : []

    content {
      sid       = "SendQueues"
      actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      resources = [for key in each.value.sqs_send : local.queue_arn_by_key[key]]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each = local.workload_service_accounts

  name               = "${local.cluster_name}-${each.key}"
  assume_role_policy = local.workload_mode == "pod-identity" ? data.aws_iam_policy_document.workload_pod_identity_assume.json : data.aws_iam_policy_document.workload_irsa_assume[each.key].json
}

resource "aws_iam_policy" "workload" {
  for_each = local.workload_service_accounts

  name   = "${local.cluster_name}-${each.key}"
  policy = data.aws_iam_policy_document.workload_permissions[each.key].json
}

resource "aws_iam_role_policy_attachment" "workload" {
  for_each = local.workload_service_accounts

  role       = aws_iam_role.workload[each.key].name
  policy_arn = aws_iam_policy.workload[each.key].arn
}

resource "kubernetes_service_account" "workload" {
  for_each = local.workload_service_accounts

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.oficina.metadata[0].name
    annotations = local.workload_mode == "irsa" ? {
      "eks.amazonaws.com/role-arn" = aws_iam_role.workload[each.key].arn
    } : {}
  }
}

data "aws_iam_policy_document" "load_balancer_controller" {
  statement {
    sid = "ControllerCore"
    actions = [
      "iam:CreateServiceLinkedRole",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth"
    ]
    resources = ["*"]
  }

  statement {
    sid = "ControllerManagedResources"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:DeleteRule"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${local.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = local.workload_mode == "pod-identity" ? data.aws_iam_policy_document.workload_pod_identity_assume.json : data.aws_iam_policy_document.addon_irsa_assume["aws-load-balancer-controller"].json
}

resource "aws_iam_policy" "load_balancer_controller" {
  name   = "${local.cluster_name}-aws-load-balancer-controller"
  policy = data.aws_iam_policy_document.load_balancer_controller.json
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "kubernetes_service_account" "load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = local.workload_mode == "irsa" ? {
      "eks.amazonaws.com/role-arn" = aws_iam_role.load_balancer_controller.arn
    } : {}
  }

  depends_on = [aws_eks_node_group.this]
}

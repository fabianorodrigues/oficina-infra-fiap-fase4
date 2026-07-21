resource "aws_ssm_parameter" "outputs" {
  #checkov:skip=CKV2_AWS_34:These SSM parameters publish non-sensitive technical outputs only (names, ARNs, IDs, endpoints, and URLs); keep String so consumers do not require decryption.

  for_each = {
    (local.resource_contract.outputs.clusterName)            = aws_ecs_cluster.this.name
    (local.resource_contract.outputs.clusterArn)             = aws_ecs_cluster.this.arn
    (local.resource_contract.outputs.ecsTaskSecurityGroupId) = aws_security_group.ecs_tasks.id

    (local.resource_contract.outputs.albName)            = aws_lb.internal.name
    (local.resource_contract.outputs.albArn)             = aws_lb.internal.arn
    (local.resource_contract.outputs.albDnsName)         = aws_lb.internal.dns_name
    (local.resource_contract.outputs.albSecurityGroupId) = aws_security_group.alb.id
    (local.resource_contract.outputs.albListenerArn)     = aws_lb_listener.http.arn

    (local.resource_contract.outputs.cadastroTargetGroupArn) = aws_lb_target_group.service["cadastro"].arn
    (local.resource_contract.outputs.estoqueTargetGroupArn)  = aws_lb_target_group.service["estoque"].arn
    (local.resource_contract.outputs.ordensTargetGroupArn)   = aws_lb_target_group.service["ordens"].arn

    (local.resource_contract.outputs.cadastroLogGroupName) = aws_cloudwatch_log_group.service["cadastro"].name
    (local.resource_contract.outputs.estoqueLogGroupName)  = aws_cloudwatch_log_group.service["estoque"].name
    (local.resource_contract.outputs.ordensLogGroupName)   = aws_cloudwatch_log_group.service["ordens"].name

    (local.resource_contract.outputs.cadastroEcr)    = aws_ecr_repository.service["cadastro"].repository_url
    (local.resource_contract.outputs.estoqueEcr)     = aws_ecr_repository.service["estoque"].repository_url
    (local.resource_contract.outputs.ordensEcr)      = aws_ecr_repository.service["ordens"].repository_url
    (local.resource_contract.outputs.dbBootstrapEcr) = aws_ecr_repository.service["db_bootstrap"].repository_url

    (local.resource_contract.outputs.estoqueCommandQueueUrl) = aws_sqs_queue.main["estoque_comandos"].url
    (local.resource_contract.outputs.estoqueCommandQueueArn) = aws_sqs_queue.main["estoque_comandos"].arn
    (local.resource_contract.outputs.estoqueCommandDlqUrl)   = aws_sqs_queue.dlq["estoque_comandos"].url
    (local.resource_contract.outputs.estoqueCommandDlqArn)   = aws_sqs_queue.dlq["estoque_comandos"].arn

    (local.resource_contract.outputs.ordensEventQueueUrl) = aws_sqs_queue.main["ordens_eventos"].url
    (local.resource_contract.outputs.ordensEventQueueArn) = aws_sqs_queue.main["ordens_eventos"].arn
    (local.resource_contract.outputs.ordensEventDlqUrl)   = aws_sqs_queue.dlq["ordens_eventos"].url
    (local.resource_contract.outputs.ordensEventDlqArn)   = aws_sqs_queue.dlq["ordens_eventos"].arn
  }

  name  = each.key
  type  = "String"
  value = each.value
}

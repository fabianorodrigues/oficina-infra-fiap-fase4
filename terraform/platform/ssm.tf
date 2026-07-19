resource "aws_ssm_parameter" "outputs" {
  for_each = {
    (local.resource_contract.outputs.clusterName)            = aws_eks_cluster.this.name
    (local.resource_contract.outputs.clusterNamespace)       = kubernetes_namespace.oficina.metadata[0].name
    (local.resource_contract.outputs.clusterArn)             = aws_eks_cluster.this.arn
    (local.resource_contract.outputs.clusterEndpoint)        = aws_eks_cluster.this.endpoint
    (local.resource_contract.outputs.clusterSecurityGroupId) = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id

    (local.resource_contract.outputs.cadastroEcr) = aws_ecr_repository.service["cadastro"].repository_url
    (local.resource_contract.outputs.estoqueEcr)  = aws_ecr_repository.service["estoque"].repository_url
    (local.resource_contract.outputs.ordensEcr)   = aws_ecr_repository.service["ordens"].repository_url

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

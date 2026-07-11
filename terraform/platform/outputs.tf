output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  value = aws_eks_node_group.this.node_group_name
}

output "namespace" {
  value = kubernetes_namespace.oficina.metadata[0].name
}

output "ecr_repository_urls" {
  value = { for key, repo in aws_ecr_repository.service : key => repo.repository_url }
}

output "queue_urls" {
  value = {
    main = { for key, queue in aws_sqs_queue.main : key => queue.url }
    dlq  = { for key, queue in aws_sqs_queue.dlq : key => queue.url }
  }
}

output "queue_arns" {
  value = {
    main = { for key, queue in aws_sqs_queue.main : key => queue.arn }
    dlq  = { for key, queue in aws_sqs_queue.dlq : key => queue.arn }
  }
}

output "workload_role_arns" {
  value = { for key, role in aws_iam_role.workload : key => role.arn }
}

output "new_relic_secret_arn" {
  value = aws_secretsmanager_secret.new_relic.arn
}

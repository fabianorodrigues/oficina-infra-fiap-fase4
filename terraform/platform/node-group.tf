resource "aws_iam_role" "node_group" {
  count = local.use_external_node_group_role ? 0 : 1

  provider = aws.iam

  name = "${local.cluster_name}-node-group"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_group_worker" {
  count = local.use_external_node_group_role ? 0 : 1

  role       = aws_iam_role.node_group[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_group_cni" {
  count = local.use_external_node_group_role ? 0 : 1

  role       = aws_iam_role.node_group[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_group_ecr" {
  count = local.use_external_node_group_role ? 0 : 1

  role       = aws_iam_role.node_group[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.official.nodeGroup.name
  node_role_arn   = local.eks_node_group_role_arn
  subnet_ids      = [data.aws_ssm_parameter.private_subnet_1.value, data.aws_ssm_parameter.private_subnet_2.value]

  capacity_type  = local.official.nodeGroup.capacityType
  disk_size      = local.official.nodeGroup.diskSize
  instance_types = local.official.nodeGroup.instanceTypes

  scaling_config {
    desired_size = local.official.nodeGroup.desiredSize
    min_size     = local.official.nodeGroup.minSize
    max_size     = local.official.nodeGroup.maxSize
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_group_worker,
    aws_iam_role_policy_attachment.node_group_cni,
    aws_iam_role_policy_attachment.node_group_ecr
  ]
}

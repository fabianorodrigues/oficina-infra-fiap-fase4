# K3s single-node em EC2 privada. Sem SSH, sem key pair, sem IP publico e sem
# a porta 6443 exposta: todo o acesso operacional passa por Systems Manager.

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  k3s_config_content = templatefile("${path.module}/k3s-config.yaml.tftpl", {
    node_name = "${local.project_name}-k3s"
  })

  k3s_user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    aws_region     = var.aws_region
    k3s_version    = local.k3s_version
    installer_url  = local.k3s_installer_url
    installer_sha  = local.k3s_installer_sha256
    binary_url     = local.k3s_binary_url
    binary_sha     = local.k3s_binary_sha256
    k3s_config     = local.k3s_config_content
    namespace      = local.namespace
    bootstrap_flag = "/opt/oficina/BOOTSTRAP_COMPLETE"
    namespace_yaml = file("${path.module}/../../k8s/namespace.yaml")
  })
}

resource "aws_instance" "k3s" {
  #checkov:skip=CKV_AWS_126:Detailed monitoring is intentionally disabled; node capacity is validated after every deploy through Systems Manager.
  #checkov:skip=CKV_AWS_88:The node runs in a private subnet without a public IP; this is enforced by associate_public_ip_address = false.

  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.k3s_instance_type
  subnet_id     = data.aws_ssm_parameter.private_subnet_1.value

  vpc_security_group_ids      = [aws_security_group.k3s_node.id]
  associate_public_ip_address = false
  iam_instance_profile        = var.instance_profile_name
  ebs_optimized               = true

  user_data                   = local.k3s_user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Hop limit 2 e o que permite que os Pods alcancem o IMDS e assumam a role
    # da instancia. Sem isso nao ha credencial para SQS, ECR nem Secrets Manager,
    # e a alternativa proibida seria credencial estatica no Pod.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.k3s_root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.common_tags, { Name = "${local.project_name}-k3s-root" })
  }

  lifecycle {
    # A AMI e resolvida pelo parametro publico "latest". Ignorar mudancas evita
    # que a publicacao de uma nova AMI pela AWS recrie o node fora de uma
    # janela controlada; a troca deliberada e feita por taint explicito.
    ignore_changes = [ami]
  }

  tags = merge(local.common_tags, {
    Name = "${local.project_name}-k3s"
    Role = "k3s-server"
  })
}

resource "aws_lb_target_group_attachment" "k3s" {
  for_each = local.services

  target_group_arn = aws_lb_target_group.service[each.key].arn
  target_id        = aws_instance.k3s.id
  port             = each.value.node_port
}

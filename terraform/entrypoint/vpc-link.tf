# VPC Link v2 into the two private subnets. Subnets and security groups are
# immutable: any change forces replacement. There is no destroy pipeline and no
# manual deletion; the AWS Academy reset performs the final cleanup.
resource "aws_apigatewayv2_vpc_link" "this" {
  name               = local.vpc_link_name
  subnet_ids         = [data.aws_ssm_parameter.private_subnet_1.value, data.aws_ssm_parameter.private_subnet_2.value]
  security_group_ids = [aws_security_group.vpc_link.id]

  tags = merge(local.common_tags, { Name = "oficina-api-vpc-link" })
}

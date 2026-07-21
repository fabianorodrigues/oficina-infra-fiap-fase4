data "aws_ssm_parameter" "vpc_id" {
  name = local.resource_contract.inputs.vpcId
}

data "aws_ssm_parameter" "private_subnet_1" {
  name = local.resource_contract.inputs.privateSubnet1
}

data "aws_ssm_parameter" "private_subnet_2" {
  name = local.resource_contract.inputs.privateSubnet2
}

data "aws_ssm_parameter" "rds_security_group_id" {
  name = local.resource_contract.inputs.rdsSecurityGroupId
}

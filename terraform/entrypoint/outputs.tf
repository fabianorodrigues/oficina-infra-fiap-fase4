output "api_id" {
  description = "HTTP API identifier."
  value       = aws_apigatewayv2_api.this.id
}

output "api_name" {
  description = "HTTP API name."
  value       = aws_apigatewayv2_api.this.name
}

output "api_endpoint" {
  description = "Default execute-api endpoint of the HTTP API."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "api_execution_arn" {
  description = "Execution ARN used for Lambda permission source ARNs."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "stage_name" {
  description = "Stage name ($default)."
  value       = aws_apigatewayv2_stage.default.name
}

output "vpc_link_id" {
  description = "VPC Link v2 identifier."
  value       = aws_apigatewayv2_vpc_link.this.id
}

output "vpc_link_status" {
  description = "VPC Link status is asynchronous and not exposed by the resource. Verify AVAILABLE with the deploy workflow polling or scripts/validate-entrypoint.ps1."
  value       = "verify-post-apply"
}

output "authorizer_id" {
  description = "Lambda REQUEST authorizer identifier."
  value       = aws_apigatewayv2_authorizer.jwt.id
}

output "auth_integration_id" {
  description = "Auth CPF Lambda proxy integration identifier."
  value       = aws_apigatewayv2_integration.auth_lambda.id
}

output "alb_integration_ids" {
  description = "Private ALB integration identifiers (protected, public and per health target)."
  value = {
    protected = aws_apigatewayv2_integration.alb_protected.id
    public    = aws_apigatewayv2_integration.alb_public.id
    health    = { for target, integration in aws_apigatewayv2_integration.health : target => integration.id }
  }
}

output "log_group_name" {
  description = "CloudWatch access log group for the HTTP API."
  value       = aws_cloudwatch_log_group.api.name
}

output "vpc_link_security_group_id" {
  description = "Dedicated VPC Link security group identifier."
  value       = aws_security_group.vpc_link.id
}

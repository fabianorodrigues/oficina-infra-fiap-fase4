locals {
  # Map each route id to its integration id based on destination. try() guards
  # the healthTarget attribute, which only exists on ALB_HEALTH routes.
  route_target_integration = {
    for r in local.routes : r.id => (
      r.destination == "ALB_PROTECTED" ? aws_apigatewayv2_integration.alb_protected.id :
      r.destination == "ALB_PUBLIC" ? aws_apigatewayv2_integration.alb_public.id :
      r.destination == "AUTH_LAMBDA" ? aws_apigatewayv2_integration.auth_lambda.id :
      aws_apigatewayv2_integration.health[try(r.healthTarget, tolist(local.health_targets)[0])].id
    )
  }
}

# Routes are declared explicitly from the contract. No $default, no catch-all.
# CUSTOM routes attach the JWT authorizer; NONE routes (auth, health, the public
# acoes-externas) attach none.
resource "aws_apigatewayv2_route" "this" {
  for_each = local.routes_by_id

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value.routeKey
  target             = "integrations/${local.route_target_integration[each.key]}"
  authorization_type = each.value.authorizationType
  authorizer_id      = each.value.authorizationType == "CUSTOM" ? aws_apigatewayv2_authorizer.jwt.id : null
}

# CORS is versioned in config/entrypoint.json and starts disabled. The API works
# for Postman, curl, automated tests and backend callers without CORS. When
# enabled, origins/methods/headers must be explicit; '*' with credentials is
# rejected by the config validator. When enabled, the HTTP API native CORS is
# used, so no manual OPTIONS routes are declared.
locals {
  cors_enabled = try(local.entrypoint.cors.enabled, false)

  cors_configuration = local.cors_enabled ? [{
    allow_origins     = local.entrypoint.cors.allowOrigins
    allow_methods     = local.entrypoint.cors.allowMethods
    allow_headers     = local.entrypoint.cors.allowHeaders
    expose_headers    = local.entrypoint.cors.exposeHeaders
    allow_credentials = local.entrypoint.cors.allowCredentials
    max_age           = local.entrypoint.cors.maxAgeSeconds
  }] : []
}

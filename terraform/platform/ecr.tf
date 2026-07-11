resource "aws_ecr_repository" "service" {
  for_each = local.ecr_repositories

  name                 = each.value
  image_tag_mutability = local.official.ecr.imageTagMutability

  image_scanning_configuration {
    scan_on_push = local.official.ecr.scanOnPush
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the latest ${local.official.ecr.retainedImages} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = local.official.ecr.retainedImages
      }
      action = {
        type = "expire"
      }
    }]
  })
}

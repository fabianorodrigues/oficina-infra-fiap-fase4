resource "aws_sqs_queue" "dlq" {
  for_each = local.sqs_queues

  name                      = each.value.dlq_name
  fifo_queue                = true
  sqs_managed_sse_enabled   = true
  message_retention_seconds = local.official.sqs.dlqRetentionSeconds
}

resource "aws_sqs_queue" "main" {
  for_each = local.sqs_queues

  name                        = each.value.name
  fifo_queue                  = true
  content_based_deduplication = false
  receive_wait_time_seconds   = local.official.sqs.longPollingSeconds
  visibility_timeout_seconds  = local.official.sqs.visibilityTimeoutSeconds
  message_retention_seconds   = local.official.sqs.messageRetentionSeconds
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = local.official.sqs.maxReceiveCount
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.sqs_queues

  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}

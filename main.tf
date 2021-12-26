resource "aws_sns_topic" "topic" {
  name = "${local.prefix}-topic-name"
}

resource "aws_sns_topic_subscription" "email-target" {
  topic_arn = aws_sns_topic.topic.arn
  protocol  = "email"
  endpoint  = var.email
}


data "aws_iam_policy_document" "error-notifier-lambda" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    effect    = "Allow"
    resources = ["*"]
    sid       = "CreateCloudWatchLogs"
  }

  statement {
    actions = [
      "sns:Publish"
    ]
    effect    = "Allow"
    resources = ["${aws_sns_topic.topic.arn}"]
    sid       = "snsarnallow"
  }
}

resource "aws_iam_role" "error_notifier_lambda" {
  name = "${local.prefix}-error-notifier-iam-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "error_notifier" {
  name = "default"
  role = aws_iam_role.error_notifier_lambda.id

  policy = data.aws_iam_policy_document.error-notifier-lambda.json
}
data "archive_file" "error_notifier" {
  type        = "zip"
  source_file = "${path.module}/Code/s3syncnotify.py"
  output_path = "${path.module}/files/s3syncnotify.zip"
}




resource "aws_lambda_function" "s3sync_error_notifier" {
  function_name = var.error_notifier_function_name
  filename      = data.archive_file.error_notifier.output_path
  role          = aws_iam_role.error_notifier_lambda.arn
  timeout       = 60
  handler       = "s3syncnotify.lambda_handler"

  # The filebase64sha256() function is available in Terraform 0.11.12 and later
  # For Terraform 0.11.11 and earlier, use the base64sha256() function and the file() function:
  # source_code_hash = "${base64sha256(file("lambda_function_payload.zip"))}"
  source_code_hash = filebase64sha256("${data.archive_file.error_notifier.output_path}")

  runtime = "python3.7"

  environment {
    variables = {
      snsARN = "${aws_sns_topic.topic.arn}"
    }
  }
}

resource "aws_lambda_permission" "test-app-allow-cloudwatch" {
  statement_id  = "test-app-allow-cloudwatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3sync_error_notifier.arn
  principal     = "logs.${data.aws_region.current.name}.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.test_lambda.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "test_lambdafunction_logfilter" {
  name            = "test_lambdafunction_logfilter"
  log_group_name  = aws_cloudwatch_log_group.test_lambda.name
  filter_pattern  = "?AccessDenied ?error ?fatal ?ERROR"
  destination_arn = aws_lambda_function.s3sync_error_notifier.arn

  depends_on = [aws_cloudwatch_log_group.test_lambda,aws_lambda_permission.test-app-allow-cloudwatch]
  }
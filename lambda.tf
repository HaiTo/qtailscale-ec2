locals {
  lambda_function_name = "${var.name}-start"
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = var.log_retention_days
}

# ---------- IAM (Lambda role) ----------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = local.lambda_function_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "StartExitNodeOnly"
    actions   = ["ec2:StartInstances"]
    resources = [aws_instance.exit_node.arn]
  }

  statement {
    sid       = "ReadShortcutToken"
    actions   = ["ssm:GetParameter"]
    resources = ["${local.ssm_parameter_arn_prefix}${var.shortcut_token_parameter_name}"]
  }

  # Terraform creates the log group, so CreateLogGroup is not granted
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "start-exit-node"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ---------- Lambda ----------

resource "aws_lambda_function" "start" {
  function_name = local.lambda_function_name
  role          = aws_iam_role.lambda.arn

  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "handler.handler"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  # Caps how many invocations can run at once, even under brute force or spam
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      INSTANCE_ID          = aws_instance.exit_node.id
      TOKEN_PARAMETER_NAME = var.shortcut_token_parameter_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

# Authentication is the token check inside the handler.
# With AuthType=NONE the provider adds the public resource policy automatically
resource "aws_lambda_function_url" "start" {
  function_name      = aws_lambda_function.start.function_name
  authorization_type = "NONE"
}

data "archive_file" "slack_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/slack_commands.py"
  output_path = "${path.module}/lambda/slack_commands.zip"
}

resource "aws_iam_role" "slack_lambda" {
  name = "${var.project_name}-${var.environment}-slack-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "slack_lambda_policy" {
  name = "slack-lambda-policy"
  role = aws_iam_role.slack_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:UpdateAutoScalingGroup"]
        Resource = aws_autoscaling_group.staging.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.slack_signing_secret_name}*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-${var.environment}-slack-commands*"
      }
    ]
  })
}

resource "aws_lambda_function" "slack_commands" {
  function_name    = "${var.project_name}-${var.environment}-slack-commands"
  filename         = data.archive_file.slack_lambda.output_path
  source_code_hash = data.archive_file.slack_lambda.output_base64sha256
  handler          = "slack_commands.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.slack_lambda.arn
  timeout          = 10

  environment {
    variables = {
      ASG_NAME                  = aws_autoscaling_group.staging.name
      SLACK_SIGNING_SECRET_NAME = var.slack_signing_secret_name
    }
  }

  tags = var.tags
}

# --- Cheap HTTP API (not REST API) ------------------------------------------
resource "aws_apigatewayv2_api" "slack" {
  name          = "${var.project_name}-${var.environment}-slack-commands"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "slack" {
  api_id                 = aws_apigatewayv2_api.slack.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.slack_commands.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack" {
  api_id    = aws_apigatewayv2_api.slack.id
  route_key = "POST /slack/commands"
  target    = "integrations/${aws_apigatewayv2_integration.slack.id}"
}

resource "aws_apigatewayv2_stage" "slack" {
  api_id      = aws_apigatewayv2_api.slack.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_commands.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack.execution_arn}/*/*"
}

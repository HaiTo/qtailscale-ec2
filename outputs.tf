output "function_url" {
  description = "URL the iPhone shortcut sends its POST request to."
  value       = aws_lambda_function_url.start.function_url
}

output "token_header_name" {
  description = "Request header that carries the token."
  value       = "X-Auth-Token"
}

output "instance_id" {
  description = "EC2 instance ID of the exit node."
  value       = aws_instance.exit_node.id
}

output "lambda_log_group" {
  description = "Name of the Lambda log group."
  value       = aws_cloudwatch_log_group.lambda.name
}

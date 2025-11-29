terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket         = "devops-accelerator-platform-tf-state"
    key            = "global/devops-accelerator/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "devops-accelerator-tf-locker"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_s3_bucket" "upload_bucket" {
  bucket        = var.upload_bucket_name
  force_destroy = true
}

resource "aws_lambda_function" "process_uploaded_file" {
  function_name = "process-uploaded-file"
  runtime       = "python3.11"
  handler       = "main.lambda_handler"
  filename      = "${path.module}/../../backend/lambda/process-uploaded-file/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../../backend/lambda/process-uploaded-file/lambda.zip")
  role = aws_iam_role.lambda_exec_role.arn

  environment {
    variables = {
      UPLOAD_BUCKET = aws_s3_bucket.upload_bucket.bucket
      SNS_TOPIC_ARN = aws_sns_topic.devops_accelerator_upload_notify.arn
    }
  }
}

resource "aws_s3_bucket_notification" "lambda_trigger" {
  bucket = aws_s3_bucket.upload_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.process_uploaded_file.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_uploaded_file.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.upload_bucket.arn
}

resource "aws_s3_bucket" "frontend_bucket" {
  bucket        = var.frontend_bucket_name
  force_destroy = true

  tags = {
    Name = "Frontend Hosting Bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend_bucket_public_access" {
  bucket = aws_s3_bucket.frontend_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_cors_configuration" "frontend_cors" {
  bucket = aws_s3_bucket.frontend_bucket.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = ["https://${aws_cloudfront_distribution.frontend_distribution.domain_name}"]
    expose_headers  = []
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_website_configuration" "frontend_bucket_website" {
  bucket = aws_s3_bucket.frontend_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_policy" "frontend_bucket_policy" {
  bucket = aws_s3_bucket.frontend_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_cloudfront_distribution" "frontend_distribution" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class

  origin {
    domain_name = aws_s3_bucket_website_configuration.frontend_bucket_website.website_endpoint
    origin_id   = "S3-Frontend-Origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Frontend-Origin"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "FrontendCDN"
  }

  depends_on = [aws_s3_bucket_policy.frontend_bucket_policy]
}

resource "aws_iam_role" "presign_lambda_role" {
  name = "DevOps-Accelerator-Presign-Lambda-Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "presign_lambda_policy" {
  name = "DevOps-Accelerator-Presign-Lambda-Policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:s3:::${var.upload_bucket_name}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "presign_lambda_attach" {
  role       = aws_iam_role.presign_lambda_role.name
  policy_arn = aws_iam_policy.presign_lambda_policy.arn
}

resource "aws_lambda_function" "presign_lambda" {
  function_name = "DevOps-Accelerator-Presign-Handler"
  role          = aws_iam_role.presign_lambda_role.arn
  handler       = "main.lambda_handler"
  runtime       = "python3.12"
  filename      = "${path.module}/../../backend/lambda/generate-presigned-url/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../../backend/lambda/generate-presigned-url/lambda.zip")

  environment {
    variables = {
      BUCKET_NAME = var.upload_bucket_name
    }
  }
}

resource "aws_apigatewayv2_api" "presign_api" {
  name          = "DevOps-Accelerator-Presign-API"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["OPTIONS", "POST"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "presign_api_integration" {
  api_id             = aws_apigatewayv2_api.presign_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.presign_lambda.invoke_arn
  integration_method = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "presign_route" {
  api_id    = aws_apigatewayv2_api.presign_api.id
  route_key = "POST /generate-presigned-url"
  target    = "integrations/${aws_apigatewayv2_integration.presign_api_integration.id}"
}

resource "aws_cloudwatch_log_group" "apigw_logs" {
  name              = "/aws/apigateway/presign-api"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "presign_stage" {
  api_id      = aws_apigatewayv2_api.presign_api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    data_trace_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId",
      requestTime    = "$context.requestTime",
      httpMethod     = "$context.httpMethod",
      path           = "$context.path",
      status         = "$context.status"
    })
  }
}

resource "aws_lambda_permission" "allow_apigw_invoke_presign" {
  statement_id  = "AllowInvokeFromAPIGatewayPresign"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presign_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.presign_api.execution_arn}/*/*"
}

resource "aws_sns_topic" "devops_accelerator_upload_notify" {
  name = "devops-accelerator-upload-notification-topic"
}

resource "aws_sns_topic_subscription" "devops_accelerator_email_sub" {
  topic_arn = aws_sns_topic.devops_accelerator_upload_notify.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_iam_policy" "devops_accelerator_lambda_sns_policy" {
  name = "devops-accelerator-lambda-sns-publish-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "sns:Publish",
        Resource = aws_sns_topic.devops_accelerator_upload_notify.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sns_policy_attachment" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.devops_accelerator_lambda_sns_policy.arn
}

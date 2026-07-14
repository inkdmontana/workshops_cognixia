terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      workshop   = "full-stack"
      autodelete = "true"
      date       = var.created_date
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Pattern: student-<name>-task-tracker-<random>
  # Example: student-john-smith-task-tracker-a1b2c3d4
  name = "student-${var.student_name}-${var.project_name}-${random_id.suffix.hex}"
}

# ─────────────────────────────────────────────
# S3 — Frontend Hosting
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "frontend" {
  bucket = local.name
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  index_document { suffix = "index.html" }
  error_document { key = "index.html" }
}

# ─────────────────────────────────────────────
# CloudFront — CDN with OAC
# ─────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${local.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
        }
      }
    }]
  })
}

# ─────────────────────────────────────────────
# Lambda — Backend API
# ─────────────────────────────────────────────
# Run build.py before terraform apply to generate backend/lambda.zip
#
# Uses the shared Lambda execution role your instructor pre-created for the
# cohort (no student-managed IAM). Pass its ARN with -var=lambda_role_arn=...

resource "aws_lambda_function" "api" {
  function_name = "student-${var.student_name}-${var.project_name}-api"
  role          = var.lambda_role_arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"
  filename      = "${path.module}/../backend/lambda.zip"
  timeout       = 15

  environment {
    variables = {
      MONGO_HOST = var.mongo_host
      MONGO_PORT = "27017"
    }
  }
}

# ─────────────────────────────────────────────
# API Gateway — HTTP API
# ─────────────────────────────────────────────

resource "aws_apigatewayv2_api" "api" {
  name          = "student-${var.student_name}-${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type"]
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# Terraform Starter Kit: Static Website Hosting on AWS (S3 + CloudFront)

# This creates:
# - an S3 bucket for hosting static files
# - a CloudFront distribution to serve the site globally
# - (Optional) Route53 DNS setup

provider "aws" {
  region = "us-west-2"
}

# Replace with your domain if using custom domain, or leave as "chatbot-static-site-<your-unique-id>"
variable "bucket_name" {
  default = "chatbot-static-site-example"
}

resource "aws_s3_bucket" "static_site" {
  bucket = var.bucket_name

  website {
    index_document = "index.html"
    error_document = "index.html"
  }

  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "block_public_access" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "allow_public_read" {
  bucket = aws_s3_bucket.static_site.id

  depends_on = [aws_s3_bucket_public_access_block.block_public_access]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.static_site.arn}/*"
      }
    ]
  })
}

resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "chatbot-oac"
  description                       = "OAC for static site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id   = "s3-${aws_s3_bucket.static_site.id}"

    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-${aws_s3_bucket.static_site.id}"

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
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
    Environment = "dev"
  }
}

output "site_url" {
  value = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}


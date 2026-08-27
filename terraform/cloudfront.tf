###############################################################################
# CloudFront distribution in front of the ALB.
#
# Project 1 lists CloudFront as a key service: "Cache static assets, reduce
# latency". Two distinct behaviours are configured to make the caching story
# explicit rather than implied:
#
#   default (*)        -> CachingDisabled. Dynamic HTML must never be cached,
#                         or every user would see the same instance ID.
#   /static/* & assets -> CachingOptimized. Long TTLs at 400+ edge locations.
#
# Getting this split right is the actual skill. A distribution that caches
# everything is worse than no distribution at all.
###############################################################################

resource "aws_cloudfront_distribution" "main" {
  count = var.enable_cloudfront ? 1 : 0

  enabled         = true
  comment         = "${local.name} - edge cache in front of the ALB"
  price_class     = "PriceClass_100" # NA + EU only; cheapest tier
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      # The ALB listener is HTTP only (no ACM certificate without a domain),
      # so CloudFront must speak HTTP to the origin. With a domain this
      # becomes "https-only" and the whole path is encrypted.
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 30
    }
  }

  # ---- Default behaviour: dynamic content, never cached -------------------
  default_cache_behavior {
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policy: CachingDisabled
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # AWS managed policy: AllViewerExceptHostHeader - forwards everything the
    # origin needs while letting CloudFront set Host itself.
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  # ---- Static assets: cached hard at the edge -----------------------------
  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policy: CachingOptimized (1 day default, 1 year max TTL)
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # Uses the default *.cloudfront.net certificate. With a registered domain
    # this becomes an ACM certificate in us-east-1 plus an aliases block.
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }

  tags = { Name = "${local.name}-cdn" }
}

# NOTE ON ORIGIN LOCKDOWN (designed, not deployed)
# As built, the ALB still answers requests that bypass CloudFront. The
# production fix is to have CloudFront add a secret custom header via an
# origin request policy, then add a WAF rule on the ALB that blocks any
# request missing it. The alternative is a security group rule referencing the
# com.amazonaws.global.cloudfront.origin-facing managed prefix list, which
# restricts by IP but not by distribution. Left out here to keep the apply
# fast and the failure surface small.

###############################################################################
# Safe accessors. A `count`-indexed reference such as
# `aws_cloudfront_distribution.main[0]` inside a conditional raises an
# "index out of range" error when the count is 0, because Terraform does not
# reliably short-circuit conditional expressions. The splat form yields an
# empty list instead, which join() turns into "".
###############################################################################

locals {
  cloudfront_domain  = join("", aws_cloudfront_distribution.main[*].domain_name)
  cloudfront_zone_id = join("", aws_cloudfront_distribution.main[*].hosted_zone_id)

  # The URL a user should actually hit.
  public_base_url = var.enable_cloudfront ? "https://${local.cloudfront_domain}" : "http://${aws_lb.main.dns_name}"
}

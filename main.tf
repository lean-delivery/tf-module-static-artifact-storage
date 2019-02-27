provider "aws" {
  region  = "${var.region}"
}

locals {
  vpc_id 		= "${var.vpc_id == "" ? module.vpc.vpc_id : var.vpc_id}"
  tags      = "${map("Environment", "test",
                "Workspace", "${terraform.workspace}",
  )}"
}

module "vpc" {
  source      = "github.com/lean-delivery/tf-module-awscore"
  project     = "${var.project_name}"
  environment = "${var.environment}"
  vpc_cidr    = "${var.vpc_cidr}"
  
  create_route53_zone = "true"
  root_domain         = "${var.root_domain_name}"
}

module "aws-cert" {
  source  = "github.com/lean-delivery/tf-module-aws-acm"
  domain  = "${var.root_domain_name}"
  zone_id = "${module.vpc.route53_zone_id}"

  alternative_domains_count   = 2
  alternative_domains         = ["*.${var.root_domain_name}"]
  # certificate_body            = "${file(var.cert_body_path)}"
  # private_key                 = "${file(var.private_key_path)}"
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "cloudfront origin access identity"
}

resource "aws_s3_bucket" "www_site" {
    bucket          = "${var.s3_bucket_name}"
    acl             = "private"
    force_destroy   = true
    policy = <<EOF
        {
        "Id": "bucket_policy_site",
        "Version": "2012-10-17",
        "Statement": [
            {
            "Sid": "bucket_policy_site_root",
            "Action": ["s3:ListBucket"],
            "Effect": "Allow",
            "Resource": "arn:aws:s3:::${var.s3_bucket_name}",
            "Principal": {"AWS":"${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"}
            },
            {
            "Sid": "bucket_policy_site_all",
            "Action": ["s3:GetObject"],
            "Effect": "Allow",
            "Resource": "arn:aws:s3:::${var.s3_bucket_name}/*",
            "Principal": {"AWS":"${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"}
            }
        ]
    }
    EOF

    website {
        index_document = "index.html"
        error_document = "404.html"
    }
}

resource "aws_cloudfront_distribution" "distribution" {
    enabled = true
    price_class  = "PriceClass_200"
    http_version = "http2"
    aliases = ["${var.root_domain_name}", "www.${var.root_domain_name}"]

    origin {
        origin_id = "origin-busket-${aws_s3_bucket.www_site.id}"
        domain_name = "${aws_s3_bucket.www_site.bucket_regional_domain_name}"

        s3_origin_config {
            origin_access_identity = "${aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path}"
        }
    }

    default_cache_behavior {
        allowed_methods = ["HEAD", "GET", "OPTIONS"]
        cached_methods  = ["HEAD", "GET", "OPTIONS"]
        target_origin_id = "origin-busket-${aws_s3_bucket.www_site.id}"

        min_ttl = 0
        default_ttl = 3600
        max_ttl = 86400
        
        // redirect any HTTP request to HTTPS
        viewer_protocol_policy = "redirect-to-https"
        compress               = true

        forwarded_values {
          query_string = false

          cookies {
            forward = "none"
          }
        }
    }

    restrictions {
        geo_restriction {
        restriction_type = "none"
        }
    }

    // apply WAF
    web_acl_id = "${aws_waf_web_acl.epam_waf_acl.id}"

    viewer_certificate {
        acm_certificate_arn = "${module.aws-cert.certificate_arn}"
        ssl_support_method  = "sni-only"
    }
}

resource "aws_security_group" "default" {
  name        = "Default security group"
  description = "Default security group"
  vpc_id      = "${local.vpc_id}"

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    self            = true
    security_groups = "${var.security_groups}"
  }
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    self            = true
    security_groups = "${var.security_groups}"
  }
}

resource "aws_waf_ipset" "epam_ipset" {
  count = "${length(var.epam_cidr)}"
  name  = "epam_ipset"

  ip_set_descriptors {
    type  = "IPV4"
    value = "${element(var.epam_cidr, count.index)}"
  }
}

resource "aws_waf_rule" "epam_wafrule" {
  count       = "${length(var.epam_cidr)}"
  depends_on  = ["aws_waf_ipset.epam_ipset"]
  name        = "epam_wafrule"
  metric_name = "EpamWafRule"

  predicates {
    data_id = "${aws_waf_ipset.epam_ipset.*.id}"
    negated = false
    type    = "IPMatch"
  }
}

resource "aws_waf_web_acl" "epam_waf_acl" {
  count       = "${length(var.epam_cidr)}"
  depends_on  = ["aws_waf_ipset.epam_ipset", "aws_waf_rule.epam_wafrule"]
  name        = "epam_waf_acl"
  metric_name = "EpamWebACL"

  default_action {
    type = "ALLOW"
  }

  rules {
    action {
      type = "BLOCK"
    }

    priority = 1
    rule_id  = "${aws_waf_rule.epam_wafrule.*.id}"
    type     = "REGULAR"
  }
}
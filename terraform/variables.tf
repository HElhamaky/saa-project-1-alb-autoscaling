variable "aws_region" {
  description = "AWS region for all regional resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix on every resource."
  type        = string
  default     = "saa-capstone"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "demo"
}

variable "owner" {
  description = "Owner tag - put your name here."
  type        = string
  default     = "san"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 leaves room for future subnet tiers."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public (edge) subnets - ALB and NAT Gateway live here."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "Private application subnets - EC2 instances, no direct internet ingress."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "data_subnet_cidrs" {
  description = "Private data subnets - RDS only, no route to the internet at all."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type for the application tier."
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum instances in the Auto Scaling Group (one per AZ for HA)."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum instances - caps blast radius and cost."
  type        = number
  default     = 4
}

variable "asg_desired_capacity" {
  description = "Desired instance count at launch."
  type        = number
  default     = 2
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is the cheapest Multi-AZ capable class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "MySQL engine version."
  type        = string
  default     = "8.0"
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username. The password is generated and stored in Secrets Manager."
  type        = string
  default     = "appadmin"
}

variable "db_multi_az" {
  description = "Multi-AZ deployment. Set false to halve RDS cost if you are only demoing scaling."
  type        = bool
  default     = true
}

variable "enable_cloudfront" {
  description = <<-EOT
    Deploy the CloudFront distribution in front of the ALB.
    NOTE: adds roughly 8 minutes to `terraform apply` and 8 minutes to
    `terraform destroy`. Set false if you are tight on time - the design is
    still documented in the README.
  EOT
  type        = bool
  default     = true
}

variable "domain_name" {
  description = <<-EOT
    Optional. A domain you already have a PUBLIC hosted zone for in Route 53.
    When set, Terraform creates an alias record pointing at the ALB plus a
    Route 53 health check. Leave "" to skip - the app is then reached on the
    ALB's own DNS name.
  EOT
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for domain_name. Required only if domain_name is set."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications. Leave empty to skip the subscription."
  type        = string
  default     = ""
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes from a single IP before the rate-based rule blocks it."
  type        = number
  default     = 500
}

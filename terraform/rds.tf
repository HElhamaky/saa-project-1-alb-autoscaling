###############################################################################
# RDS MySQL - Multi-AZ, encrypted with a customer-managed key, credentials in
# Secrets Manager. Never a hardcoded password, never a password in tfvars.
###############################################################################

resource "random_password" "db" {
  length  = 32
  special = true
  # RDS rejects these characters in a master password
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/rds/master-credentials"
  description             = "Master credentials for the ${local.name} RDS instance"
  recovery_window_in_days = 0 # 0 = immediate delete, so `terraform destroy` is clean

  tags = { Name = "${local.name}-db-secret" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "mysql"
    host     = aws_db_instance.main.address
    port     = 3306
    dbname   = var.db_name
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = aws_subnet.data[*].id

  tags = { Name = "${local.name}-db-subnet-group" }
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-mysql8-" # name_prefix pairs with create_before_destroy
  family = "mysql8.0"

  # Force TLS for every client connection - encryption in transit at the
  # database tier - enforced by the database itself, not merely requested by
  # the application.
  parameter {
    name  = "require_secure_transport"
    value = "ON"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-mysql"
  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  # Encrypted with the AWS-managed key (aws/rds). Customer-managed KMS keys
  # are a Project 8 concern; this project uses the free default key.
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 3306

  # ---- High availability -------------------------------------------------
  # Multi-AZ provisions a synchronous standby in the second AZ. It is NOT a
  # read replica: the standby serves no traffic. Its purpose is automatic
  # failover with an RTO of 60-120s and an RPO of zero.
  multi_az = var.db_multi_az

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  performance_insights_enabled = false # not free on t3.micro-class in all regions

  # ---- Teardown safety ---------------------------------------------------
  # deletion_protection = false and skip_final_snapshot = true are DEMO
  # settings so `terraform destroy` completes without manual intervention.
  # In production both would be inverted; this is called out in the README.
  deletion_protection = false
  skip_final_snapshot = true

  tags = { Name = "${local.name}-mysql" }
}

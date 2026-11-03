# =============================================================================
# IaC 坏配置样本：编号 10 类，每类一个资源（供 tfsec / trivy config 双扫）
# 验收：≥9/10 被扫出，且报告能按 CRITICAL/HIGH 归类
# =============================================================================

# BAD-1 安全组全开（全端口对全网）
resource "aws_security_group" "open" {
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# BAD-2 实例绑定公网 IP
resource "aws_instance" "public_ip" {
  ami                         = "ami-123"
  instance_type               = "t2.micro"
  associate_public_ip_address = true
}

# BAD-3 明文数据库口令（variable 默认值硬编码）
variable "db_password" {
  type    = string
  default = "super-secret-password-123"
}

# BAD-4 provider 硬编码 AK/SK（凭证入库）
provider "aws" {
  region     = "us-east-1"
  access_key = "AKIAIOSFODNN7EXAMPLE"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
}

# BAD-5 S3 公网访问阻断被显式关闭
resource "aws_s3_bucket" "public" {
  bucket = "my-public-bucket"
}

resource "aws_s3_bucket_public_access_block" "off" {
  bucket              = aws_s3_bucket.public.id
  block_public_acls   = false
  block_public_policy = false
}

# BAD-6 EBS 卷未加密
resource "aws_ebs_volume" "unencrypted" {
  availability_zone = "us-east-1a"
  size              = 10
}

# BAD-7 S3 桶未启用静态加密（也无版本化）
resource "aws_s3_bucket_server_side_encryption_configuration" "missing" {
  count = 0 # 故意不生效：声明了但 count=0，桶裸奔
  bucket = aws_s3_bucket.public.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# BAD-8 过期 TLS 策略（TLS 1.0/1.1 时代策略）
resource "aws_lb_listener" "legacy_tls" {
  load_balancer_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/demo/abc"
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-0-2015-04"
  certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/demo"
}

# BAD-9 RDS 存储未加密
resource "aws_db_instance" "unencrypted" {
  identifier        = "lab-db"
  engine            = "mysql"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  username          = "admin"
  password          = var.db_password
}

# BAD-10 IMDSv1（可被 SSRF 利用窃取凭证）
resource "aws_instance" "imds_v1" {
  ami           = "ami-123"
  instance_type = "t2.micro"
  metadata_options {
    http_tokens = "optional"
  }
}

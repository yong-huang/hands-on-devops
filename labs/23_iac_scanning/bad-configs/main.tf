# 故意包含 10 种坏配置供扫描器检出
resource "aws_security_group" "open" {
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "public_ip" {
  ami           = "ami-123"
  instance_type = "t2.micro"
  associate_public_ip_address = true
}

variable "db_password" {
  type    = string
  default = "super-secret-password-123"
}

resource "aws_s3_bucket" "public" {
  bucket = "my-public-bucket"
}

resource "aws_s3_bucket_public_access_block" "off" {
  bucket                  = aws_s3_bucket.public.id
  block_public_acls       = false
  block_public_policy     = false
}

resource "aws_ebs_volume" "unencrypted" {
  availability_zone = "us-east-1a"
  size              = 10
}

provider "aws" {
  region = "us-east-1"
  access_key = "AKIAIOSFODNN7EXAMPLE"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
}

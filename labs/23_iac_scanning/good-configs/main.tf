# 合规样本：tfsec 零发现（description / 加密 / IMDSv2 一个不能少）
resource "aws_security_group" "restricted" {
  name        = "restricted-sg"
  description = "restrict ingress to 443 from corp cidr"

  ingress {
    description = "https from corp"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
}

resource "aws_instance" "private" {
  ami           = "ami-123"
  instance_type = "t2.micro"

  root_block_device {
    encrypted = true
  }

  metadata_options {
    http_tokens = "required"
  }
}

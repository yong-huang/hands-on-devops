resource "aws_security_group" "restricted" {
  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
}

resource "aws_instance" "private" {
  ami           = "ami-123"
  instance_type = "t2.micro"
}

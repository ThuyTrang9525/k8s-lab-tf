# -------------------------------------------------------------
# SECURITY CONFIGURATION: SECURITY GROUPS
# -------------------------------------------------------------

resource "aws_security_group" "alb_sg" {
  name        = "minikube-alb-sg"
  description = "Allows HTTP traffic from the Internet to the ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "HTTP from Internet"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "minikube-alb-sg"
  }
}

resource "aws_security_group" "ec2_sg" {
  name        = "minikube-ec2-sg"
  description = "Allows SSH and NodePort traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "SSH from Internet"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description     = "NodePort from ALB"
    from_port       = 30080
    to_port         = 30080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "minikube-ec2-sg"
  }
}
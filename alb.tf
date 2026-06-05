# -------------------------------------------------------------
# APPLICATION LOAD BALANCER (ALB) CONFIGURATION
# -------------------------------------------------------------

resource "aws_lb" "external_alb" {
  name               = "minikube-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb_sg.id
  ]

  subnets = [
    data.aws_subnets.default.ids[0],
    data.aws_subnets.default.ids[1]
  ]

  tags = {
    Name = "minikube-alb"
  }
}

resource "aws_lb_target_group" "ec2_target_group" {
  name        = "minikube-tg"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 20
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "minikube-target-group"
  }
}

resource "aws_lb_target_group_attachment" "register_ec2" {
  target_group_arn = aws_lb_target_group.ec2_target_group.arn
  target_id        = aws_instance.minikube_node.id
  port             = 30080
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.external_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_target_group.arn
  }
}
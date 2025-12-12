provider "aws" {
  region = "ap-south-1"
}

# ----------------------------
# VPC & Subnets
# ----------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ----------------------------
# ALB Security Group
# ----------------------------
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------------------
# EC2 Security Group
# ----------------------------
resource "aws_security_group" "web_sg" {
  name        = "web-sg"
  description = "Allow ALB + SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Allow ALB to EC2"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------------------
# USER DATA SCRIPT (Amazon Linux 2023)
# ----------------------------
locals {
  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y nginx git

    systemctl enable nginx
    systemctl start nginx

    WEB_DIR="/usr/share/nginx/html"
    rm -rf $WEB_DIR/*

    git clone https://github.com/Jirage/static-website-project.git /tmp/site
    cp -r /tmp/site/* $WEB_DIR/
    chown -R nginx:nginx $WEB_DIR/

    echo "OK" > /usr/share/nginx/html/health
  EOF
}

# ----------------------------
# Launch Template (AMI FIXED)
# ----------------------------
resource "aws_launch_template" "web_lt" {
  name_prefix   = "web-lt-"
  image_id      = "ami-00ca570c1b6d79f36"   # 🔥 Direct AMI ID (Amazon Linux 2023)
  instance_type = "t2.micro"

  key_name = "Aj"

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = base64encode(local.user_data)
}

# ----------------------------
# Target Group
# ----------------------------
resource "aws_lb_target_group" "tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 20
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# ----------------------------
# Auto Scaling Group
# ----------------------------
resource "aws_autoscaling_group" "asg" {
  name                = "web-asg"
  desired_capacity    = 1
  max_size            = 3
  min_size            = 1
  target_group_arns   = [aws_lb_target_group.tg.arn]
  vpc_zone_identifier = data.aws_subnets.default.ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "web-instance"
    propagate_at_launch = true
  }
}

# ----------------------------
# Auto Scaling Policies
# ----------------------------

# SCALE OUT WHEN CPU > 30%
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale-out-policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "CPU_Above_30"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 30
  evaluation_periods  = 2
  period              = 60
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# SCALE IN WHEN CPU < 20%
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "scale-in-policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "CPU_Below_20"
  comparison_operator = "LessThanThreshold"
  threshold           = 20
  evaluation_periods  = 2
  period              = 60
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# ----------------------------
# ALB
# ----------------------------
resource "aws_lb" "alb" {
  name               = "web-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# ----------------------------
# ALB Listener
# ----------------------------
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_sns_topic" "alerts" {
  name = "asg-alerts"
}

resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "abhishekjirage98@gmail.com"  # your email — subscription must be confirmed
}


# ----------------------------
# OUTPUT
# ----------------------------
output "alb_dns" {
  value = aws_lb.alb.dns_name
}

provider "aws" {
  region = var.region
}

resource "aws_vpc" "mws_vpc" {
  cidr_block                          = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block   = true
  tags = { Name = "mws-vpc" }
}

resource "aws_subnet" "mws_subnet" {
  vpc_id                          = aws_vpc.mws_vpc.id
  cidr_block                      = "10.0.1.0/24"
  assign_ipv6_address_on_creation = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.mws_vpc.ipv6_cidr_block, 8, 0)
  availability_zone               = "us-east-1"
  tags = { Name = "mws-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.mws_vpc.id
}

resource "aws_eip" "eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.eip.id
  subnet_id     = aws_subnet.mws_subnet.id
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.mws_vpc.id
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.mws_subnet.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "sg" {
  vpc_id = aws_vpc.mws_vpc.id
  name   = "mws-sg"

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_instance" "mws_ec2" {
  ami                         = "ami-075b06d55777be7cd"  # Ubuntu 22.04 LTS ap-south-1
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.mws_subnet.id
  associate_public_ip_address = true
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.sg.id]

  user_data = file("userdata.sh")

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    throughput  = 135
  }

  tags = {
    Name = "mws-ec2"
  }
}

resource "aws_cloudwatch_metric_alarm" "ebs_alarm" {
  alarm_name          = "ebs-usage-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "VolumeConsumedReadWriteOps"
  namespace           = "AWS/EBS"
  period              = 300
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "Alarm if EBS usage exceeds 20%"
  actions_enabled     = true
  alarm_actions       = [aws_sns_topic.topic.arn]
  dimensions = {
    VolumeId = aws_instance.mws_ec2.root_block_device[0].volume_id
  }
}

resource "aws_cloudwatch_metric_alarm" "ram_alarm" {
  alarm_name          = "ram-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Alarm when RAM usage > 80%"
  actions_enabled     = true
  alarm_actions       = [aws_sns_topic.topic.arn]
  dimensions = {
    InstanceId = aws_instance.mws_ec2.id
  }
}

resource "aws_sns_topic" "topic" {
  name = "mws-alert-topic"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.topic.arn
  protocol  = "email"
  endpoint  = var.email
}

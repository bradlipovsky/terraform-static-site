# Terraform ECS Fargate Deployment with VPC, ECR, and ALB

provider "aws" {
  region = "us-west-2"
}

# VPC setup
resource "aws_vpc" "chatbot_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "chatbot-vpc" }
}

resource "aws_subnet" "chatbot_subnet" {
  vpc_id                  = aws_vpc.chatbot_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone = "us-west-2a"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-subnet" }
}

resource "aws_subnet" "chatbot_subnet_2" {
  vpc_id                  = aws_vpc.chatbot_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-west-2b"
  map_public_ip_on_launch = true

  tags = {
    Name = "chatbot-subnet-2"
  }
}

resource "aws_route_table_association" "chatbot_rta_2" {
  subnet_id      = aws_subnet.chatbot_subnet_2.id
  route_table_id = aws_route_table.chatbot_rt.id
}

resource "aws_internet_gateway" "chatbot_igw" {
  vpc_id = aws_vpc.chatbot_vpc.id
  tags = { Name = "chatbot-igw" }
}

resource "aws_route_table" "chatbot_rt" {
  vpc_id = aws_vpc.chatbot_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.chatbot_igw.id
  }
  tags = { Name = "chatbot-rt" }
}

resource "aws_route_table_association" "chatbot_rta" {
  subnet_id      = aws_subnet.chatbot_subnet.id
  route_table_id = aws_route_table.chatbot_rt.id
}

# Security Group for ALB
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP access to ALB"
  vpc_id      = aws_vpc.chatbot_vpc.id

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

# Security Group for ECS
resource "aws_security_group" "chatbot_sg" {
  name        = "chatbot-sg"
  description = "Allow port 8000 from ALB"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECR Repository
resource "aws_ecr_repository" "chatbot_repo" {
  name = "chatbot-backend"
  image_scanning_configuration { scan_on_push = true }
  force_delete = true
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "chatbot" {
  name              = "/ecs/chatbot-backend"
  retention_in_days = 7
}

# IAM Role for ECS Task
resource "aws_iam_role" "task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Cluster
resource "aws_ecs_cluster" "chatbot_cluster" {
  name = "chatbot-ecs-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "chatbot_task" {
  family                   = "chatbot-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "chatbot"
      image     = "${aws_ecr_repository.chatbot_repo.repository_url}:latest"
      essential = true
      portMappings = [{ containerPort = 8000, hostPort = 8000 }],
      environment = [
        {
          name  = "OPENAI_API_KEY"
          value = var.openai_api_key
        },
        {
          name  = "DUMMY_VAR"
          value = "force-revision-${timestamp()}"
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = aws_cloudwatch_log_group.chatbot.name,
          awslogs-region        = "us-west-2",
          awslogs-stream-prefix = "chatbot"
        }
      }
    }
  ])
}

# Load Balancer
resource "aws_lb" "chatbot_alb" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets = [aws_subnet.chatbot_subnet.id, aws_subnet.chatbot_subnet_2.id]
}

resource "aws_lb_target_group" "chatbot_tg" {
  name        = "chatbot-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.chatbot_vpc.id
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "chatbot_listener" {
  load_balancer_arn = aws_lb.chatbot_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
  }
}

# ECS Service
resource "aws_ecs_service" "chatbot_service" {
  name            = "chatbot-service"
  cluster         = aws_ecs_cluster.chatbot_cluster.id
  task_definition = aws_ecs_task_definition.chatbot_task.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.chatbot_subnet.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.chatbot_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
    container_name   = "chatbot"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.chatbot_listener]
}

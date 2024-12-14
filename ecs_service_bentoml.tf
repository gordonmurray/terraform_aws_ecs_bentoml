
data "aws_ami" "ecs_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"] # Match ECS-Optimized AMIs
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  owners = ["amazon"] # AWS official AMIs
}

resource "aws_ecs_cluster_capacity_providers" "bento" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = [
    aws_ecs_capacity_provider.bento.name,
  ]
}

resource "aws_ecs_service" "bentoml" {
  name            = "bentoml"
  cluster         = aws_ecs_cluster.main.arn
  task_definition = aws_ecs_task_definition.bentoml.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.bento.name
    weight            = 1
  }

  # Configure rolling updates
  deployment_minimum_healthy_percent = 0   # Ensure at least X% of tasks are healthy during deployment. Default is 100%
  deployment_maximum_percent         = 200 # Allow double the number of tasks to be running during deployment. Default is 200%
}

resource "aws_ecs_task_definition" "bentoml" {
  family                   = "bentoml"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  cpu                      = "1024" # 1 vCPU
  memory                   = "7168" # 7 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "bentoml"
      image     = "${aws_ecr_repository.repository.repository_url}:bentoml-latest"
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
        }
      ],

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_log_group.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "bentoml"
        }
      },

      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl -f http://localhost:3000/livez || exit 1"
        ]
        interval    = 30 # Run health check every 30 seconds
        timeout     = 5  # Mark as failed if no response within 5 seconds
        retries     = 3  # Mark the container as unhealthy after 3 failed attempts
        startPeriod = 60 # Wait 60 seconds before starting health checks
      }
    }
  ])
}


resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.application_name}-ecs-launch-template"
  image_id      = data.aws_ami.ecs_ami.id
  instance_type = "t3.large" # t3.large has 2 vCPUs and 8GB of memory

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 60
      volume_type = "gp3"
    }
  }

  # Metadata options to enforce IMDSv2
  metadata_options {
    http_tokens                 = "required" # Requires IMDSv2
    http_endpoint               = "enabled"  # Optional: Enable or disable IMDS
    http_put_response_hop_limit = 2          # if the hop limit is 1, the IMDSv2 response does not return because going to the container is considered an additional network hop.
  }

  vpc_security_group_ids = [aws_security_group.ecs_sg.id]

  user_data = base64encode(<<-EOF
  #!/bin/bash

  # Update the package list and install necessary dependencies
  yum update -y
  amazon-linux-extras enable epel
  yum install -y epel-release jq

  # Set cluster name
  echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config

  # Install the SSM Agent
  yum install -y https://s3.amazonaws.com/amazon-ssm-${var.region}/latest/linux_amd64/amazon-ssm-agent.rpm
  systemctl enable amazon-ssm-agent
  systemctl start amazon-ssm-agent

EOF
  )


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.application_name}-ecs-instance"
    }
  }
}

resource "aws_autoscaling_group" "ecs" {
  name                = "${var.application_name}-ecs-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  desired_capacity    = 1
  max_size            = 3
  min_size            = 1

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  target_group_arns = [
    aws_lb_target_group.bentoml.arn
  ]

  tag {
    key                 = "Name"
    value               = "${var.application_name}-ecs-instance"
    propagate_at_launch = true
  }
}

resource "aws_ecs_capacity_provider" "bento" {
  name = "${var.application_name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 80 # 80% of the capacity provider so that the ASG can scale in and out. Default is 100
      maximum_scaling_step_size = 10 # Maximum number of tasks to scale out or in at once. Default is 100. Step size should match or exceed the number of tasks needed.
      minimum_scaling_step_size = 1  # Minimum number of tasks to scale out or in at once. Default is 1
    }
  }
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bentoml.arn
  }
}

resource "aws_lb_target_group" "bentoml" {
  name        = "bentoml-target-group"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "instance"

  health_check {
    path                = "/livez" # Bentoml health check endpoint
    port                = "3000"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb" "main" {
  name                       = "${var.application_name}-ecs-load-balancer"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.lb_sg.id]
  subnets                    = aws_subnet.public[*].id
  enable_deletion_protection = false
  drop_invalid_header_fields = true
}

resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/bentoml"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.flow_logs.arn
}

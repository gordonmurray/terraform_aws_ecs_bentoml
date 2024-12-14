resource "aws_ecs_cluster" "main" {
  name = "${var.application_name}-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

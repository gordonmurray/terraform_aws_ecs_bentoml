resource "aws_kms_key" "flow_logs" {
  description         = "KMS key for VPC Flow Logs"
  enable_key_rotation = true
}

resource "aws_kms_key" "ecr_key" {
  description         = "KMS key for ECR repository encryption"
  enable_key_rotation = true

}

resource "aws_kms_key" "ecs_logs" {
  description         = "KMS key for ECS logs"
  enable_key_rotation = true
}
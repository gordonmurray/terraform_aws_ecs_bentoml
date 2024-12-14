output "load_balancer_address" {
  value     = aws_lb.main.dns_name
}

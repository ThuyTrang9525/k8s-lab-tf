# -------------------------------------------------------------
# TERRAFORM OUTPUTS
# -------------------------------------------------------------

output "alb_dns_name" {
  description = "The public URL to access your K8s Web App"
  value       = "http://${aws_lb.external_alb.dns_name}"
}

output "ec2_public_ip" {
  description = "Public IP of EC2"
  value       = aws_instance.minikube_node.public_ip
}

output "ssh_command" {
  description = "SSH command"
  value       = "ssh -i minikube-key.pem ubuntu@${aws_instance.minikube_node.public_ip}"
}
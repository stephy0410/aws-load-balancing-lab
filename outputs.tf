output "web_url" {
  description = "HTTPS URL of the load-balanced app (self-signed cert — browsers/curl will warn; use curl -k)"
  value       = "https://${aws_lb.this.dns_name}"
}

output "round_robin_check_cmd" {
  description = "Run this a few times (or in a loop) to see the Instance ID/IP alternate between the two EC2s"
  value       = "for i in $(seq 1 10); do curl -sk https://${aws_lb.this.dns_name}/api/whoami; echo; done"
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.this.dns_name
}

output "instance_ids" {
  description = "EC2 instance IDs behind the load balancer"
  value       = aws_instance.web[*].id
}

output "instance_public_ips" {
  description = "Public IPv4 addresses of each EC2 instance (for direct SSH; app traffic should go through the ALB)"
  value       = aws_instance.web[*].public_ip
}

output "instance_private_ips" {
  description = "Private IPv4 addresses of each EC2 instance, as reported by the target group"
  value       = aws_instance.web[*].private_ip
}

output "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22"
  value       = local.ssh_cidr
}

output "key_pair_name" {
  description = "Name of the EC2 key pair Terraform created"
  value       = aws_key_pair.lab.key_name
}

output "ssh_commands" {
  description = "SSH command per instance using your local private key"
  value       = [for ip in aws_instance.web[*].public_ip : "ssh -i ${var.private_key_path} ec2-user@${ip}"]
}

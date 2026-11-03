# Outputs
############################################

output "public_ip" {
  description = "Create an A record in Namecheap: Host 'sonar' -> this IP"
  value       = aws_eip.sonarqube.public_ip
}

output "sonarqube_url" {
  value = "https://${var.domain_name}"
}

output "instance_id" {
  description = "Use this in EC2 console -> Connect -> Session Manager"
  value       = aws_instance.sonarqube.id
}

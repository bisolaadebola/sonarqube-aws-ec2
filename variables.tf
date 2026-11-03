# Variables
############################################

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain_name" {
  description = "FQDN for SonarQube"
  type        = string
  default     = "sonar.bfithub.store"
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt expiry notices"
  type        = string
}

variable "instance_type" {
  description = "SonarQube needs at least 4 GB RAM; t3.large (8 GB) is a safe choice"
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "ssh_key_name" {
  description = "Optional existing EC2 key pair name for SSH. Leave empty to use Session Manager only."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH (only used if ssh_key_name is set), e.g. 203.0.113.10/32"
  type        = string
  default     = "0.0.0.0/32"
}

############################################

############################################
# SonarQube on EC2 with Let's Encrypt (HTTPS)
# Stack: Ubuntu 22.04 + Docker Compose
#        nginx-proxy + acme-companion + SonarQube + PostgreSQL
# Access: AWS Console -> EC2 -> Connect -> Session Manager
############################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

############################################

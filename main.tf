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
# Networking (dedicated VPC + public subnet)
############################################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "sonarqube" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "sonarqube-vpc" }
}

resource "aws_internet_gateway" "sonarqube" {
  vpc_id = aws_vpc.sonarqube.id
  tags   = { Name = "sonarqube-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.sonarqube.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "sonarqube-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.sonarqube.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sonarqube.id
  }

  tags = { Name = "sonarqube-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "sonarqube" {
  name_prefix = "sonarqube-"
  description = "SonarQube HTTP/HTTPS"
  vpc_id      = aws_vpc.sonarqube.id

  # Port 80 must stay open for the Let's Encrypt HTTP-01 challenge and renewals
  ingress {
    description = "HTTP (LetsEncrypt challenge and redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.ssh_key_name != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.ssh_allowed_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "sonarqube-sg" }
}

############################################
# IAM role for AWS Console login (Session Manager)
############################################

resource "aws_iam_role" "sonarqube" {
  name_prefix = "sonarqube-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.sonarqube.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sonarqube" {
  name_prefix = "sonarqube-ec2-"
  role        = aws_iam_role.sonarqube.name
}

############################################
# AMI, DB password, Elastic IP
############################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_eip" "sonarqube" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.sonarqube]
  tags       = { Name = "sonarqube-eip" }
}

############################################
# EC2 instance
############################################

resource "aws_instance" "sonarqube" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.sonarqube.id]
  iam_instance_profile        = aws_iam_instance_profile.sonarqube.name
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee /var/log/sonarqube-setup.log) 2>&1

    export DEBIAN_FRONTEND=noninteractive

    # ---- Kernel settings required by SonarQube's embedded Elasticsearch ----
    cat >/etc/sysctl.d/99-sonarqube.conf <<'SYSCTL'
    vm.max_map_count=524288
    fs.file-max=131072
    SYSCTL
    sysctl --system

    # ---- Docker + Compose ----
    apt-get update -y
    apt-get install -y ca-certificates curl docker.io docker-compose-v2 dnsutils
    systemctl enable --now docker

    # ---- Host directories used by the nginx-proxy / acme-companion bind mounts ----
    mkdir -p /etc/nginx/certs /etc/nginx/vhost.d /usr/share/nginx/html

    # ---- Compose file ----
    mkdir -p /opt/sonarqube
    cat >/opt/sonarqube/docker-compose.yml <<'COMPOSE'
    services:
      # Reverse proxy to SonarQube
      nginx-proxy:
        image: nginxproxy/nginx-proxy:latest
        container_name: nginx-proxy
        labels:
          com.github.nginx-proxy.nginx: "true"
        ports:
          - "80:80"
          - "443:443"
        volumes:
          - /etc/nginx/certs:/etc/nginx/certs:rw
          - /etc/nginx/vhost.d:/etc/nginx/vhost.d
          - /usr/share/nginx/html:/usr/share/nginx/html
          - /var/run/docker.sock:/tmp/docker.sock:ro
        restart: unless-stopped

      # Let's Encrypt companion: generates and renews certificates
      letsencrypt:
        image: nginxproxy/acme-companion:latest
        container_name: nginx-proxy-le
        depends_on:
          - nginx-proxy
        volumes:
          - /etc/nginx/certs:/etc/nginx/certs:rw
          - /etc/nginx/vhost.d:/etc/nginx/vhost.d
          - /usr/share/nginx/html:/usr/share/nginx/html
          - /var/run/docker.sock:/var/run/docker.sock:ro
          - acme:/etc/acme.sh
        environment:
          - NGINX_PROXY_CONTAINER=nginx-proxy
          - DEFAULT_EMAIL=${var.letsencrypt_email}
        restart: unless-stopped

      # SonarQube server
      sonarqube:
        image: sonarqube:community
        container_name: sonarqube
        depends_on:
          - db
        environment:
          SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonar
          SONAR_JDBC_USERNAME: sonar
          SONAR_JDBC_PASSWORD: ${random_password.db.result}
          VIRTUAL_HOST: ${var.domain_name}
          VIRTUAL_PORT: "9000"
          LETSENCRYPT_HOST: ${var.domain_name}
          LETSENCRYPT_EMAIL: ${var.letsencrypt_email}
        expose:
          - "9000"
        volumes:
          - sonarqube_data:/opt/sonarqube/data
          - sonarqube_extensions:/opt/sonarqube/extensions
          - sonarqube_logs:/opt/sonarqube/logs
        restart: unless-stopped

      # PostgreSQL for SonarQube
      db:
        image: postgres:15
        container_name: sonarqube_db
        environment:
          POSTGRES_USER: sonar
          POSTGRES_PASSWORD: ${random_password.db.result}
          POSTGRES_DB: sonar
        volumes:
          - postgresql_data:/var/lib/postgresql/data
        restart: unless-stopped

    volumes:
      sonarqube_data:
      sonarqube_extensions:
      sonarqube_logs:
      postgresql_data:
      acme:
    COMPOSE

    # ---- Wait for DNS to point at this server so Let's Encrypt validation succeeds ----
    for i in $(seq 1 60); do
      RESOLVED=$(dig +short ${var.domain_name} | tail -n1)
      if [ "$RESOLVED" = "${aws_eip.sonarqube.public_ip}" ]; then
        break
      fi
      echo "Waiting for DNS (${var.domain_name} -> ${aws_eip.sonarqube.public_ip}), attempt $i"
      sleep 30
    done

    cd /opt/sonarqube
    docker compose up -d
  EOT

  tags = { Name = "sonarqube-server" }

  # user_data references the EIP address, so it must exist first
  depends_on = [aws_eip.sonarqube]
}

resource "aws_eip_association" "sonarqube" {
  instance_id   = aws_instance.sonarqube.id
  allocation_id = aws_eip.sonarqube.id
}

############################################
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

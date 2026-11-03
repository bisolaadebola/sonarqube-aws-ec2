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

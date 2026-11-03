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

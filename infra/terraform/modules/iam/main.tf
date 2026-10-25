data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ================= APP server: pull image, read its settings =================

resource "aws_iam_role" "app" {
  name               = "${var.name}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-permissions"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# ================= JENKINS server: push images, read/write deploy settings, find servers =================

resource "aws_iam_role" "jenkins" {
  name               = "${var.name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "jenkins" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [var.ecr_repository_arn]
  }
  statement {
    sid       = "ReadSettings"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_arn, "${local.ssm_arn}/*"]
  }
  statement {
    sid       = "RecordDeployedTag"
    actions   = ["ssm:PutParameter"]
    resources = ["${local.ssm_arn}/image_tag"]
  }
  statement {
    sid       = "AnsibleDynamicInventory"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags", "ec2:DescribeRegions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "jenkins-permissions"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins.json
}

# ================= MONITORING server: find targets, read CloudWatch, read SMTP password =================

resource "aws_iam_role" "monitoring" {
  name               = "${var.name}-monitoring-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "monitoring" {
  statement {
    sid       = "PrometheusEc2Discovery"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }
  statement {
    sid = "GrafanaCloudWatch"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "logs:DescribeLogGroups",
      "tag:GetResources",
      "rds:DescribeDBInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "monitoring" {
  name   = "monitoring-permissions"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.monitoring.json
}

# ================= all servers: AWS Systems Manager (emergency shell access, no open port) =================

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = {
    app        = aws_iam_role.app.name
    jenkins    = aws_iam_role.jenkins.name
    monitoring = aws_iam_role.monitoring.name
  }

  role       = each.value
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ================= instance profiles (how an EC2 server "wears" a role) =================

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

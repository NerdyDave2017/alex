# ----------------------------------------------------------------------------
# GitHub Actions OIDC for Alex
#
# The GitHub OIDC identity provider already exists in this AWS account, so we
# look it up with a data source instead of creating it. This module only
# manages the IAM role that the CI/CD pipeline assumes (`AWS_ROLE_ARN` secret
# in `.github/workflows/cicd.yml`) and its policy attachments.
#
# Run once per AWS account:
#   cd terraform/github-oidc
#   terraform init
#   terraform apply -var="github_repository=YOUR_GITHUB_USERNAME/alex"
#
# Or, if you need targeted apply (matches the style your other infra uses):
#
#   terraform apply \
#     -target=aws_iam_role.github_actions \
#     -target=aws_iam_role_policy_attachment.github_lambda \
#     -target=aws_iam_role_policy_attachment.github_s3 \
#     -target=aws_iam_role_policy_attachment.github_apigateway \
#     -target=aws_iam_role_policy_attachment.github_cloudfront \
#     -target=aws_iam_role_policy_attachment.github_iam \
#     -target=aws_iam_role_policy_attachment.github_sagemaker \
#     -target=aws_iam_role_policy_attachment.github_apprunner \
#     -target=aws_iam_role_policy_attachment.github_ecr \
#     -target=aws_iam_role_policy_attachment.github_rds \
#     -target=aws_iam_role_policy.github_additional \
#     -var="github_repository=YOUR_GITHUB_USERNAME/alex"
#
# After apply, copy the `github_actions_role_arn` output into your repo's
# `AWS_ROLE_ARN` secret (Settings → Secrets and variables → Actions).
# ----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ----------------------------------------------------------------------------
# 1. GitHub OIDC identity provider — already exists in this AWS account.
#    Look it up by issuer URL and reuse its ARN in the trust policy below.
#    (If you ever need to (re)create it, swap this data block for the
#    `aws_iam_openid_connect_provider` resource shown in the README.)
# ----------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ----------------------------------------------------------------------------
# 2. IAM role that workflows assume via OIDC
#    Trust policy is restricted to `repo:<owner>/<repo>:*` so only this repo
#    (any branch / PR / tag) can assume it.
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = var.role_name
  description          = "Assumed by GitHub Actions CI/CD via OIDC for the ${var.github_repository} repo"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600

  tags = {
    Project = "alex"
    Purpose = "github-actions-oidc"
  }
}

# ----------------------------------------------------------------------------
# 3. AWS-managed policies for every service the pipeline touches.
#    Each `aws_iam_role_policy_attachment` is named `github_<service>` so it
#    can be referenced individually with `terraform apply -target=...`.
#
#    NOTE: AWS limits managed-policy attachments per role to 10. We keep this
#    section at 9 attachments and inline the remaining services (SQS,
#    Secrets Manager, CloudWatch / Logs) into `github_additional` below.
# ----------------------------------------------------------------------------

# Lambda — every backend service: ingest, api, planner, tagger, reporter,
# charter, retirement, optional scheduler.
resource "aws_iam_role_policy_attachment" "github_lambda" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
}

# S3 — terraform state bucket, vectors bucket, lambda packages bucket,
# frontend bucket, plus snapshot uploads.
resource "aws_iam_role_policy_attachment" "github_s3" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# API Gateway — covers both v1 (REST, ingestion) and v2 (HTTP, frontend API).
resource "aws_iam_role_policy_attachment" "github_apigateway" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
}

# CloudFront — distribution management + cache invalidation after frontend deploy.
resource "aws_iam_role_policy_attachment" "github_cloudfront" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
}

# IAM — Terraform creates execution roles for every Lambda, SageMaker model,
# App Runner service, Aurora cluster, etc. Needs full IAM (or a tightened
# policy scoped to `alex-*` role names).
resource "aws_iam_role_policy_attachment" "github_iam" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

# SageMaker — embedding endpoint, endpoint config, model.
resource "aws_iam_role_policy_attachment" "github_sagemaker" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# App Runner — researcher service create/update/redeploy.
resource "aws_iam_role_policy_attachment" "github_apprunner" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AWSAppRunnerFullAccess"
}

# ECR — repository management + docker push for the researcher image.
resource "aws_iam_role_policy_attachment" "github_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

# RDS — Aurora Serverless v2 cluster lifecycle.
resource "aws_iam_role_policy_attachment" "github_rds" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

# ----------------------------------------------------------------------------
# 4. Inline policy: services with no AWS-managed policy, plus the three
#    (SQS, Secrets Manager, CloudWatch / Logs) that were inlined to keep us
#    under the 10-managed-policies-per-role quota. Inline policies do NOT
#    count toward that quota and are scoped to `alex-*` resources.
# ----------------------------------------------------------------------------

resource "aws_iam_role_policy" "github_additional" {
  name = "alex-cicd-additional"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 Vectors — separate namespace from regular S3, no managed policy yet.
        # Used by ingestion (write) and every agent (query/get).
        Sid    = "S3Vectors"
        Effect = "Allow"
        Action = [
          "s3vectors:CreateBucket",
          "s3vectors:DeleteBucket",
          "s3vectors:GetBucket",
          "s3vectors:ListBuckets",
          "s3vectors:CreateIndex",
          "s3vectors:DeleteIndex",
          "s3vectors:GetIndex",
          "s3vectors:ListIndexes",
          "s3vectors:PutVectors",
          "s3vectors:GetVectors",
          "s3vectors:QueryVectors",
          "s3vectors:DeleteVectors"
        ]
        Resource = "*"
      },
      {
        # RDS Data API — used by backend/database/run_migrations.py + seed_data.py.
        # `AmazonRDSFullAccess` covers cluster lifecycle but not these data-plane calls.
        Sid    = "RDSDataAPI"
        Effect = "Allow"
        Action = [
          "rds-data:ExecuteStatement",
          "rds-data:BatchExecuteStatement",
          "rds-data:BeginTransaction",
          "rds-data:CommitTransaction",
          "rds-data:RollbackTransaction"
        ]
        Resource = "*"
      },
      {
        # EventBridge Scheduler — schedule for the optional researcher scheduler
        # in terraform/4_researcher (`scheduler_enabled = true`).
        Sid    = "EventBridgeScheduler"
        Effect = "Allow"
        Action = [
          "scheduler:CreateSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule",
          "scheduler:GetSchedule",
          "scheduler:ListSchedules",
          "scheduler:TagResource",
          "scheduler:UntagResource"
        ]
        Resource = "*"
      },
      {
        # API Gateway api-key value lookup — the workflow fetches the api_key
        # value to inject as ALEX_API_KEY into the researcher's runtime env.
        # Already covered by AmazonAPIGatewayAdministrator; here for clarity.
        Sid    = "APIGatewayKeyValue"
        Effect = "Allow"
        Action = [
          "apigateway:GET"
        ]
        Resource = "arn:aws:apigateway:*::/apikeys/*"
      },
      {
        # Identity probe — `aws sts get-caller-identity` runs in every job's
        # `setup` action to derive the state bucket name.
        Sid    = "Identity"
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity",
          "iam:GetUser"
        ]
        Resource = "*"
      },
      {
        # SQS — analysis_jobs queue + DLQ in terraform/6_agents.
        # Inlined (instead of attaching AmazonSQSFullAccess) to stay under the
        # 10-managed-policies-per-role quota. Scoped to `alex-*` queues.
        Sid    = "SQS"
        Effect = "Allow"
        Action = ["sqs:*"]
        Resource = [
          "arn:aws:sqs:*:${data.aws_caller_identity.current.account_id}:alex-*"
        ]
      },
      {
        # SQS list/describe actions don't accept a resource ARN; required so
        # the provider can refresh queue state during plan/apply.
        Sid      = "SQSListAndAttributes"
        Effect   = "Allow"
        Action   = ["sqs:ListQueues"]
        Resource = "*"
      },
      {
        # Secrets Manager — `alex-aurora-credentials-*` secret in terraform/5_database.
        # Inlined (instead of attaching SecretsManagerReadWrite) to stay under
        # the managed-policies-per-role quota. Scoped to `alex-*` secrets.
        Sid    = "SecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:TagResource",
          "secretsmanager:UntagResource",
          "secretsmanager:ListSecretVersionIds",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:PutResourcePolicy",
          "secretsmanager:DeleteResourcePolicy"
        ]
        Resource = [
          "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:alex-*"
        ]
      },
      {
        # ListSecrets has no resource-level scoping.
        Sid      = "SecretsManagerList"
        Effect   = "Allow"
        Action   = ["secretsmanager:ListSecrets"]
        Resource = "*"
      },
      {
        # EC2:CreateSecurityGroup — required by terraform/4_researcher.
        Sid    = "EC2CreateSecurityGroup"
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeSubnets",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateTags",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        # CloudWatch dashboards (terraform/8_enterprise) — scoped to `alex-*`.
        # Inlined (instead of attaching CloudWatchFullAccess) to stay under quota.
        Sid    = "CloudWatchDashboards"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetDashboard",
          "cloudwatch:PutDashboard",
          "cloudwatch:DeleteDashboards",
          "cloudwatch:ListDashboards"
        ]
        Resource = [
          "arn:aws:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/alex-*"
        ]
      },
      {
        # CloudWatch metric reads — required by dashboards/alarms refreshes;
        # GetMetricData/Statistics don't support resource-level scoping.
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        # CloudWatch Logs — log groups for every Lambda (`/aws/lambda/alex-*`).
        # Inlined to stay under the managed-policies-per-role quota.
        Sid    = "CloudWatchLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:ListTagsForResource",
          "logs:TagLogGroup",
          "logs:UntagLogGroup"
        ]
        Resource = [
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/alex-*",
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/alex-*:*"
        ]
      },
      {
        # logs:DescribeLogGroups has no resource-level scoping.
        Sid      = "CloudWatchLogsDescribe"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

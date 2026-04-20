# This file creates the S3 bucket and DynamoDB table for Terraform state
# Run this once per AWS account, then remove the file
# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "alex-terraform-state-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "Alex Terraform State Store"
    Environment = "global"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Note: aws_caller_identity.current is already defined in main.tf

output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.id
}
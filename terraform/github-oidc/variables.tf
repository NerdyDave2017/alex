variable "aws_region" {
  description = "AWS region for the IAM resources (IAM is global; this just controls the provider session)."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume this role, in `<owner>/<repo>` form (e.g. `andela-ai/alex`)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in the form `<owner>/<repo>`."
  }
}

variable "role_name" {
  description = "Name of the IAM role assumed via OIDC. Used as the `AWS_ROLE_ARN` secret in GitHub Actions."
  type        = string
  default     = "alex-cicd-deployer"
}

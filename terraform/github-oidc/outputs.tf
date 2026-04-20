output "github_actions_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions. Set this as the `AWS_ROLE_ARN` GitHub repository secret."
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "ARN of the existing GitHub OIDC identity provider (looked up via data source, not managed by this module)."
  value       = data.aws_iam_openid_connect_provider.github.arn
}

output "next_steps" {
  description = "What to do after a successful apply."
  value       = <<-EOT

    ✅ GitHub Actions OIDC role created.

    1. Copy the role ARN into your repository secret:
         gh secret set AWS_ROLE_ARN --body "${aws_iam_role.github_actions.arn}"
       (or paste it into GitHub → Settings → Secrets and variables → Actions)

    2. Remove the old static-key secrets if you had them:
         gh secret delete AWS_ACCESS_KEY_ID
         gh secret delete AWS_SECRET_ACCESS_KEY

    3. Re-run the CI/CD workflow. Every job's setup action will now assume
       ${aws_iam_role.github_actions.arn}
       via OIDC instead of using long-lived keys.
  EOT
}

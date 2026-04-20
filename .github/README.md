# Alex CI/CD

Eight-stage GitHub Actions pipeline that mirrors the `terraform/<n>_<name>/`
folders and the `guides/` walkthrough. Each stage runs only when its own paths
changed — or when an upstream stage's *outputs* actually changed (snapshot diff
in S3) — so a typical PR or push touches the minimum number of jobs.

```
                                     ┌──────────────┐
                                     │ 1. SageMaker │
                                     └──────┬───────┘
                                            │ endpoint name
                          ┌─────────────────┴───────────────────┐
                          ▼                                     ▼
                  ┌──────────────┐                       ┌──────────────┐
                  │ 3. Ingestion │ ──┐                   │ 2. Database  │
                  └──────┬───────┘   │ vector bucket     └──────┬───────┘
       ALEX_API_*  ─────►│           │                          │ aurora arns
                  ┌──────▼───────┐   │                          │
                  │ 4. Researcher│   │                          │
                  └──────────────┘   │                          │
                                     ▼                          ▼
                              ┌──────────────────────────────────┐
                              │ 5. Agents (planner/tagger/…)     │
                              └──────────────┬───────────────────┘
                                             │ sqs queue url
                              ┌──────────────▼───────────────────┐
                              │ 6. API + Frontend infra          │
                              └──────────────┬───────────────────┘
                                             ▼
                              ┌──────────────────────────────────┐
                              │ 7. Frontend assets (S3 + CF)     │
                              └──────────────────────────────────┘

(terraform/8_enterprise — observability dashboards — is intentionally
 excluded from CI for now. Apply it manually when you want it; destroy.yml
 will still tear it down on cleanup.)
```

## Layout

```
.github/
├── workflows/
│   ├── cicd.yml                  # the orchestrator (8 jobs + summary)
│   └── destroy.yml               # manual reverse-order teardown (workflow_dispatch only)
└── actions/
    ├── setup/                    # AWS creds + Terraform + uv/Node
    ├── tf-stage/                 # init / plan -detailed-exitcode / apply / snapshot diff
    ├── tf-destroy/               # init / destroy -auto-approve / snapshot delete
    ├── s3-empty/                 # purge a bucket (incl. versions) before destroy
    ├── lambda-package/           # uv + package_docker.py with per-service caching
    ├── researcher-image/         # docker build/push + App Runner redeploy
    ├── db-migrate/               # run_migrations.py + seed_data.py via Data API
    └── frontend-deploy/          # npm build + s3 sync + CloudFront invalidation
```

## How the cascade works

A downstream job runs when **any** of these are true:

1. Its own paths changed (`dorny/paths-filter@v3`).
2. Shared backend code changed (`backend/pyproject.toml`, `backend/uv.lock`,
  `backend/common/`**) — this rebuilds Lambda zips and re-applies their stages.
3. An upstream stage's outputs **actually** changed. After every `terraform apply`
  the `tf-stage` action writes `terraform output -json` to
   `s3://alex-terraform-state-<accountId>/snapshots/<stage>.outputs.json`.
   The next run downloads the previous snapshot and compares; if the JSON differs
   (or no snapshot exists yet) the action sets `outputs_changed=true`.
4. The CI files themselves changed (`.github/`**) — guarantees pipeline-wide
  smoke runs after a workflow edit.
5. The workflow was dispatched with `full=true`, or the optional `stages`
  subset filter matches.

Plus, every stage uses `terraform plan -detailed-exitcode`, so an `apply` step
only runs (and only writes a new snapshot) when there are real changes — safe
to re-run the workflow with no diffs.

### Filtered outputs

`tf-stage` strips human-facing Terraform outputs from both the `outputs_json`
exposed to downstream jobs **and** the snapshot it writes to S3. By default the
only filtered key is `setup_instructions` — a multiline help string that
contains apostrophes / quotes that previously broke shell parsing in
downstream `read` steps, and that nothing in CI consumes (the same info lives
in `guides/`). Local `terraform output` / `terraform apply` still print the
full set of outputs unchanged. Override per stage with the `exclude_outputs`
input (comma-separated list, empty disables filtering).

## Prerequisites (one-time, done outside CI)

These exist in `[guides/1_permissions.md](../guides/1_permissions.md)` through
`[guides/3_ingestion.md](../guides/3_ingestion.md)` — they need an admin or
console access and aren't safe to bake into a pipeline:

1. IAM groups, policies, and the deploy user the workflow will use.
2. **S3 Vectors** namespace bucket (a different namespace from regular S3 —
  neither Terraform's `aws_s3_bucket` nor the AWS CLI's `s3` commands manage it).
3. An OpenAI API key with access to `OPENAI_MODEL` (default `gpt-4o-mini`).
  The 5 agent Lambdas and the researcher App Runner service all call OpenAI
   directly via LiteLLM (`OPENAI_API_KEY` + `OPENAI_MODEL` env vars).
4. Apply `[terraform/backend-setup](../terraform/backend-setup)` once to create
  the S3 state bucket `alex-terraform-state-<accountId>`. Every CI stage stores
   its `tfstate` and its outputs snapshot in that bucket.

## Required secrets

The pipeline uses **GitHub OIDC** to assume an AWS IAM role — no long-lived
access keys live in the repo. The workflow already sets `id-token: write`
at the top level, and every job calls the `setup` action with `AWS_ROLE_ARN`.


| Secret                          | Purpose                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `AWS_ROLE_ARN`                  | ARN of the IAM role assumed via OIDC (e.g. `arn:aws:iam::123456789012:role/alex-cicd-deployer`)      |
| `OPENAI_API_KEY`                | Injected into researcher + every agent Lambda                                                        |
| `POLYGON_API_KEY`               | Market data for the planner / charter agents                                                         |
| `CLERK_JWKS_URL`                | JWT validation in the API Lambda (stage 6)                                                           |
| `CLERK_ISSUER`                  | Optional, kept for backwards compatibility                                                           |
| `CLERK_PUBLISHABLE_KEY`         | Baked into the Next.js bundle at build time                                                          |
| `LANGFUSE_PUBLIC_KEY` *(opt)*   | Observability                                                                                        |
| `LANGFUSE_SECRET_KEY` *(opt)*   | Observability                                                                                        |
| `LANGFUSE_HOST` *(opt)*         | Observability                                                                                        |
| `AWS_ACCESS_KEY_ID` *(opt)*     | **Fallback only.** Static-key path; the `setup` action uses these only when `AWS_ROLE_ARN` is empty. |
| `AWS_SECRET_ACCESS_KEY` *(opt)* | Fallback only — see above.                                                                           |


### One-time AWS setup for OIDC

1. Create the GitHub OIDC identity provider in your AWS account if it doesn't
  already exist (URL `https://token.actions.githubusercontent.com`, audience
   `sts.amazonaws.com`).
2. Create an IAM role (e.g. `alex-cicd-deployer`) with a trust policy that
  restricts which repo and ref can assume it:
3. Attach a policy to the role with permissions for everything the pipeline
  touches: SageMaker, Lambda, API Gateway, S3, S3 Vectors, ECR, App Runner,
   RDS / RDS Data API, Secrets Manager, IAM (read/role-passing for the resources
   it manages), CloudWatch Logs, CloudFront, SQS, EventBridge Scheduler.
   Most of these line up with the policies listed in
   `[guides/1_permissions.md](../guides/1_permissions.md)`.
4. Set `AWS_ROLE_ARN` as a repository secret to that role's ARN.

## Required vars


| Variable       | Default       | Notes                                    |
| -------------- | ------------- | ---------------------------------------- |
| `AWS_REGION`   | `us-east-1`   | Must match the state bucket region       |
| `OPENAI_MODEL` | `gpt-4o-mini` | LiteLLM model id for researcher + agents |
| `POLYGON_PLAN` | `free`        | `free` or `paid`                         |
| `DB_MIN_ACU`   | `0.5`         | Aurora Serverless v2 minimum capacity    |
| `DB_MAX_ACU`   | `1`           | Aurora Serverless v2 maximum capacity    |


## Triggers


| Event                    | Behaviour                                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `pull_request` to `main` | `terraform plan` only on every eligible stage. No apply, no docker push, no S3 sync.                          |
| `push` to `main`         | Full apply for every eligible stage.                                                                          |
| `workflow_dispatch`      | Manual run. Inputs: `full` (force every stage) and `stages` (comma-separated subset, e.g. `agents,frontend`). |


`concurrency` is grouped per ref with `cancel-in-progress: false` — a deploy
in flight will never be cancelled by a follow-up commit.

## First deploy

Run the workflow manually with `full=true`. That bootstraps every stage in
order, populates the snapshot bucket, and exits clean. Subsequent pushes will
only touch the stages whose paths changed.

## Tearing it all down

`destroy.yml` is the inverse of `cicd.yml` — it runs only via `workflow_dispatch`
and tears down every stage in **reverse** dependency order. Trigger it from
**Actions → Destroy → Run workflow** and type the literal string `destroy`
into the `confirm` input. Anything else aborts before any AWS call.

What it does:


| #   | Stage                    | Pre-destroy step                              |
| --- | ------------------------ | --------------------------------------------- |
| 1   | enterprise (8)           | —                                             |
| 2   | api + frontend infra (7) | empty `alex-frontend-<acct>` S3 bucket        |
| 3   | agents (6)               | empty `alex-lambda-packages-<acct>` S3 bucket |
| 4   | researcher (4)           | — (ECR has `force_delete = true`)             |
| 5   | ingestion (3)            | empty `alex-vectors-<acct>` S3 bucket         |
| 6   | database (5)             | —                                             |
| 7   | sagemaker (2)            | —                                             |


Each stage runs `terraform destroy -auto-approve` and then deletes its
outputs snapshot from `s3://alex-terraform-state-<acct>/snapshots/`.

The `stages` input lets you destroy a subset (comma-separated names from the
table above, e.g. `enterprise,frontend`). Skipped stages are left untouched —
beware that skipping a stage with downstream consumers can leave them broken.

What it deliberately does **not** touch:

- The Terraform state bucket itself (`alex-terraform-state-<acct>`) — that's
a bootstrap resource managed by `terraform/backend-setup/`.
- The GitHub OIDC role + policies (`terraform/github-oidc/`) — destroying
those would lock CI out of AWS. Tear them down by hand once you're
certain you're done.
- The S3 Vectors namespace (managed outside Terraform).

## Local equivalents (for reference / debugging)


| Stage        | Local command                                                                                                                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2 SageMaker  | `cd terraform/2_sagemaker && terraform apply`                                                                                                                |
| 3 Ingestion  | `cd backend/ingest && uv run package.py && cd ../../terraform/3_ingestion && terraform apply`                                                                |
| 4 Researcher | `cd backend/researcher && uv run deploy.py`                                                                                                                  |
| 5 Database   | `cd terraform/5_database && terraform apply && cd ../../backend/database && uv run run_migrations.py`                                                        |
| 6 Agents     | `cd backend/<agent> && uv run package_docker.py` (×5) `&& cd ../../terraform/6_agents && terraform apply`                                                    |
| 7 Frontend   | `cd backend/api && uv run package_docker.py && cd ../../terraform/7_frontend && terraform apply && cd ../../frontend && npm run build && aws s3 sync out/ …` |
| 8 Enterprise | `cd terraform/8_enterprise && terraform apply`                                                                                                               |


## Known limitations / follow-ups

- **OIDC is the default**: `setup/action.yml` prefers `AWS_ROLE_ARN` and only falls back to `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` when the role ARN is empty. To enforce OIDC-only, simply don't set the static-key secrets.
- **Stage 7 remote_state override**: `terraform/7_frontend/main.tf` declares its `data "terraform_remote_state"` blocks with `backend = "local"`. The `tf-stage` action writes a `_ci_remote_state_override.tf` file at run time that switches them to `backend = "s3"`. If you adopt the same pattern locally, change those blocks in `main.tf` directly.
- **Cascade granularity**: the cascade signal is the snapshot diff of the *full* outputs JSON. A future improvement is per-key diffing so a downstream only re-runs when a key it actually consumes changed.
- **Ingest packaging**: `backend/ingest` uses `package.py` (no Docker) per Guide 3; `lambda-package` detects this automatically.
- **Stage 8 dashboards still target Bedrock metrics**: `terraform/8_enterprise/main.tf` queries `AWS/Bedrock` CloudWatch metrics, which will be empty now that the backend calls OpenAI directly. CI passes through the stage's Terraform defaults (`bedrock_region=us-west-2`, `bedrock_model_id=amazon.nova-pro-v1:0`) so `plan` / `apply` still succeed; swapping those widgets to a provider-agnostic source (e.g. LiteLLM / OpenTelemetry metrics via LangFuse) is a follow-up in Terraform, not CI.


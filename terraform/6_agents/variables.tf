variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-west-1"
}

variable "aurora_cluster_arn" {
  description = "ARN of the Aurora cluster from Part 5"
  type        = string
  sensitive   = true
}

variable "aurora_secret_arn" {
  description = "ARN of the Secrets Manager secret from Part 5"
  type        = string
  sensitive   = true
}

variable "vector_bucket" {
  description = "S3 Vectors bucket name from Part 3"
  type        = string
}

variable "openai_model" {
  description = "OpenAI model name for LiteLLM (e.g. gpt-4o-mini)"
  type        = string
  default     = "gpt-4o-mini"
}

variable "sagemaker_endpoint" {
  description = "SageMaker endpoint name from Part 2"
  type        = string
  default     = "alex-embedding-endpoint"
}

variable "polygon_api_key" {
  description = "Polygon.io API key for market data"
  type        = string
}

variable "polygon_plan" {
  description = "Polygon.io plan type (free or paid)"
  type        = string
  default     = "free"
}

# LangFuse observability variables (optional)
variable "langfuse_public_key" {
  description = "LangFuse public key for observability (optional)"
  type        = string
  default     = ""
  sensitive   = false
}

variable "langfuse_secret_key" {
  description = "LangFuse secret key for observability (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "langfuse_host" {
  description = "LangFuse host URL (optional)"
  type        = string
  default     = "https://us.cloud.langfuse.com"
}

# OpenAI API key for LLM calls and OpenAI Agents SDK tracing
variable "openai_api_key" {
  description = "OpenAI API key; injected into every agent Lambda as OPENAI_API_KEY (LiteLLM / OpenAI API)"
  type        = string
  sensitive   = true
}
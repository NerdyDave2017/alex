variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-west-1"
}

variable "openai_api_key" {
  description = "OpenAI API key for the researcher agent"
  type        = string
  sensitive   = true
}

variable "openai_model" {
  description = "OpenAI model name for LiteLLM (e.g. gpt-4o-mini)"
  type        = string
  default     = "gpt-4o-mini"
}

variable "alex_api_endpoint" {
  description = "Alex API endpoint from Part 3"
  type        = string
  sensitive   = true
}

variable "alex_api_key" {
  description = "Alex API key from Part 3"
  type        = string
  sensitive   = true
}

variable "scheduler_enabled" {
  description = "Enable automated research scheduler"
  type        = bool
  default     = false
}
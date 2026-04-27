variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}

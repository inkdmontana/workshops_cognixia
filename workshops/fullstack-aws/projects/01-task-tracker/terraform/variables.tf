variable "student_name" {
  description = "Your name in lowercase with no spaces (e.g. john-smith). Used to identify your resources."

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.student_name))
    error_message = "student_name must be lowercase letters, numbers, and hyphens only (e.g. john-smith)."
  }
}

variable "project_name" {
  description = "Project name — combined with student_name to form resource names"
  default     = "task-tracker"
}

variable "aws_region" {
  default = "us-east-1"
}

variable "mongo_host" {
  description = "EC2 public IP running MongoDB"
}

variable "created_date" {
  description = "Creation date for the `date` tag, format dd-mmm-yyyy (e.g. 12-Jul-2026)."
  type        = string
}

variable "lambda_role_arn" {
  description = "ARN of the shared Lambda execution role your instructor pre-created for the cohort. You don't create your own IAM role."
  type        = string
}

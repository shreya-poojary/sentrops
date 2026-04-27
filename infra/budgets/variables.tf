variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email address that receives budget alert notifications."
  type        = string
}

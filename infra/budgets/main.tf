terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Move to S3 backend in Sprint 1 when the state bucket is provisioned.
  # For now, local state is fine — this config is applied once and rarely changes.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "sentrops"
      ManagedBy   = "terraform"
      Component   = "budgets"
    }
  }
}

# Monthly cost budget with a hard cap at $50 and alerts at $25 and $40.
resource "aws_budgets_budget" "monthly" {
  name         = "sentrops-monthly"
  budget_type  = "COST"
  limit_amount = "50"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alert at 50% ($25) — informational
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Alert at 80% ($40) — investigate immediately
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Alert when forecast exceeds $50 — act before it happens
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

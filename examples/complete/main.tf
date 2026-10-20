module "finops" {
  source = "../.."

  name_prefix = "finops"

  notifications = {
    emails = ["ops@example.com"]
    # Name of an SSM SecureString parameter that you create yourself. It holds the
    # Slack incoming webhook URL. The URL never appears in Terraform.
    slack_webhook_ssm_param = "/finops/slack-webhook"
  }

  account_budget = {
    limit_usd           = 100
    alert_thresholds    = [50, 80, 100]
    forecast_thresholds = [100]

    actions = {
      # At 100% of actual spend, AWS waits for someone to approve in the console,
      # then attaches a deny policy to this role.
      deny-new-spend = {
        type              = "deny_policy"
        threshold_percent = 100
        roles             = ["dev-deployer"]
        approval_model    = "MANUAL"
      }
      # At 120% of actual spend, stop everything the scheduler tags. No approval step.
      stop-dev = {
        type              = "stop_tagged"
        threshold_percent = 120
      }
    }
  }

  tag_budgets = {
    env-dev = { tag_key = "Environment", tag_value = "dev", limit_usd = 30 }
  }

  service_budgets = {
    ec2 = { service = "Amazon Elastic Compute Cloud - Compute", limit_usd = 40 }
  }

  anomaly_detection = {
    enabled        = true
    min_impact_usd = 10
    min_impact_pct = 20

    tag_monitors = {
      project = { tag_key = "Project", tag_values = ["example"] }
    }
  }

  # AWS refuses to activate a key that no billed resource has used yet.
  cost_allocation_tag_keys = ["Environment", "Project"]

  scheduler = {
    enabled        = true
    timezone       = "Australia/Brisbane"
    tag_key        = "Schedule"
    tag_value      = "office-hours"
    stop_cron      = "cron(0 19 ? * MON-FRI *)"
    start_cron     = "cron(0 7 ? * MON-FRI *)"
    resource_types = ["ec2", "rds"]
    # Start with a dry run. Turn it off once the summaries show what you expect.
    dry_run = true
  }

  cost_report = {
    enabled  = true
    schedule = "cron(0 9 ? * MON *)"
    timezone = "Australia/Brisbane"
  }

  tags = { Project = "example" }
}

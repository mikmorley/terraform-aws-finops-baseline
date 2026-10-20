mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

variables {
  name_prefix   = "finops"
  sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:finops-alerts"
}

run "no_actions_by_default" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = { limit_usd = 100 }
  }

  assert {
    condition     = length(aws_budgets_budget_action.this) == 0 && length(aws_iam_role.actions) == 0 && length(aws_iam_policy.deny) == 0 && length(aws_sns_topic.budget_stop) == 0
    error_message = "Nothing action related should exist unless an action is set."
  }

  assert {
    condition     = output.native_action_budget_count == 0 && output.stop_topic_arn == null && output.deny_policy_arn == null && output.actions_role_arn == null
    error_message = "The action outputs should be empty."
  }
}

run "deny_policy_action_applies_a_module_policy" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        deny = { type = "deny_policy", threshold_percent = 90, roles = ["dev-role"], approval_model = "MANUAL", notification_type = "FORECASTED" }
      }
    }
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/deny"].action_type == "APPLY_IAM_POLICY" && aws_budgets_budget_action.this["account/deny"].approval_model == "MANUAL" && aws_budgets_budget_action.this["account/deny"].notification_type == "FORECASTED"
    error_message = "A deny_policy action should apply an IAM policy with the chosen approval model and notification type."
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/deny"].action_threshold[0].action_threshold_type == "PERCENTAGE" && aws_budgets_budget_action.this["account/deny"].action_threshold[0].action_threshold_value == 90
    error_message = "The threshold should be a percentage."
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/deny"].budget_name == "finops-account" && aws_budgets_budget_action.this["account/deny"].definition[0].iam_action_definition[0].roles == toset(["dev-role"])
    error_message = "The action should belong to its budget and target the listed role."
  }

  assert {
    condition     = one([for s in aws_budgets_budget_action.this["account/deny"].subscriber : s.address]) == var.sns_topic_arn && one([for s in aws_budgets_budget_action.this["account/deny"].subscriber : s.subscription_type]) == "SNS"
    error_message = "The action should tell the alert topic when it runs."
  }

  assert {
    condition     = length(aws_iam_policy.deny) == 1 && aws_iam_policy.deny[0].name == "finops-budget-deny"
    error_message = "Without policy_arn the module should create the deny policy."
  }

  assert {
    condition     = jsondecode(aws_iam_policy.deny[0].policy).Statement[0].Effect == "Deny" && contains(jsondecode(aws_iam_policy.deny[0].policy).Statement[0].Action, "ec2:RunInstances")
    error_message = "The created policy should deny the default actions."
  }

  assert {
    condition     = jsondecode(aws_iam_role.actions[0].assume_role_policy).Statement[0].Principal.Service == "budgets.amazonaws.com"
    error_message = "AWS Budgets should be able to assume the execution role."
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Sid]) == "AttachDenyPolicyToListedRoles"
    error_message = "The execution role should only manage policy attachments."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Condition.ArnEquals["iam:PolicyARN"]]) == ["arn:aws:iam::123456789012:policy/finops-budget-deny"] && join(",", one([for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Resource])) == "arn:aws:iam::123456789012:role/*/dev-role,arn:aws:iam::123456789012:role/dev-role"
    error_message = "Attach and detach should be limited to the listed role and the deny policy."
  }

  assert {
    condition     = output.native_action_budget_count == 1
    error_message = "One budget has native actions."
  }
}

run "deny_policy_action_with_own_policy" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        deny = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"], policy_arn = "arn:aws:iam::123456789012:policy/my-deny" }
      }
    }
  }

  assert {
    condition     = length(aws_iam_policy.deny) == 0
    error_message = "No policy should be created when the caller brings one."
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/deny"].definition[0].iam_action_definition[0].policy_arn == "arn:aws:iam::123456789012:policy/my-deny"
    error_message = "The action should use the supplied policy."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Condition.ArnEquals["iam:PolicyARN"]]) == ["arn:aws:iam::123456789012:policy/my-deny"]
    error_message = "The role should be limited to the supplied policy."
  }
}

run "stop_ec2_action_runs_an_ssm_document" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        stop = { type = "stop_ec2", threshold_percent = 100, instance_ids = ["i-0123456789abcdef0"] }
      }
    }
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/stop"].action_type == "RUN_SSM_DOCUMENTS" && aws_budgets_budget_action.this["account/stop"].approval_model == "AUTOMATIC" && aws_budgets_budget_action.this["account/stop"].notification_type == "ACTUAL"
    error_message = "A stop_ec2 action should run an SSM document, automatic and on actual spend by default."
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/stop"].definition[0].ssm_action_definition[0].action_sub_type == "STOP_EC2_INSTANCES" && aws_budgets_budget_action.this["account/stop"].definition[0].ssm_action_definition[0].instance_ids == toset(["i-0123456789abcdef0"]) && aws_budgets_budget_action.this["account/stop"].definition[0].ssm_action_definition[0].region == "us-east-1"
    error_message = "The SSM definition should stop the listed instances in the provider region."
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Sid]) == "StopListedEc2Instances,DescribeEc2InstanceStatus,RunSsmStopDocuments"
    error_message = "The role should be able to stop the listed instances and start the SSM automation, and nothing for RDS."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Resource if s.Sid == "StopListedEc2Instances"]) == ["arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0"]
    error_message = "ec2:StopInstances should be limited to the listed instances."
  }

  assert {
    condition     = length(aws_iam_policy.deny) == 0 && length(aws_sns_topic.budget_stop) == 0
    error_message = "A stop_ec2 action needs no deny policy or stop topic."
  }
}

run "stop_rds_action_in_another_region" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        stop = { type = "stop_rds", threshold_percent = 100, instance_ids = ["dev-db"], region = "eu-west-1", approval_model = "MANUAL" }
      }
    }
  }

  assert {
    condition     = aws_budgets_budget_action.this["account/stop"].definition[0].ssm_action_definition[0].action_sub_type == "STOP_RDS_INSTANCES" && aws_budgets_budget_action.this["account/stop"].definition[0].ssm_action_definition[0].region == "eu-west-1" && aws_budgets_budget_action.this["account/stop"].approval_model == "MANUAL"
    error_message = "A stop_rds action should use the RDS document, its own region and the chosen approval model."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.actions[0].policy).Statement : s.Resource if s.Sid == "StopListedRdsInstances"]) == ["arn:aws:rds:eu-west-1:123456789012:db:dev-db"]
    error_message = "rds:StopDBInstance should be limited to the listed database in its region."
  }
}

run "stop_tagged_action_notifies_the_stop_topic" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        stop-all = { type = "stop_tagged", threshold_percent = 100 }
        brake    = { type = "stop_tagged", threshold_percent = 95, notification_type = "FORECASTED" }
      }
    }
  }

  assert {
    condition     = length(aws_budgets_budget_action.this) == 0 && length(aws_iam_role.actions) == 0
    error_message = "stop_tagged is a plain notification, so it needs no native action and no execution role."
  }

  assert {
    condition     = length(aws_sns_topic.budget_stop) == 1 && aws_sns_topic.budget_stop[0].name == "finops-budget-stop" && output.native_action_budget_count == 0
    error_message = "One stop topic should exist and no budget should count as having native actions."
  }

  assert {
    condition     = toset([for s in jsondecode(aws_sns_topic_policy.budget_stop[0].policy).Statement : s.Principal.Service if try(s.Principal.Service, null) != null]) == toset(["budgets.amazonaws.com"])
    error_message = "Only AWS Budgets may publish to the stop topic."
  }

  assert {
    condition     = one([for s in jsondecode(aws_sns_topic_policy.budget_stop[0].policy).Statement : s.Condition.StringEquals["aws:SourceAccount"] if try(s.Principal.Service, null) != null]) == "123456789012"
    error_message = "The stop topic policy should be scoped to this account."
  }

  assert {
    condition     = one([for n in aws_budgets_budget.this["account"].notification : n.subscriber_sns_topic_arns if n.notification_type == "ACTUAL" && n.threshold == 100]) == toset(["arn:aws:sns:us-east-1:123456789012:finops-alerts", "arn:aws:sns:us-east-1:123456789012:finops-budget-stop"])
    error_message = "The 100 percent actual notification should reach the alert topic and the stop topic."
  }

  assert {
    condition     = one([for n in aws_budgets_budget.this["account"].notification : n.subscriber_sns_topic_arns if n.notification_type == "FORECASTED" && n.threshold == 95]) == toset(["arn:aws:sns:us-east-1:123456789012:finops-budget-stop"])
    error_message = "A forecast stop at a new threshold should add a notification that reaches the stop topic only."
  }

  assert {
    condition     = one([for n in aws_budgets_budget.this["account"].notification : n.subscriber_sns_topic_arns if n.notification_type == "ACTUAL" && n.threshold == 80]) == toset(["arn:aws:sns:us-east-1:123456789012:finops-alerts"])
    error_message = "Other alerts should still reach the alert topic only."
  }
}

run "stop_topic_is_shared_by_all_stop_tagged_actions" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        stop = { type = "stop_tagged", threshold_percent = 100 }
      }
    }
    service_budgets = {
      ec2 = {
        service   = "Amazon Elastic Compute Cloud - Compute"
        limit_usd = 40
        actions = {
          stop = { type = "stop_tagged", threshold_percent = 100 }
        }
      }
    }
  }

  assert {
    condition     = length(aws_sns_topic.budget_stop) == 1
    error_message = "All stop_tagged actions should share one topic."
  }

  assert {
    condition     = length(aws_budgets_budget.this["service-ec2"].notification) == 4
    error_message = "The service budget should keep its four alerts, with the stop topic added to the matching one."
  }
}

run "two_budgets_with_native_actions_are_free" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        a = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"] }
        b = { type = "deny_policy", threshold_percent = 120, roles = ["dev-role"] }
      }
    }
    tag_budgets = {
      dev = {
        tag_key   = "Environment"
        tag_value = "dev"
        limit_usd = 30
        actions = {
          stop = { type = "stop_ec2", threshold_percent = 100, instance_ids = ["i-0123456789abcdef0"] }
        }
      }
    }
  }

  assert {
    condition     = length(aws_budgets_budget_action.this) == 3 && output.native_action_budget_count == 2
    error_message = "Three actions on two budgets should count as two budgets."
  }
}

run "warns_when_more_than_two_budgets_have_native_actions" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        deny = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"] }
      }
    }
    tag_budgets = {
      dev = {
        tag_key   = "Environment"
        tag_value = "dev"
        limit_usd = 30
        actions = {
          stop = { type = "stop_ec2", threshold_percent = 100, instance_ids = ["i-0123456789abcdef0"] }
        }
      }
    }
    service_budgets = {
      rds = {
        service   = "Amazon Relational Database Service"
        limit_usd = 20
        actions = {
          stop = { type = "stop_rds", threshold_percent = 100, instance_ids = ["dev-db"] }
        }
      }
    }
  }

  expect_failures = [check.native_action_budgets]
}

run "custom_deny_policy_actions" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        deny = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"] }
      }
    }
    deny_policy_actions = ["s3:CreateBucket"]
  }

  assert {
    condition     = jsondecode(aws_iam_policy.deny[0].policy).Statement[0].Action == ["s3:CreateBucket"]
    error_message = "deny_policy_actions should replace the default list."
  }
}

run "rejects_unknown_action_type" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "nuke", threshold_percent = 100 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_threshold_below_one" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_tagged", threshold_percent = 0 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_threshold_above_1000" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_tagged", threshold_percent = 1001 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_unknown_notification_type" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_tagged", threshold_percent = 100, notification_type = "ESTIMATED" }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_unknown_approval_model" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"], approval_model = "ASK" }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_manual_approval_for_stop_tagged" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_tagged", threshold_percent = 100, approval_model = "MANUAL" }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_deny_policy_without_roles" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "deny_policy", threshold_percent = 100 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_role_arn_in_place_of_role_name" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "deny_policy", threshold_percent = 100, roles = ["arn:aws:iam::123456789012:role/dev-role"] }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_bad_deny_policy_arn" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"], policy_arn = "my-deny" }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_stop_ec2_without_instance_ids" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_ec2", threshold_percent = 100 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_stop_rds_without_instance_ids" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_rds", threshold_percent = 100 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_bad_ec2_instance_id" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_ec2", threshold_percent = 100, instance_ids = ["web-1"] }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_bad_region" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        bad = { type = "stop_ec2", threshold_percent = 100, instance_ids = ["i-0123456789abcdef0"], region = "mars" }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_action_name_with_spaces" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        "bad name" = { type = "stop_tagged", threshold_percent = 100 }
      }
    }
  }

  expect_failures = [aws_budgets_budget.this]
}

run "rejects_empty_deny_policy_actions" {
  command = plan

  module {
    source = "./modules/budgets"
  }

  variables {
    account_budget = {
      limit_usd = 100
      actions = {
        deny = { type = "deny_policy", threshold_percent = 100, roles = ["dev-role"] }
      }
    }
    deny_policy_actions = []
  }

  expect_failures = [var.deny_policy_actions]
}

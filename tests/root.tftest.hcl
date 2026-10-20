mock_provider "aws" {}
mock_provider "archive" {}

# Smoke test: the (still empty) root module plans. Real assertions arrive with
# the feature milestones.
run "root_plans" {
  command = plan
}

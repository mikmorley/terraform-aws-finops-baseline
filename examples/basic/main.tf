module "finops" {
  source = "../.."

  name_prefix = "finops"

  notifications = {
    emails = ["ops@example.com"]
  }

  account_budget = {
    limit_usd = 100
  }

  tags = { Project = "example" }
}

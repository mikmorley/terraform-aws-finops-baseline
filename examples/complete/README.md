# complete

Every feature on. Use it to see what each input looks like, then remove what you do not need.

It creates:

- Email and Slack alerts. Create the SecureString parameter `/finops/slack-webhook` first, with your webhook URL as its value.
- A US$100 account budget, a tag budget for `Environment=dev` and a service budget for EC2.
- Two actions on the account budget: a deny policy for the role `dev-deployer` that waits for manual approval at 100%, and a `stop_tagged` action at 120%.
- Anomaly detection, with an extra monitor for the `Project` tag.
- Activation of the `Environment` and `Project` cost allocation tags.
- The scheduler for EC2 and RDS resources tagged `Schedule=office-hours`, in dry-run mode, in the `Australia/Brisbane` time zone.
- The weekly cost report.

Before you apply:

- Tag at least one billed resource with each key in `cost_allocation_tag_keys`. AWS refuses to activate a key that no billed resource has used yet.
- Create the role `dev-deployer`, or change `roles`. The deny policy attaches to it.
- Look at the cost of the actions. This example has one budget with native actions, which is free. A third budget would cost about US$3 a month.
- The scheduler runs with `dry_run = true`. The summaries show what it would stop. Set it to `false` when they look right.

Applying creates real AWS resources. This example has a plan and a validate check in CI, and no automated apply.

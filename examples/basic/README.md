# basic

The smallest useful setup: one monthly account budget and email alerts.

It creates:

- A US$100 monthly budget with alerts at 50%, 80% and 100% of actual spend and at 100% of forecast.
- Cost anomaly alerts for anomalies of at least US$10 **and** 20%.
- A weekly cost report, Mondays at 09:00 UTC.
- The SNS topic that carries all of them, with an email subscription.

Replace `ops@example.com` with your address, then:

```sh
terraform init
terraform plan
```

After you apply, open the confirmation email from AWS and click the link. Alerts do not arrive until you do.

Applying creates real AWS resources. This example has a plan and a validate check in CI, and no automated apply.

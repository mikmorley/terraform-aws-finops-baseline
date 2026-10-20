# Contributing

Thanks for helping. This is a small project, so the process is short.

## Set up

You need Terraform 1.7 or later, Python 3.13, [tflint](https://github.com/terraform-linters/tflint) and [terraform-docs](https://github.com/terraform-docs/terraform-docs) v0.24.0. CI pins the same terraform-docs version, because its output differs between versions.

```sh
python -m venv .venv && . .venv/bin/activate
pip install pytest "moto[ssm,sns,ec2,rds,ce]" boto3 ruff checkov pre-commit
pre-commit install
```

## Checks

CI runs all of these on every pull request. The pre-commit hooks run the format, validate, tflint, terraform-docs and ruff checks:

```sh
terraform fmt -check -recursive
scripts/validate-all.sh          # init and validate the root, every module and every example
tflint --init && tflint --recursive
terraform init -backend=false && terraform test
ruff check . && ruff format --check .
pytest
checkov -d . --framework terraform
terraform-docs --config .terraform-docs.yml .    # then check git shows no change
```

`terraform test` uses mock providers and starts a provider process per run block, so it is slow on a small machine. CI runs it for you.

## Changes

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat(budgets): ...`, `fix(scheduler): ...`, `docs: ...`. Release tooling reads them to pick the next version and write `CHANGELOG.md`.
- Add or update tests with the change. Terraform changes need `tests/*.tftest.hcl` runs. Lambda changes need `lambda/tests`.
- Update the README of the module you change. Keep the content between the `terraform-docs` markers as generated.
- Lambdas use Python 3.13, the standard library and boto3 only, so there is no build step.
- Document every checkov skip next to the resource, with the reason.
- Use `123456789012` for account IDs, `example.com` for addresses and `/finops/slack-webhook` for the parameter name. Never commit real account IDs, email addresses, webhook URLs or ARNs.
- Renaming a resource needs a `moved` block, so existing users do not lose it.

## Real applies

CI never creates AWS resources. Before a release the maintainer applies `examples/complete` to a test account by hand. If you change how a message is parsed or what an IAM policy allows, say in the pull request how you checked it against real AWS.

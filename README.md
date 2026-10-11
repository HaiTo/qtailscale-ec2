# qtailscale-ec2

One tap on an iPhone shortcut starts an EC2 instance in a US Region, which joins your tailnet as a [Tailscale](https://tailscale.com/) exit node and shuts itself down 75 minutes later.

It is a personal tool for checking how your own services behave when accessed from outside Japan. It costs about one US dollar a month.

## How it works

```
iPhone shortcut
  │  POST + X-Auth-Token
  ▼
Lambda function URL ──▶ ec2:StartInstances (one fixed instance)
                              │
                              ▼
                        EC2 t4g.nano boots
                          ├─ joins the tailnet as exit node "exit-us"
                          └─ powers itself off after 75 minutes (= stopped)
```

1. The shortcut sends a POST request with a secret token to a Lambda function URL.
2. The Lambda function checks the token and starts the instance. That is all it can do.
3. The instance boots, connects to Tailscale, and advertises itself as an exit node.
4. The shortcut waits about 30 seconds, then tells the Tailscale app to use that exit node.
5. A systemd timer inside the instance powers it off 75 minutes after boot.

The Lambda function only starts the instance. Stopping is done by the instance itself, so it does not depend on anything outside the machine.

## What gets created

| Resource | Details |
| --- | --- |
| EC2 instance | `t4g.nano` (Arm), Amazon Linux 2023, 8 GB encrypted gp3 volume, IMDSv2 only |
| Network | Dedicated VPC with one public subnet and an internet gateway. No NAT gateway |
| Security group | No inbound rules at all. Outbound is unrestricted |
| Lambda function | Python 3.13 on arm64, with a function URL and a reserved concurrency of 1 |
| IAM roles | One for the instance, one for the Lambda function, both least-privilege |
| Log group | Lambda logs, kept for 14 days |

## Security model

- **Secrets stay out of Terraform.** The shortcut token and the Tailscale auth key are created by hand and stored as SSM SecureString parameters. Terraform only knows their names, so nothing sensitive ends up in `tfstate`.
- **The token is compared in constant time** with `hmac.compare_digest`. A missing or wrong token gets a 403.
- **The Lambda role can do three things:** start this one instance, read this one token parameter, and write to its own log group.
- **The instance role can do two things:** read the auth key parameter, and talk to SSM for Session Manager.
- **No inbound ports.** Administration goes through SSM Session Manager. SSH is not open.
- **A leaked token is low impact.** The worst an attacker can do is start the instance, which stops again after 75 minutes.
- **Tokens and keys are never logged.** The auth key is passed to Tailscale through a file on tmpfs and deleted right after.

Keep `terraform.tfvars`, `*.tfstate*`, and the function URL out of version control and out of public places. The first two are git-ignored. The URL is not a secret on its own, since every request still needs the token, but there is no reason to publish it.

## Prerequisites

- An AWS account or project that can use a US Region
- A Tailscale account, with the Tailscale app installed on the iPhone
- AWS CLI v2 with a profile that uses short-lived credentials (no long-lived access keys)
- Terraform 1.9 or later (developed with 1.16.5; `mise use terraform@1.16.5` works)

### AWS credentials

Use one of these. Both give short-lived credentials.

```sh
# A. Browser sign-in (the only option for projects in the new AWS experience)
aws configure set region us-west-2 --profile <profile>
aws login --region us-west-2 --profile <profile>

# B. IAM Identity Center (SSO)
aws configure sso
aws sso login --profile <profile>
```

> **New AWS experience:** each project is its own AWS account, and a project can be locked to a single Region by an organization policy. Requests to any other Region fail with `explicit deny in a service control policy`. Sign in to a project whose Region is in the US, and pass that Region to `aws login`.

### Lambda concurrency limit

Reserving concurrency requires the account limit to leave at least 100 unreserved. Check it:

```sh
aws lambda get-account-settings --profile <profile> --region us-west-2 \
  --query AccountLimit.ConcurrentExecutions
```

Anything from a few hundred up is fine. If it is very low (new accounts sometimes get 10), request an increase for "Concurrent executions" in Service Quotas, and set `lambda_reserved_concurrency = -1` in `terraform.tfvars` until it is granted.

## Setup

Do these in order. The instance tries to register with Tailscale as soon as it is created, so the Tailscale side and the parameters must exist first.

### 1. Configure Tailscale

In the admin console, open **Access controls** and add these two entries. If `tagOwners` or `autoApprovers` already exist, add the lines inside them.

```jsonc
{
  "tagOwners": {
    "tag:exit-us": ["autogroup:admin"]
  },
  "autoApprovers": {
    "exitNode": ["tag:exit-us"]
  }
}
```

`autoApprovers` approves the exit node automatically. Without it, the node waits for manual approval on the **Machines** page.

Then create an auth key under **Settings → Keys → Generate auth key**:

| Option | Value |
| --- | --- |
| Reusable | Off |
| Ephemeral | Off |
| Tags | On, with `tag:exit-us` |
| Expiration | Short is fine (1 to 7 days). The key is used once |

A node registered with a tagged key has key expiry disabled, so it keeps working without re-authentication.

### 2. Store the secrets in SSM

Run these in a regular terminal, not through a tool that records the session.

The shortcut token:

```sh
TOKEN="$(openssl rand -hex 32)"
aws ssm put-parameter --profile <profile> --region us-west-2 \
  --name /qtailscale-ec2/shortcut-token \
  --type SecureString --value "$TOKEN"
echo "$TOKEN"   # put this in the iPhone shortcut, then close the terminal
unset TOKEN
```

The Tailscale auth key:

```sh
read -rs TS_AUTHKEY   # paste the key and press Enter; nothing is echoed
aws ssm put-parameter --profile <profile> --region us-west-2 \
  --name /qtailscale-ec2/tailscale-authkey \
  --type SecureString --value "$TS_AUTHKEY"
unset TS_AUTHKEY
```

### 3. Deploy

```sh
cp terraform.tfvars.example terraform.tfvars   # set aws_profile
terraform init
terraform plan
terraform apply
```

The instance boots right away, registers within a minute or two, and stops itself 75 minutes later.

### 4. Verify

- The Tailscale admin console lists `exit-us` on the **Machines** page with the **Exit Node** badge.
- The function URL rejects requests without the token:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$(terraform output -raw function_url)"
# 403
```

- With the token, it starts the instance:

```sh
curl -X POST -H "X-Auth-Token: <token>" "$(terraform output -raw function_url)"
# {"previous": "stopped", "current": "pending"}
```

| Status | Meaning |
| --- | --- |
| 200 | Start requested. `previous` is `running` if it was already up |
| 403 | Token missing or wrong |
| 405 | Not a POST request |
| 409 | The instance is still stopping. Retry in a few seconds |
| 429 | Concurrency limit reached |

### 5. Build the iPhone shortcut

1. **Get Contents of URL**
   - URL: the value of `terraform output function_url`
   - Method: POST
   - Headers: `X-Auth-Token` set to your token
2. **Wait**: 30 seconds
3. Tailscale **Use Exit Node**: choose `exit-us`
4. Tailscale **Connect**

Action names in the Tailscale app can differ between versions. If the exit node is not ready after 30 seconds, raise the wait to 45.

## Daily use

- **Start:** run the shortcut. About 30 seconds later the iPhone's traffic leaves through the US.
- **Check:** open `https://ifconfig.me` in Safari. It should show a US address. The address changes on every start.
- **Finish:** set the exit node back to **None** in the Tailscale app.

Things to know:

- **Set the exit node back to None when you are done.** If the instance stops while the iPhone still uses it as an exit node, the iPhone loses internet access until you switch back.
- **Running the shortcut again does not extend the session.** The 75 minutes count from the moment the instance booted.
- **Only the IP address changes.** Services that look at the phone number, device region, App Store country, or GPS will not see a different country.
- **Some iOS traffic bypasses VPNs.** Connections opened before the exit node was enabled may stay on the old path. Reopen the app you are testing.

To stop the instance early:

```sh
aws ec2 stop-instances --profile <profile> --region us-west-2 \
  --instance-ids "$(terraform output -raw instance_id)"
```

## Configuration

Set these in `terraform.tfvars`. Only `aws_profile` is required.

| Variable | Default | Purpose |
| --- | --- | --- |
| `aws_profile` | (required) | AWS CLI profile |
| `aws_region` | `us-west-2` | Region to deploy into |
| `auto_stop_minutes` | `75` | Minutes after boot until the instance powers off |
| `tailscale_tag` | `tag:exit-us` | Tag applied to the node |
| `tailscale_hostname` | `exit-us` | Hostname shown in the tailnet |
| `shortcut_token_parameter_name` | `/qtailscale-ec2/shortcut-token` | SSM parameter with the shortcut token |
| `tailscale_authkey_parameter_name` | `/qtailscale-ec2/tailscale-authkey` | SSM parameter with the auth key |
| `lambda_reserved_concurrency` | `1` | 1 or 2, or -1 for unreserved |
| `log_retention_days` | `14` | Lambda log retention |
| `vpc_cidr` | `10.99.0.0/24` | CIDR of the dedicated VPC |

The instance ignores changes to its AMI and user data, because replacing it wipes the Tailscale state. `auto_stop_minutes`, `tailscale_tag`, and `tailscale_hostname` are baked into the user data, so changing them needs a [rebuild](#rebuilding-the-instance).

## Design choices

These were not dictated by the requirements. They are the safer or cheaper option in each case.

| Topic | Choice | Reason |
| --- | --- | --- |
| VPC | Dedicated minimal VPC | Free, and independent of the default VPC |
| AMI | Amazon Linux 2023 (arm64) | Ships with the SSM agent and the AWS CLI |
| Admin access | SSM Session Manager only | Tailscale SSH needs extra ACL rules, so it is off by default |
| Public IP | Auto-assigned, no Elastic IP | No IPv4 charge while the instance is stopped |
| Encryption keys | AWS managed keys for SSM and EBS | No KMS permissions needed in the IAM policies |
| Token lookup | Read from SSM on every request | A rotated token takes effect immediately |
| State | Local `tfstate` | Personal use, and the state holds no secrets |

## Operations

### Rotate the token

The old token stops working the moment the parameter is overwritten.

```sh
TOKEN="$(openssl rand -hex 32)"
aws ssm put-parameter --profile <profile> --region us-west-2 \
  --name /qtailscale-ec2/shortcut-token \
  --type SecureString --value "$TOKEN" --overwrite
echo "$TOKEN"   # update the header in the shortcut
unset TOKEN
```

Look for rejected calls in the logs:

```sh
aws logs tail "$(terraform output -raw lambda_log_group)" \
  --profile <profile> --region us-west-2 --since 7d --filter-pattern forbidden
```

To shut the URL off completely, set the concurrency to zero:

```sh
aws lambda put-function-concurrency --profile <profile> --region us-west-2 \
  --function-name qtailscale-ec2-start --reserved-concurrent-executions 0
```

If the Tailscale auth key leaks, revoke it under **Settings → Keys**.

### Connect to the instance

```sh
aws ssm start-session --profile <profile> --region us-west-2 \
  --target "$(terraform output -raw instance_id)"
```

This needs the Session Manager plugin. Useful commands once inside:

```sh
systemctl list-timers auto-stop.timer        # when the instance will power off
journalctl -u tailscale-bootstrap.service    # Tailscale install and registration log
tailscale status
```

### How the instance is set up

User data runs only on the first boot, so it does nothing but install two systemd units:

- `auto-stop.timer` schedules a power-off 75 minutes after every boot. It is installed before anything else, so it works even if the rest of the setup fails.
- `tailscale-bootstrap.service` installs Tailscale and registers the node. It runs on every boot until it succeeds once, then never again.

### If Tailscale registration fails

The bootstrap retries on every boot. If the auth key was missing or expired, store a new one in SSM and start the instance again.

### Rebuilding the instance

To apply a new AMI or changed user data:

1. Create a new auth key and store it in SSM.
2. Remove the old `exit-us` node in the Tailscale admin console.
3. Replace the instance:

```sh
terraform apply -replace=aws_instance.exit_node
```

### No inbound ports

The security group has no inbound rules. Tailscale builds its connections from the inside out, so the exit node still works. On some networks the traffic is relayed through Tailscale's DERP servers, which is slower.

### Tailscale SSH

Run `tailscale set --ssh` on the instance and add an `ssh` rule to the ACL.

### Moving the state to S3

1. Create an S3 bucket with versioning and encryption.
2. Add a backend to the `terraform` block in `versions.tf`:

```hcl
backend "s3" {
  bucket       = "<bucket>"
  key          = "qtailscale-ec2/terraform.tfstate"
  region       = "us-west-2"
  profile      = "<profile>"
  use_lockfile = true
}
```

3. Run `terraform init -migrate-state`, then delete the local `terraform.tfstate*` files.

## Cost

Estimate for one hour a day (30 hours a month) in `us-west-2`:

| Item | Monthly |
| --- | --- |
| EBS gp3, 8 GB | about $0.64 |
| EC2 t4g.nano, 30 hours | about $0.13 |
| Public IPv4, 30 hours | about $0.15 |
| Lambda, SSM, logs | close to $0 |
| **Total** | **about $0.90**, before tax |

Data transfer is expected to stay inside the 100 GB monthly free allowance.

## Teardown

```sh
terraform destroy
aws ssm delete-parameter --profile <profile> --region us-west-2 --name /qtailscale-ec2/shortcut-token
aws ssm delete-parameter --profile <profile> --region us-west-2 --name /qtailscale-ec2/tailscale-authkey
```

Then remove the `exit-us` node in the Tailscale admin console and revoke any auth keys that are still valid.

## Development

Optional linting with pre-commit:

```sh
brew install pre-commit tflint trivy
pre-commit install
tflint --init
```

This runs gitleaks, `terraform fmt`, `terraform validate`, tflint, and trivy on each commit.

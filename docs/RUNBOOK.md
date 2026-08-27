# Runbook — deploy, verify, destroy

The one rule: **start `terraform apply` before you do anything else.** RDS
Multi-AZ takes ~15 minutes and CloudFront another ~8. There is no reason to
watch that happen — go draw the diagram while it builds.

| Clock | Task | Notes |
|---|---|---|
| 0:00–0:15 | Prereqs + `terraform init` | Install Terraform, confirm AWS creds |
| 0:15–0:20 | **`terraform apply` — kick it off and walk away** | ~22 min unattended |
| 0:20–1:20 | Draw the architecture diagram | See `DIAGRAM-SPEC.md` |
| 1:20–1:30 | Verify apply succeeded, open the app URL | |
| 1:30–2:15 | Evidence capture | See `EVIDENCE-CHECKLIST.md` |
| 2:15–2:35 | `terraform destroy` | CloudFront dominates the time |
| 2:35–4:10 | Write the README | Scaffold is written; fill the TODOs |
| 4:10–4:40 | Push to GitHub, check rendering | |
| 4:40–5:00 | Buffer | |

---

## Step 0 — Prerequisites (15 min)

```bash
# Terraform (Linux/WSL)
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Windows (PowerShell, as Administrator)
choco install terraform

terraform version            # expect >= 1.5
aws sts get-caller-identity  # must return YOUR account id
```

If `aws sts get-caller-identity` fails, run `aws configure` first.

> Use an IAM user or role with **AdministratorAccess** for this build. Do not
> spend deadline time debugging IAM denials.

---

## Step 1 — Configure and apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set owner, and alert_email if you want alarm emails

terraform init
terraform plan -out=tfplan    # skim the resource count, ~64 resources
terraform apply tfplan
```

**Then leave it.** Go draw the diagram.

### Tight on time?

Set `enable_cloudfront = false` in `terraform.tfvars`. That removes ~8 minutes
from the apply and ~8 from the destroy. The design stays documented in the
README either way — you just lose the cache-header screenshot.

### If apply fails

- **`InvalidParameterValue: DB engine version`** — run
  `aws rds describe-db-engine-versions --engine mysql --query 'DBEngineVersions[-1].EngineVersion' --output text`
  and put that value in `db_engine_version`.
- **Region has fewer than 2 AZs available** — switch `aws_region` to `us-east-1`.
- **`InvalidClientTokenId` / expired credentials** — re-run `aws configure`.

---

## Step 2 — Verify (10 min)

```bash
terraform output application_url    # ALB direct
terraform output cloudfront_url     # via the edge
terraform output demo_commands      # your copy-paste command sheet
```

Refreshing `application_url` should show the **Instance ID and AZ changing**
between two values. That single screenshot proves multi-AZ load balancing.

> CloudFront takes a few extra minutes to fully propagate even after Terraform
> reports success. If the CloudFront URL 502s, give it 3–5 minutes.

---

## Step 3 — Evidence, then destroy

Follow `EVIDENCE-CHECKLIST.md`. Then:

```bash
terraform destroy
```

Takes ~15 minutes with CloudFront (Terraform disables the distribution, waits
for it to propagate, then deletes it), or ~8 minutes without. **Wait for it to
finish and read the last line.** If anything errors, run it again — destroy is
idempotent.

### Confirm nothing is left billing

```bash
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
aws cloudfront list-distributions --query 'DistributionList.Items[].Id'
```

All five should come back empty. **NAT Gateways and unattached Elastic IPs**
are the two things that quietly keep charging after a sloppy teardown.

# Evidence Capture — ~45 minutes, ordered by how long each takes to react

Run `terraform output demo_commands` first — every command below is in there
with your real resource IDs already filled in.

**Order matters.** Start the slow-reacting things first, then capture the
instant ones while you wait.

Save screenshots to `docs/screenshots/` using the exact filenames given.
**Target: 14 screenshots** (15 files - `05b` is a bonus).

---

## Start these FIRST (they need time to show up)

### 1. Trigger the scale-out — 0:00, results at ~0:06
```bash
aws ssm start-session --target <instance-id>
sudo /usr/local/bin/burn-cpu.sh 420
```
Leave it running. Detach with `Ctrl-D` — the load continues.

📸 `01-terraform-apply-complete.png` — the apply output showing the resource
count and the outputs. Proof the whole thing is code.

📸 `02-ssm-session.png` — the Session Manager terminal. **Caption the point:
no key pair, no port 22, no bastion host.**

### 2. Force the RDS failover — 0:02, completes in ~2 min

**Capture the "before" line first** — it is worthless afterwards:

```bash
curl -s http://<alb-dns>/dbstatus.txt      # note the server= hostname
aws rds reboot-db-instance --db-instance-identifier <id> --force-failover
# wait ~3 min for the probe timer to run again, then:
curl -s http://<alb-dns>/dbstatus.txt      # server= should be a DIFFERENT host
```

RDS console → your instance → **Logs & events** tab. Watch for the
`Multi-AZ instance failover started` / `completed` pair.

📸 `05-rds-failover-events.png` — the event log showing both lines.

📸 `13-dbstatus-before-after-failover.png` — both `curl` outputs in one frame.
This is the strongest single piece of evidence in the project: it proves the
private app tier really reaches the database over TLS, *and* that the standby
took over. Subtract the two timestamps for your measured failover duration —
that is the number the README asks you to fill in.

---

## Capture these while you wait (instant)

### 3. Multi-AZ load balancing — the money shot
Open `terraform output application_url`, refresh 6 times.

📸 `03-alb-az-a.png` and `04-alb-az-b.png` — the same URL showing two
different Instance IDs and two different AZs. This pair is the clearest
possible proof of a highly available architecture. Put it near the top of the
README.

### 4. Security group chain
Console → EC2 → Security Groups → the RDS SG → Inbound rules.

📸 `06-sg-chain.png` — the source column showing a **security group ID**, not
a CIDR block. Caption why that matters.

### 5. ALB listener rule blocking /admin
```bash
curl -i "http://<alb-dns>/admin"
```
Expect **HTTP 403** with your custom message body.

📸 `07-alb-listener-rule.png`

### 6. WAF blocking SQL injection

> **Run this from inside the VPC, not from your laptop.** Running it locally
> returned `curl: (52) Empty reply from server` with no HTTP status at all -
> the request was dropped by something on the client network (antivirus web
> shield, corporate inspection, ISP DPI) *before it reached AWS*. WAF's
> sampled-request log confirmed the malicious request never arrived, while a
> benign one did. A real WAF block always returns a clean `403`; a
> connection-level failure means the test never got there.

```bash
aws ssm start-session --target <instance-id>
H=http://<alb-dns>
curl -s -o /dev/null -w 'sqli=%{http_code}
'      "$H/?id=1%27%20OR%20%271%27=%271"
curl -s -o /dev/null -w 'xss=%{http_code}
'       "$H/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
curl -s -o /dev/null -w 'traversal=%{http_code}
' "$H/?f=..%2F..%2Fetc%2Fpasswd"
curl -s -o /dev/null -w 'benign=%{http_code}
'    "$H/?id=hello"
```

Expect `403` for the three attacks and `200` for the benign control. Including
the control is what makes the screenshot persuasive - it shows WAF
discriminating, not merely refusing everything.

📸 `11-waf-block-curl.png` - all four lines in one frame.

Cross-check in CloudWatch: `AWS/WAFV2 BlockedRequests` should equal the number
of *attack* probes only. `/admin` is blocked by the ALB listener rule, not
WAF, so it must not appear in that count.

### 7. CloudFront cache behaviour — run each curl TWICE
```bash
# dynamic - should be "Miss from cloudfront" every single time
curl -sI https://<cf-domain>/ | grep -i x-cache

# static - first call Miss, SECOND call "Hit from cloudfront"
curl -sI https://<cf-domain>/static/logo.svg | grep -i x-cache
curl -sI https://<cf-domain>/static/logo.svg | grep -i x-cache
```

📸 `10-cloudfront-cache-headers.png` — all four lines in one terminal frame.
This single screenshot proves you understood the dynamic/static split, which
is the actual skill CloudFront tests.

> If the static file 404s, the instance may not have finished bootstrapping.
> Wait 60 seconds and retry.

### 8. Secrets Manager
Console → Secrets Manager → your secret → *Retrieve secret value*.

📸 `12-secrets-manager.png` — **blur or crop the password.** Showing the
credential lives here is the point; leaking it is not.

---

## Back to the slow ones (~0:15 onward)

### 9. Auto Scaling in action
Console → EC2 → Auto Scaling Groups → your ASG → **Activity** tab.

📸 `08-asg-scaling-activity.png` — the entry reading *"Launching a new EC2
instance… triggered by target tracking policy"*.

### 10. CloudWatch dashboard
`terraform output dashboard_url`

📸 `09-cloudwatch-dashboard.png` — set the time range to **Last 1 hour** so
the CPU spike and the capacity increase are both visible in one frame. This is
your hero image.

---

## Before you destroy

```bash
terraform output > ../docs/terraform-outputs.txt
terraform state list > ../docs/terraform-resources.txt
```

Both are cheap, both look thorough, and `terraform state list` shows the full
resource inventory without pasting state.

Count your screenshots. **You want 14.** Then destroy.

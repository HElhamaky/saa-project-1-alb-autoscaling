# Evidence capture — step by step

Detailed instructions for all 15 screenshots. Every command is copy-paste
ready and reads its own values from Terraform, so nothing here goes stale
between deployments.

[`EVIDENCE-CHECKLIST.md`](EVIDENCE-CHECKLIST.md) covers *why* the order is what
it is. This file covers *how* to take each shot.

---

## Before you start

### Rule 1 — never hardcode an instance ID

Instances in an Auto Scaling Group are disposable. Scale-in terminates them
without warning, and an ID copied twenty minutes ago will fail with
`TargetNotConnected`. **Fetch them fresh every time:**

```powershell
.\docs\evidence-values.ps1
```

That prints every endpoint and ID this document refers to. Re-run it whenever a
command fails on a missing resource.

> `TargetNotConnected` has two very different causes. Check which one you have
> before debugging:
> ```powershell
> aws ec2 describe-instances --instance-ids <id> --query "Reservations[].Instances[].State.Name" --output text
> ```
> `terminated` means the ID is stale — fetch a new one. `running` means a real
> SSM problem, usually the IAM role or the NAT path.

### Rule 2 — confirm the SNS email first

Every deployment creates a **new** topic, so a **new** confirmation email is
sent and the old confirmation does not carry over. Click it before anything
else, or screenshot 14 is impossible and you will only find out after the
alarm has already fired.

Search Gmail for `in:anywhere from:no-reply@sns.amazonaws.com` — `in:anywhere`
matters, because AWS notification mail reliably lands in spam.

### Rule 3 — clear the old screenshots

```powershell
Remove-Item docs\screenshots\*.png
```

Git then shows all 15 as deleted, which doubles as your checklist. Without
this, a shot you forget to retake silently keeps a stale image.

### Rule 4 — quoting on Windows

PowerShell parses `<`, `>` and `&` as operators, and does not understand `\"`.
Any AWS CLI argument containing shell syntax must go through a JSON file:

```powershell
aws ssm send-command --cli-input-json file://payload.json
```

Building that argument inline is the single most common way these commands
fail.

---

## Order of operations

Two tests take minutes to produce results. Start both, then collect the
instant shots while they run.

| Phase | Do this | Yields |
|---|---|---|
| 1 | Capture the failover baseline | — |
| 2 | Start the CPU burn | `08`, `09` |
| 3 | Trigger the failover (~1 min after the burn) | `05`, `05b`, `13` |
| 4 | Terminal captures while waiting | `01`, `02`, `07`, `10`, `11` |
| 5 | Browser captures while waiting | `03`, `04`, `06`, `12` |
| 6 | Return to the slow ones | `05`, `08`, `09`, `13`, `14` |

Overlapping the burn and the failover is deliberate: it puts the CPU spike,
the capacity change and the database failover in a single dashboard frame,
which is what makes `09` a strong image.

---

## Phase 1 — baseline

```powershell
.\docs\failover-evidence.ps1 -Before
```

Saves the current database hostname and AZ placement. **This is
unrecoverable once the failover has happened** — if you skip it, you cannot
produce screenshot 13 without failing over a second time.

---

## Phase 2 — start the CPU burn

```powershell
.\docs\start-burn.ps1
```

Runs `burn-cpu.sh` on every instance in the group, detached, for 25 minutes.
It resolves instance IDs itself and writes the JSON payload for you, so the
quoting problem in Rule 4 cannot bite.

Expect `burn processes: 2` per instance. Note the start time — you will want
it for the write-up.

---

## Phase 3 — trigger the failover

Wait about a minute, then:

```powershell
aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover --query "DBInstance.DBInstanceStatus" --output text
```

Expect `rebooting`. Completion takes 20–40 seconds.

> **Trigger it an odd number of times.** Each failover swaps the AZs, so after
> two the primary is back where it started and the AZ line in screenshot 13
> shows no change. The hostname still differs, but a reader comparing the AZ
> line will think the test failed.

---

## Phase 4 — terminal captures

### 01 · `01-terraform-apply-complete.png`

Screenshot the apply output while it is still on screen:

```
Apply complete! Resources: 65 added, 0 changed, 0 destroyed.
```

If it has scrolled away, regenerate proof from state instead — and caption it
honestly as an inventory, not as the original apply:

```powershell
cd terraform
Write-Host "Resources under Terraform management:" (terraform state list).Count
terraform state list | Select-Object -First 10
terraform output application_url
terraform output rds_multi_az
```

### 02 · `02-ssm-session.png`

```powershell
aws ssm start-session --target <instance-id from evidence-values.ps1>
```

Paste inside the session as one block:

```bash
echo '== reached over SSM: no key pair, no bastion =='; whoami; hostname
T=$(curl -sX PUT -m3 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
echo; echo '== IMDSv1, no token (expect 401) =='; curl -s -m3 -o /dev/null -w 'HTTP %{http_code}\n' http://169.254.169.254/latest/meta-data/placement/availability-zone
echo '== IMDSv2, with token =='; printf 'AZ:         '; curl -s -m3 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/placement/availability-zone; echo
printf 'private IP: '; curl -s -m3 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/local-ipv4; echo
echo; echo '== sshd runs, but no SG permits inbound 22 and there is no public IP =='; ss -tlnp | grep ':22'
```

> **Paste one line at a time.** An SSM session echoes each command back as it
> arrives. Paste a multi-line block and the echo interleaves with the output,
> producing collisions like `AZ:  printfus-east-1a` (the word `printf` merged
> into `us-east-1a`) and `private IP: echo10.0.11.183`. Every value is still
> correct, but the screenshot reads as broken. Press Enter between each line,
> or use the single-line variants below.

Paste-safe version — six separate lines, each self-contained:

```bash
echo '== over SSM: no key pair, no bastion =='; whoami; hostname
T=$(curl -sX PUT -m3 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); echo "token acquired"
echo '== IMDSv1, no token, expect 401 =='; curl -s -m3 -o /dev/null -w 'HTTP %{http_code}
' http://169.254.169.254/latest/meta-data/placement/availability-zone
echo "AZ         : $(curl -s -m3 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
echo "private IP : $(curl -s -m3 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/local-ipv4)"
echo '== sshd runs, but no SG permits 22 and there is no public IP =='; ss -tlnp | grep ':22'
```

Wrapping each value in `echo "label : $(command)"` keeps the label and its
result on one line, so even if the echo interleaves, nothing splits mid-value.

**Must be in frame:** the `Starting session with SessionId: admin-cli-…`
banner, `HTTP 401` for IMDSv1, and the AZ returned for IMDSv2.

**Caption carefully.** Do *not* write "no port 22" — `sshd` genuinely runs on
the AMI, and the output shows it listening. The accurate and stronger claim
is: *no security group permits inbound 22 and the instance has no public IP,
so the port is unreachable. The control is the network, not the host.*

### 07 · `07-alb-listener-rule.png`

```powershell
curl.exe -i --max-time 20 "http://<alb-dns>/admin"
```

**Must be in frame:** `HTTP/1.1 403 Forbidden`, `Server: awselb/2.0`, and the
body `Forbidden - administrative paths are not exposed publicly.`

That body text is your own string from `alb.tf`, which is what proves the 403
came from the listener rule rather than from a web server.

### 10 · `10-cloudfront-cache-headers.png`

```powershell
$cf="<cloudfront-domain>"
"=== dynamic / : CachingDisabled - never cached ==="
1..2 | % { curl.exe -sI --max-time 25 "https://$cf/" | Select-String '^x-cache' }
"=== static /static/logo.svg : CachingOptimized - served from the edge ==="
1..3 | % { curl.exe -sI --max-time 25 "https://$cf/static/logo.svg" | Select-String '^x-cache' }
```

**Expect** `Miss, Miss` for the dynamic path and `Miss, Hit, Hit` (or all
`Hit` if the edge is already warm) for the static one.

Label the sections by *cache policy*, not by predicted outcome. A caption
promising "Miss then Hit" against three `Hit` lines looks like you did not
read your own output.

### 11 · `11-waf-block-curl.png`

**Run this from inside the VPC.** From a laptop it commonly returns
`curl: (52) Empty reply from server` — client-side network inspection
destroys SQL-injection payloads before they ever reach AWS, which is
indistinguishable from WAF being broken.

In the same SSM session as screenshot 02:

Set the host first, on its own line:

```bash
H=http://<alb-dns>
```

Then paste these **one at a time**, waiting for each result:

```bash
echo "benign___ = $(curl -s -o /dev/null -w '%{http_code}' "$H/?id=hello")"
echo "sqli_____ = $(curl -s -o /dev/null -w '%{http_code}' "$H/?id=1%27%20OR%20%271%27=%271")"
echo "xss______ = $(curl -s -o /dev/null -w '%{http_code}' "$H/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")"
echo "traversal = $(curl -s -o /dev/null -w '%{http_code}' "$H/?f=..%2F..%2Fetc%2Fpasswd")"
```

**Expect `200 / 403 / 403 / 403`.** Keep the benign control in frame — it
shows WAF discriminating rather than refusing everything, which is what makes
the shot persuasive.

Cross-check afterwards: `AWS/WAFV2 BlockedRequests` should equal the number of
*attack* probes only. `/admin` is blocked by the ALB listener rule, not WAF,
so it must not appear in that count.

---

## Phase 5 — browser captures

### 03 / 04 · `03-alb-az-a.png` and `04-alb-az-b.png`

Open the ALB URL and hard-refresh with **Ctrl+F5** until the values change. A
plain refresh may serve from browser cache.

| Shot | Shows |
|---|---|
| `03-alb-az-a.png` | an instance in `us-east-1a` |
| `04-alb-az-b.png` | an instance in `us-east-1b` |

**Include the URL bar in both.** The point is that one identical URL returns
two different instances in two different Availability Zones. Without the URL
visible they are just two screenshots of a page.

### 06 · `06-sg-chain.png`

```
https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#SecurityGroup:groupId=<rds-sg-id>
```

Open the **Inbound rules** tab.

**Must be in frame:** one rule, port `3306`, and a Source that reads
`sg-…` — the app tier's security group — **not** a CIDR block.

Caption why: instances come and go and their IPs change constantly, but a
security-group reference stays correct forever. A CIDR rule is either too
broad or immediately stale.

**Bonus if it fits:** the **Outbound rules** tab is empty. The database has no
egress at all.

### 12 · `12-secrets-manager.png`

```
https://us-east-1.console.aws.amazon.com/secretsmanager/secret?name=saa-capstone/rds/master-credentials&region=us-east-1
```

Scroll to **Secret value** → **Retrieve secret value**.

> **Cover the password with a solid fill before saving.** Not a blur — blurs
> on short high-contrast text can sometimes be reversed. This repository is
> public.

Leave `username`, `engine`, `host`, `port` and `dbname` visible. They prove
the structure the instances parse at runtime, and they are already in the
Terraform.

---

## Phase 6 — the slow ones

### 05 · `05-rds-failover-events.png`

```
https://us-east-1.console.aws.amazon.com/rds/home?region=us-east-1#database:id=saa-capstone-mysql;is-cluster=false;tab=logs-and-events
```

Scroll to **Recent events**. Set the range to the last 24 hours if needed.

**Must be in frame:** `Multi-AZ instance failover started` **and**
`Multi-AZ instance failover completed`, with timestamps.

> The console renders event times to the **minute** and in your **browser's
> local timezone**. It establishes ordering, but it cannot substantiate a
> sub-second duration — that is what `05b` is for. If your documentation
> quotes UTC, say so, or the two will look inconsistent.

### 05b · `05b-rds-failover-events-cli.png`

```powershell
aws rds describe-events --source-identifier saa-capstone-mysql --source-type db-instance --duration 20 --query "Events[].[Date,Message]" --output table
```

Full timestamps with milliseconds. Subtract `started` from `completed` for
your measured failover duration — a real number from your own run rather than
a figure quoted from documentation.

> **`--duration` is a lookback window in minutes, not a row count.** Run this
> within a few minutes of the failover and a tight window like `20` gives a
> clean frame containing only the failover events. Leave it an hour and the
> same command returns nothing at all — an empty table, no error. Widen it to
> `240` to find older events, at the cost of including provisioning noise
> (instance created, Multi-AZ conversion, automated backups).

### 08 · `08-asg-scaling-activity.png`

```
https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#AutoScalingGroupDetails:id=<asg-name>;view=activity
```

**Widen or expand the `Cause` column before shooting.** That column holds the
sentence that turns this into evidence:

> *a monitor alarm TargetTracking-…-AlarmHigh in state ALARM triggered policy
> saa-capstone-cpu-target-50 changing the desired capacity from 2 to 4*

**Capture every row, not just the launches.** Scale-out goes `2 → 4` in a
single step while scale-in steps down `4 → 3 → 2` individually — and that
asymmetry is the most interesting thing on the page. Scaling out too little
costs money; scaling in too eagerly costs availability, so AWS treats the two
directions differently.

### 09 · `09-cloudwatch-dashboard.png`

```powershell
cd terraform; terraform output dashboard_url
```

Set the time range to **Last 1 hour**.

This is the hero image. If the burn and failover overlapped, one frame
contains the CPU spike, the capacity step from 2 to 4, and the database
failover.

Read the CPU curve as three levels — it is the clearest thing in the whole
evidence set:

| Level | Meaning |
|---|---|
| ~100% | 2 instances, both pinned |
| **~50%** | 4 instances: 2 burning + 2 idle |
| ~0% | load ended |

That middle step is target tracking's arithmetic made visible. It did not
drift toward 50% — it *landed* there, because `(100+100+0+0)/4 = 50`, exactly
the configured target. A grader can read the policy setting straight off the
graph.

Also point at the brief `UnHealthyHostCount` spike when the new instances
appear: registered but still bootstrapping, not yet passing `/health`. That is
precisely why the group uses **ELB** health checks rather than EC2 ones.

### 13 · `13-dbstatus-before-after-failover.png`

Wait about 3 minutes after the failover — the probe runs on a 2-minute timer —
then:

```powershell
.\docs\failover-evidence.ps1
```

**Must be in frame:** a changed `server=` hostname, and swapped AZs.

Press Enter a few times first so the block sits clear of earlier scrollback.

> If the AZ line looks unchanged, you have failed over an even number of
> times. Trigger one more and re-run.

### 14 · `14-sns-alarm-email.png`

Gmail → `in:anywhere from:no-reply@sns.amazonaws.com`

Capture the **`ALARM: "saa-capstone-asg-high-cpu"`** message, framing the
subject line and the body showing the alarm name, threshold and reason.

Click **Report not spam** first — it trains Gmail and makes the screenshot
cleaner.

---

## Before you tear down

```powershell
Get-ChildItem docs\screenshots\*.png | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB)}}
```

You want **15 files**: `01`–`14` plus `05b`.

Then export the artifacts that only exist while the stack is live:

```powershell
cd terraform
terraform output > ..\docs\terraform-outputs.txt
terraform state list > ..\docs\terraform-resources.txt
```

Finally, re-read `12-secrets-manager.png` with your own eyes and confirm the
password is covered. A file called "secrets-manager.png" in a public
repository is the one worth checking twice.

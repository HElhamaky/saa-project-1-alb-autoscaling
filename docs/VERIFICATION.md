# Live verification results

Captured against the deployed stack on **2026-08-27 / 28**, region `us-east-1`,
account `074189218557`. Every result below is reproducible with the commands
shown — they are the same ones `terraform output demo_commands` prints.

`terraform apply` completed with **63 added, 0 changed, 0 destroyed** and no
warnings.

---

## 1. Load balancing across two Availability Zones

```bash
for i in $(seq 1 8); do curl -s http://<alb-dns>/ | grep -o 'us-east-1[ab]'; done | sort | uniq -c
```

| AZ | Requests |
|---|---|
| `us-east-1a` | 4 |
| `us-east-1b` | 4 |

An even split across both AZs over eight requests. The instance serving each
request reports its own instance ID, AZ and private IP, so the page itself is
the evidence — e.g. `i-0289948e305373af7`, `us-east-1b`, `10.0.12.167`, which
is inside the `10.0.12.0/24` app subnet.

## 2. The private app tier reaches the Multi-AZ database

```bash
curl -s http://<alb-dns>/dbstatus.txt
```

```
2026-08-27T18:55:14Z  OK  endpoint=saa-capstone-mysql.<...>.rds.amazonaws.com
                          server=ip-172-16-5-83  8.0.46  0  tls=enforced
```

`0` is `@@read_only` — the instance serving the query is the writer, not the
standby. `tls=enforced` follows from the connection succeeding at all: the
parameter group sets `require_secure_transport = ON`, so a plaintext
connection would have been rejected by the server.

### The probe self-healed, which is the point of the timer

The first observation, minutes earlier, was:

```
2026-08-27T18:53:31Z  PENDING  secret not readable yet:
  ResourceNotFoundException ... staging label: AWSCURRENT
```

The instances booted before RDS had finished provisioning, so the Secrets
Manager *secret version* did not exist yet. Because the probe runs on a
systemd timer rather than once at boot, the next tick two minutes later
succeeded with no intervention. Had it been a one-shot bootstrap step, every
instance would have been permanently stuck reporting a failure that had
already resolved itself.

## 3. WAF and the ALB listener rule

**Run these from inside the VPC — see the warning below.**

```bash
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -s -o /dev/null -w %{http_code} \"http://<alb-dns>/?id=1%27%20OR%20%271%27=%271\""]'
```

| Probe | Status | Blocked by |
|---|---|---|
| benign `?id=hello` | `200` | — (allowed) |
| SQL injection | `403` | `AWSManagedRulesSQLiRuleSet` |
| XSS `<script>alert(1)</script>` | `403` | `AWSManagedRulesCommonRuleSet` |
| path traversal `../../etc/passwd` | `403` | Common / known-bad-inputs |
| `/admin` | `403` | ALB listener rule, priority 10 |

CloudWatch `AWS/WAFV2 BlockedRequests` recorded **3** for that window — the
SQLi, XSS and traversal probes. `/admin` is deliberately *not* among them: it
is terminated by the ALB listener rule before WAF's managed groups matter,
which is exactly the intended split. The count is a useful cross-check that
the two controls are doing separate jobs.

> ### Test WAF from inside AWS, not from your laptop
>
> Running the SQL injection probe from a local machine returned
> `curl: (52) Empty reply from server`, with no HTTP status at all. That is
> not WAF. WAF's sampled-request log showed the benign request arriving and
> being allowed, while **the malicious request never appeared at all** — it
> was dropped on the client network (antivirus web shield, corporate
> inspection or ISP DPI) before it ever reached AWS.
>
> Symptom to recognise: a connection-level failure (`empty reply`, `connection
> reset`) rather than a clean `403`. A WAF block always returns a real HTTP
> status. Route the test through SSM as above and the result is unambiguous.

## 4. CloudFront cache split

```bash
curl -sI https://<cf-domain>/               | grep -i x-cache   # x2
curl -sI https://<cf-domain>/static/logo.svg | grep -i x-cache   # x3
```

| Path | Request 1 | Request 2 | Request 3 |
|---|---|---|---|
| `/` (dynamic) | `Miss from cloudfront` | `Miss from cloudfront` | — |
| `/static/logo.svg` | `Miss from cloudfront` | `Hit from cloudfront` | `Hit from cloudfront` |

Dynamic HTML misses on every request under `CachingDisabled`, so each user
reaches a real instance and the load balancer keeps doing its job. The static
asset is served from the edge from the second request onward under
`CachingOptimized`. This split is the whole reason the distribution exists.

## 5. Bastion-free administrative access

```bash
aws ssm describe-instance-information --filters Key=InstanceIds,Values=<id>
```

```
Online    Amazon Linux    3.3.4624.0
```

The instance is fully manageable — the WAF probes in §3 were executed on it
via `ssm send-command` — with **no inbound port 22 rule anywhere in the
architecture, no key pair and no bastion host**. Access is authorised by IAM
and every session is logged.

---

## 6. RDS Multi-AZ forced failover

```bash
curl -s http://<alb-dns>/dbstatus.txt          # capture BEFORE - unrecoverable after
aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover
```

| | Before | After |
|---|---|---|
| Database server hostname | `ip-172-16-5-83` | `ip-172-16-1-167` |
| Primary AZ | `us-east-1a` | `us-east-1b` |
| Standby AZ | `us-east-1b` | `us-east-1a` |

The AZs swapped, which is the point: the standby was promoted in place and the
old primary became the new standby. The endpoint DNS name never changed, so
the application needed no reconfiguration - that is what the writer endpoint
buys you.

### Measured failover duration: 38.7 seconds

From the RDS event log:

```
15:37:12.882  Multi-AZ instance failover started.
15:37:28.177  DB instance restarted
15:37:51.533  Multi-AZ instance failover completed
```

`15:37:51.533 - 15:37:12.882 = 38.7s`, comfortably inside the 60-120s RTO that
AWS documents. Measured end to end from the API call at `15:37:01`, it was
50.5 seconds.

The app tier observed the change between `15:38:39` (still reporting the old
host) and `15:39:44` (reporting the new one). That gap reflects the **probe's
own 2-minute timer**, not database downtime - a useful reminder that your
observation interval sets a floor on how precisely you can measure an outage.

## 7. Auto Scaling under load

```bash
aws ssm send-command --instance-ids <both ids> --document-name AWS-RunShellScript   --parameters 'commands=["setsid nohup /usr/local/bin/burn-cpu.sh 1200 >/dev/null 2>&1 </dev/null &"]'
```

| Event | Time (UTC) | Elapsed from load start |
|---|---|---|
| CPU load started on both instances | `15:36:12` | - |
| `saa-capstone-asg-high-cpu` alarm -> ALARM | `15:39:44` | 3m 32s |
| Target-tracking policy fired, desired 2 -> 4 | `15:40:41` | 4m 29s |
| Both new instances launched | `15:40:55` | 4m 43s |
| All 4 instances InService | `15:41:53` | **5m 41s** |

```
At 2026-08-28T15:40:41Z a monitor alarm TargetTracking-...-AlarmHigh in state
ALARM triggered policy saa-capstone-cpu-target-50 changing the desired
capacity from 2 to 4.
```

Note the policy jumped straight from 2 to 4 rather than stepping. Target
tracking computes the capacity needed to reach the target rather than nudging
by a fixed increment: with two instances pinned near 100% against a 50%
target, the required capacity is `2 x (100/50) = 4`. Step scaling would have
added one instance at a time and taken far longer to converge.

The new instances landed one per AZ, so the group stayed balanced at 2+2
without anyone asking for it.

### The alarm cleared while the load was still running

The alarm returned to OK at `15:48:24`, roughly eight minutes before the CPU
burn was due to end. That is not a fault - it is the control loop converging.
Only the two original instances were burning CPU; the two new ones were idle.
Average CPU across the group became `(100 + 100 + 0 + 0) / 4 = 50%`, which is
exactly the target. The system stopped scaling because it had arrived, and
watching the arithmetic land on the target value is the clearest possible
demonstration of what "target tracking" actually means.

### Scale-in: 4 -> 3 -> 2, one instance at a time

Once the load stopped, the group returned to its baseline:

```
16:12:46  AlarmLow triggered saa-capstone-cpu-target-50, desired 4 -> 3
16:13:19  AlarmLow triggered saa-capstone-cpu-target-50, desired 3 -> 2
```

Note the asymmetry against the scale-out, which went straight from 2 to 4 in a
single step. **Scaling out is aggressive; scaling in is deliberate.** Removing
capacity too eagerly risks thrashing - terminating an instance only to need it
again a minute later - and every termination costs a warm-up on the way back.
Being wrong about scale-out costs money; being wrong about scale-in costs
availability, so AWS treats the two directions differently.

The group ended balanced at one instance per AZ without intervention.

Full minute-by-minute timeline: [`evidence-timeline.txt`](evidence-timeline.txt)

---

## Not yet captured

- Console screenshots (see [`EVIDENCE-CHECKLIST.md`](EVIDENCE-CHECKLIST.md))
- SNS alarm notification email - the subscription was still
  `PendingConfirmation` when the CPU alarm fired, so no email was delivered.
  An unconfirmed SNS subscription drops notifications silently.

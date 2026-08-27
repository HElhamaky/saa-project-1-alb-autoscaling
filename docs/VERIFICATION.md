# Live verification results

Captured against the deployed stack on **2026-08-27**, region `us-east-1`,
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

## Not yet captured

- Auto Scaling reacting to the CPU target-tracking policy
  (`/usr/local/bin/burn-cpu.sh`)
- RDS Multi-AZ forced failover, before/after `dbstatus.txt` hostname change
- CloudWatch dashboard with the CPU spike and capacity increase in one frame
- SNS alarm notification email

See [`EVIDENCE-CHECKLIST.md`](EVIDENCE-CHECKLIST.md).

# Architecture Diagram Spec

> **A finished diagram already ships with this repo** at
> [`architecture.svg`](architecture.svg) — hand-authored SVG, so it renders
> inline on GitHub, stays diffable in version control, and needs no binary
> asset. This spec is kept for two reasons: it documents *why* the diagram is
> laid out the way it is, and it is the checklist to follow if you would
> rather redraw it yourself with official AWS iconography.

---

## Redrawing it by hand (~45 minutes)

Use **draw.io** (app.diagrams.net). Enable the AWS shape library:
`More Shapes… → Networking → AWS 19` (or AWS 2023), then Apply.

Export as **PNG at 300 DPI** to `docs/architecture.png`, save the `.drawio`
source next to it, and update the image link in the README.

---

## Layout — five horizontal bands

Draw it top to bottom. Each band is a row across the page.

```
┌─────────────────────────────────────────────────────────────────────┐
│ BAND 0 · Internet / Edge                                             │
│  [ User ] ─► [ Route 53 ]* ─► [ CloudFront ] ─► [ WAF ]              │
│  (* Route 53 dashed = written but not applied, no domain)            │
└─────────────────────────────────────────────────────────────────────┘
        │
┌───────┼─────────────────────────────────────────────────────────────┐
│ AWS Cloud  (outer container, region label: us-east-1)                │
│ ┌───────────────────────────────────────────────────────────────┐   │
│ │ VPC  10.0.0.0/16                                              │   │
│ │                                                               │   │
│ │  ┌─────────── AZ us-east-1a ──────┐ ┌───── AZ us-east-1b ───┐ │   │
│ │  │ BAND 1 · PUBLIC 10.0.1.0/24    │ │ PUBLIC 10.0.2.0/24    │ │   │
│ │  │   [NAT Gateway]                │ │                       │ │   │
│ │  │   [ALB node]  ◄───────────────────► [ALB node]           │ │   │
│ │  ├────────────────────────────────┤ ├───────────────────────┤ │   │
│ │  │ BAND 2 · APP 10.0.11.0/24      │ │ APP 10.0.12.0/24      │ │   │
│ │  │   [EC2]  (inside ASG boundary) │ │   [EC2]               │ │   │
│ │  ├────────────────────────────────┤ ├───────────────────────┤ │   │
│ │  │ BAND 3 · DATA 10.0.21.0/24     │ │ DATA 10.0.22.0/24     │ │   │
│ │  │   [RDS primary]  ══sync══════════►  [RDS standby]        │ │   │
│ │  └────────────────────────────────┘ └───────────────────────┘ │   │
│ └───────────────────────────────────────────────────────────────┘   │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ BAND 4 · Management & Observability (full width, outside the VPC)│ │
│ │  [Systems Manager]  [Secrets Manager]                            │ │
│ │  [CloudWatch]  [SNS]                                             │ │
│ └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Elements checklist

Tick each one off. This is the list a grader scans for.

**Containers (draw these first, as nested boxes)**
- [ ] AWS Cloud container, labelled with the region
- [ ] VPC container, labelled `10.0.0.0/16`
- [ ] Two AZ containers, labelled `us-east-1a` / `us-east-1b`
- [ ] Six subnet containers, each labelled with its **CIDR and tier name**
- [ ] Auto Scaling Group boundary (dashed) drawn around both EC2 instances

**Icons**
- [ ] CloudFront, above the VPC (it is a global service — do not draw it
      inside the VPC, that is the most common mistake on this diagram)
- [ ] WAF, between CloudFront and the ALB
- [ ] Internet Gateway, on the VPC boundary
- [ ] NAT Gateway, in the public subnet of AZ-a **only** (deliberate)
- [ ] Application Load Balancer, spanning both public subnets
- [ ] 2 × EC2, one per app subnet
- [ ] RDS primary in data subnet a, RDS standby in data subnet b
- [ ] Systems Manager, Secrets Manager, CloudWatch, SNS in Band 4

**Arrows — label every one**
- [ ] `User → CloudFront` labelled **HTTPS :443**
- [ ] `CloudFront → WAF → ALB` labelled **HTTP :80 (origin)**
- [ ] `ALB → EC2` labelled **:80 (SG reference, not CIDR)**
- [ ] `EC2 → RDS` labelled **:3306 TLS required**
- [ ] `EC2 → NAT → IGW` labelled **outbound only**
- [ ] `RDS primary → RDS standby` labelled **synchronous replication**
- [ ] `Systems Manager → EC2` labelled **Session Manager (no inbound port)**
- [ ] `Secrets Manager → EC2` labelled **DB credentials at runtime**
- [ ] `CloudWatch → SNS` labelled **alarms**

**Annotations — four text callouts. These separate a good diagram from a
generic one.**
- [ ] On CloudFront: *"`/static/*` cached · `*` CachingDisabled — dynamic HTML
      must never be cached"*
- [ ] On the data subnets: *"No route to NAT or IGW — database cannot reach
      the internet"*
- [ ] On the NAT Gateway: *"Single NAT — cost optimisation, documented
      tradeoff vs one-per-AZ"*
- [ ] On the app subnets: *"No SSH ingress anywhere in this architecture"*

---

## Three things that lose marks

1. **Unlabelled arrows.** An arrow with no port and no protocol says nothing.
2. **CloudFront drawn inside the VPC.** It is a global edge service and sits
   outside both the VPC and the region boundary.
3. **Drawing Route 53 as if deployed** when it is not. Draw it dashed with a
   legend entry. Being explicit about scope is treated as rigour; pretending
   is not.

## Legend (bottom-right corner)

```
──────  deployed and verified
- - - -  written but not applied (see README §Scope)
══════  synchronous replication
```

#!/bin/bash
set -euxo pipefail

dnf update -y
# mariadb105 provides /usr/bin/mysql; jq parses the Secrets Manager payload.
dnf install -y nginx mariadb105 jq

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)
LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

cat > /usr/share/nginx/html/index.html <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><title>${project_name}</title>
<style>
 body{font-family:ui-sans-serif,system-ui,sans-serif;background:#0f172a;color:#e2e8f0;
      display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
 .card{background:#1e293b;padding:2.5rem 3rem;border-radius:12px;
       border:1px solid #334155;box-shadow:0 20px 40px rgba(0,0,0,.4)}
 h1{margin:0 0 1.5rem;font-size:1.25rem;color:#38bdf8;letter-spacing:.02em}
 table{border-collapse:collapse}
 td{padding:.45rem 1.25rem .45rem 0;font-size:.95rem}
 td:first-child{color:#94a3b8}
 td:last-child{font-family:ui-monospace,monospace;color:#f1f5f9}
 a{color:#38bdf8}
 p{margin:1.5rem 0 0;font-size:.85rem;color:#94a3b8}
</style></head>
<body><div class="card">
<h1>${project_name} &mdash; application tier</h1>
<table>
<tr><td>Instance ID</td><td>$INSTANCE_ID</td></tr>
<tr><td>Availability Zone</td><td>$AZ</td></tr>
<tr><td>Private IP</td><td>$LOCAL_IP</td></tr>
<tr><td>Subnet tier</td><td>private / no public IP</td></tr>
<tr><td>Served via</td><td>ALB &rarr; WAF</td></tr>
</table>
<p>Database connectivity: <a href="/dbstatus.txt">/dbstatus.txt</a></p>
</div></body></html>
HTML

# A real static asset, so the CloudFront /static/* cache behaviour has
# something to cache and the Hit/Miss difference can be demonstrated.
mkdir -p /usr/share/nginx/html/static
cat > /usr/share/nginx/html/static/logo.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="120" height="120">
  <rect width="120" height="120" rx="16" fill="#0f172a"/>
  <path d="M28 78 L60 30 L92 78 Z" fill="none" stroke="#38bdf8" stroke-width="6"
        stroke-linejoin="round"/>
  <circle cx="60" cy="88" r="6" fill="#38bdf8"/>
</svg>
SVG

# Health check endpoint kept separate from / so the target group check does
# not depend on the page rendering correctly.
echo "healthy" > /usr/share/nginx/html/health

systemctl enable --now nginx

###############################################################################
# Database connectivity probe.
#
# Provisioning RDS proves nothing on its own - this proves the application
# tier can actually reach it. The probe:
#   * reads the master credentials from Secrets Manager at runtime, using the
#     instance role. Nothing is baked into the AMI or written to disk.
#   * passes the password via MYSQL_PWD, not argv, so it never appears in `ps`.
#   * connects with --ssl. The server has require_secure_transport = ON, so a
#     plaintext connection would be rejected outright - a successful query is
#     itself the proof that the link is TLS.
#
# It runs on a systemd timer rather than once at boot, so an instance that
# starts before RDS has finished provisioning heals itself instead of being
# stuck reporting a failure. Every path exits 0: a database problem must never
# fail the ALB health check and cause the ASG to churn instances.
###############################################################################
cat > /usr/local/bin/db-check.sh <<'DBCHECK'
#!/bin/bash
set -uo pipefail
OUT=/usr/share/nginx/html/dbstatus.txt
STAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_name}" --region "${aws_region}" \
  --query SecretString --output text 2>&1) || {
  echo "$STAMP  PENDING  secret not readable yet: $SECRET" > "$OUT"; exit 0; }

HOST=$(jq -r .host <<<"$SECRET")
USERNAME=$(jq -r .username <<<"$SECRET")
PASSWORD=$(jq -r .password <<<"$SECRET")
DBNAME=$(jq -r .dbname <<<"$SECRET")

ROW=$(MYSQL_PWD="$PASSWORD" mysql --ssl -h "$HOST" -u "$USERNAME" "$DBNAME" \
  -N -B -e "SELECT @@hostname, @@version, @@read_only;" 2>&1) || {
  echo "$STAMP  UNREACHABLE  $HOST : $ROW" > "$OUT"; exit 0; }

echo "$STAMP  OK  endpoint=$HOST  server=$ROW  tls=enforced" > "$OUT"
DBCHECK
chmod +x /usr/local/bin/db-check.sh

cat > /etc/systemd/system/db-check.service <<'UNIT'
[Unit]
Description=Verify application-tier connectivity to the RDS instance
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/db-check.sh
UNIT

cat > /etc/systemd/system/db-check.timer <<'UNIT'
[Unit]
Description=Re-run the RDS connectivity probe every two minutes

[Timer]
OnBootSec=45
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
UNIT

echo "pending first probe" > /usr/share/nginx/html/dbstatus.txt
systemctl daemon-reload
systemctl enable --now db-check.timer

# CPU load endpoint - used to trigger the target-tracking scaling policy
# during the demo without needing to SSH in and run stress manually.
cat > /usr/local/bin/burn-cpu.sh <<'BURN'
#!/bin/bash
DURATION=$${1:-300}
CORES=$(nproc)
for i in $(seq 1 $CORES); do
  timeout "$DURATION" bash -c 'while :; do :; done' &
done
wait
BURN
chmod +x /usr/local/bin/burn-cpu.sh

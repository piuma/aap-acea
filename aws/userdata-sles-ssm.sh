#!/bin/bash
#
# cloud-init user-data per SUSE Linux Enterprise Server 15 su AWS.
# Prepara la VM a essere gestita da AAP via Session Manager:
#   - installa e avvia amazon-ssm-agent
#   - assicura la presenza di python3 (richiesto dai moduli Ansible)
#
# Log: /var/log/cloud-init-output.log
set -euxo pipefail

exec > >(tee -a /var/log/aap-bootstrap.log) 2>&1
echo "=== bootstrap AAP/SSM: $(date -Is) ==="

# IMDSv2 (l'istanza viene lanciata con HttpTokens=required)
IMDS_TOKEN="$(curl -sf -X PUT 'http://169.254.169.254/latest/api/token' \
              -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)"
REGION="$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
          'http://169.254.169.254/latest/meta-data/placement/region' || true)"
echo "regione rilevata: ${REGION:-sconosciuta}"

# ---------------------------------------------------------------------------
# Python 3 — i moduli Ansible non girano senza
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  zypper --non-interactive refresh || true
  zypper --non-interactive install -y python3-base
fi
python3 --version

# ---------------------------------------------------------------------------
# SSM Agent
# ---------------------------------------------------------------------------
# Strada 1: pacchetto dai repository SUSE (modulo Public Cloud, gia' abilitato
# sulle AMI on-demand registrate agli RMT di AWS).
if ! rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  zypper --non-interactive refresh || true
  if ! zypper --non-interactive install -y amazon-ssm-agent; then
    # Strada 2: RPM ufficiale AWS della regione corrente.
    echo "pacchetto SUSE non disponibile, installo l'RPM AWS"
    AGENT_URL="https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/linux_amd64/amazon-ssm-agent.rpm"
    curl -fsSL -o /tmp/amazon-ssm-agent.rpm "$AGENT_URL" \
      || curl -fsSL -o /tmp/amazon-ssm-agent.rpm \
         "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm"
    zypper --non-interactive --no-gpg-checks install -y /tmp/amazon-ssm-agent.rpm
    rm -f /tmp/amazon-ssm-agent.rpm
  fi
fi

systemctl enable --now amazon-ssm-agent
systemctl is-active amazon-ssm-agent

# ---------------------------------------------------------------------------
# Controlli finali
# ---------------------------------------------------------------------------
# L'SSM Agent crea l'utente ssm-user e il relativo sudoers: il connection
# plugin aws_ssm entra come ssm-user e poi usa `become` per diventare root.
id ssm-user || echo "ssm-user non ancora creato: lo fara' l'agent alla prima sessione"

echo "=== bootstrap completato: $(date -Is) ==="

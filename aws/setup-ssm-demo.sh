#!/usr/bin/env bash
#
# Prepara su AWS tutto quello che serve alla demo AAP + SSM:
#
#   1. bucket S3 di transito per il connection plugin aws_ssm
#   2. ruolo IAM + instance profile per le EC2 (SSM Core + accesso al bucket)
#   3. policy IAM gestita da assegnare all'utente/ruolo usato da AAP
#   4. (opzionale) una EC2 SUSE SLES 15 senza IP pubblico e senza chiave SSH
#
# Uso:
#   ./setup-ssm-demo.sh
#   ./setup-ssm-demo.sh --with-instance
#   REGION=eu-west-1 BUCKET=mio-bucket ./setup-ssm-demo.sh --with-instance
#   ./setup-ssm-demo.sh --teardown
#
# Prerequisiti: aws cli v2 configurata con permessi IAM/S3/EC2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGION="${REGION:-eu-south-1}"
PREFIX="${PREFIX:-aap-acea}"
BUCKET="${BUCKET:-}"
ROLE_NAME="${ROLE_NAME:-${PREFIX}-ssm-ec2-role}"
PROFILE_NAME="${PROFILE_NAME:-${PREFIX}-ssm-ec2-profile}"
CONTROLLER_POLICY="${CONTROLLER_POLICY:-${PREFIX}-aap-controller-policy}"
SG_NAME="${SG_NAME:-${PREFIX}-ssm-egress-only}"
INSTANCE_NAME="${INSTANCE_NAME:-${PREFIX}-sles15-demo-01}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
SUBNET_ID="${SUBNET_ID:-}"

WITH_INSTANCE=false
TEARDOWN=false
for arg in "$@"; do
  case "$arg" in
    --with-instance) WITH_INSTANCE=true ;;
    --teardown)      TEARDOWN=true ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $arg" >&2; exit 2 ;;
  esac
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-${PREFIX}-ssm-transfer-${ACCOUNT_ID}-${REGION}}"

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '    \033[0;32m+\033[0m %s\n' "$*"; }

# ===========================================================================
# Teardown
# ===========================================================================
if [[ "$TEARDOWN" == "true" ]]; then
  say "Teardown (gli errori 'does not exist' sono attesi)"
  aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running,stopped,pending" \
      --query 'Reservations[].Instances[].InstanceId' --output text \
    | tr '\t' '\n' | while read -r iid; do
        [[ -n "$iid" ]] && aws ec2 terminate-instances --region "$REGION" --instance-ids "$iid" >/dev/null && ok "terminata $iid"
      done
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "${PREFIX}-ssm-bucket-access" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CONTROLLER_POLICY}" 2>/dev/null || true

  # Il bucket NON viene cancellato per default: potrebbe essere un bucket
  # preesistente passato con BUCKET=..., e `rb --force` svuota tutto.
  if [[ "${DELETE_BUCKET:-false}" == "true" ]]; then
    printf '\n\033[1;31mSto per svuotare e cancellare s3://%s\033[0m\n' "$BUCKET"
    read -r -p "Scrivi il nome del bucket per confermare: " CONFERMA
    if [[ "$CONFERMA" == "$BUCKET" ]]; then
      aws s3 rb "s3://${BUCKET}" --force --region "$REGION" && ok "bucket cancellato"
    else
      echo "    nome non corrispondente: bucket lasciato intatto"
    fi
  else
    ok "bucket s3://${BUCKET} lasciato intatto (DELETE_BUCKET=true per cancellarlo)"
  fi

  say "Teardown completato"
  exit 0
fi

say "Account ${ACCOUNT_ID} / regione ${REGION}"

# ===========================================================================
# 1. Bucket S3 di transito
# ===========================================================================
say "Bucket di transito: s3://${BUCKET}"
BUCKET_PREESISTENTE=false
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  BUCKET_PREESISTENTE=true
  ok "esiste gia'"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  ok "creato"
fi

if [[ "$BUCKET_PREESISTENTE" == "true" ]]; then
  # Su un bucket che non abbiamo creato noi non tocchiamo NULLA: sovrascrivere
  # cifratura, public access block o lifecycle di un bucket altrui e' una
  # modifica distruttiva che nessuno ci ha chiesto. Ci limitiamo a riportare la
  # configurazione, perche' e' quella che decide se il plugin funzionera'.
  say "Configurazione attuale del bucket (nessuna modifica applicata)"

  echo "  default encryption:"
  aws s3api get-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
    --query 'ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault' \
    --output table 2>/dev/null || echo "    nessuna default encryption configurata"

  echo "  versioning:"
  echo "    $(aws s3api get-bucket-versioning --bucket "$BUCKET" --region "$REGION" \
       --query 'Status' --output text 2>/dev/null || echo Disabled)"

  echo "  bucket policy:"
  BUCKET_POLICY="$(aws s3api get-bucket-policy --bucket "$BUCKET" --region "$REGION" \
                   --query Policy --output text 2>/dev/null || true)"
  if [[ -z "$BUCKET_POLICY" ]]; then
    echo "    nessuna bucket policy"
  elif grep -q 'server-side-encryption-customer-algorithm' <<<"$BUCKET_POLICY"; then
    cat <<'WARN'
    *** La policy IMPONE SSE-C ***
    Il connection plugin aws_ssm non sa emettere gli header SSE-C: i task `raw`
    funzioneranno, ogni modulo Ansible fallira' con 403.
    Serve un bucket di transito dedicato con SSE-S3 o SSE-KMS.
    Dettagli e alternative: aws/README.md, sezione "SSE-C".
WARN
  else
    echo "    presente, non impone SSE-C"
  fi
else
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
  ok "accesso pubblico bloccato"

  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null
  ok "cifratura SSE-S3 (AES256) attiva"

  # Il versioning resta DISABILITATO di proposito: il plugin aws_ssm cancella
  # gli oggetti temporanei, ma con il versioning le vecchie versioni resterebbero.
  aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
    --lifecycle-configuration '{"Rules":[{"ID":"expire-ansible-transfers","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":1},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' >/dev/null
  ok "lifecycle: cancellazione automatica dopo 1 giorno"
fi

# ===========================================================================
# 2. Ruolo IAM + instance profile per le EC2
# ===========================================================================
say "Ruolo IAM per le EC2: ${ROLE_NAME}"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "Permette alle EC2 di registrarsi in SSM e usare il bucket di transito Ansible" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  ok "ruolo creato"
else
  ok "ruolo gia' presente"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
ok "AmazonSSMManagedInstanceCore agganciata"

sed "s|BUCKET_NAME|${BUCKET}|g" "${SCRIPT_DIR}/iam-policy-ec2-instance.json" > /tmp/ec2-bucket-policy.json
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "${PREFIX}-ssm-bucket-access" \
  --policy-document file:///tmp/ec2-bucket-policy.json >/dev/null
ok "policy inline sul bucket applicata"

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null
  ok "instance profile creato — attendo la propagazione IAM"
  sleep 15
else
  ok "instance profile gia' presente"
fi

# ===========================================================================
# 3. Policy per il controller AAP
# ===========================================================================
say "Policy per il controller AAP: ${CONTROLLER_POLICY}"
sed -e "s|BUCKET_NAME|${BUCKET}|g" \
    -e "s|ACCOUNT_ID|${ACCOUNT_ID}|g" \
    -e "s|REGION|${REGION}|g" \
    "${SCRIPT_DIR}/iam-policy-aap-controller.json" > /tmp/aap-controller-policy.json

CONTROLLER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CONTROLLER_POLICY}"
if aws iam get-policy --policy-arn "$CONTROLLER_POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy-version --policy-arn "$CONTROLLER_POLICY_ARN" \
    --policy-document file:///tmp/aap-controller-policy.json --set-as-default >/dev/null
  ok "nuova versione pubblicata"
else
  aws iam create-policy --policy-name "$CONTROLLER_POLICY" \
    --description "Permessi per AAP: inventario EC2, sessioni SSM, bucket di transito" \
    --policy-document file:///tmp/aap-controller-policy.json >/dev/null
  ok "policy creata"
fi

# ===========================================================================
# 4. Istanza SUSE di prova (opzionale)
# ===========================================================================
if [[ "$WITH_INSTANCE" == "true" ]]; then
  say "Istanza SUSE di prova: ${INSTANCE_NAME}"

  if [[ -z "$SUBNET_ID" ]]; then
    VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
              --query 'Vpcs[0].VpcId' --output text)"
    SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" \
                 --filters "Name=vpc-id,Values=${VPC_ID}" \
                 --query 'Subnets[0].SubnetId' --output text)"
    ok "uso la VPC di default ${VPC_ID}, subnet ${SUBNET_ID}"
  fi
  VPC_ID="$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET_ID" \
            --query 'Subnets[0].VpcId' --output text)"

  # Security group senza regole in ingresso: SSM usa solo traffico in uscita su 443.
  SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
           --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
           --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID="$(aws ec2 create-security-group --region "$REGION" \
             --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
             --description "Solo egress: accesso via Session Manager" \
             --query GroupId --output text)"
    ok "security group ${SG_ID} creato (nessuna porta aperta in ingresso)"
  else
    ok "security group ${SG_ID} gia' presente"
  fi

  # AMI SLES 15: prima il parametro pubblico SSM di SUSE, altrimenti describe-images.
  AMI_ID="$(aws ssm get-parameters --region "$REGION" \
            --names /aws/service/suse/sles/15-sp6/x86_64/latest \
            --query 'Parameters[0].Value' --output text 2>/dev/null || true)"
  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    AMI_ID="$(aws ec2 describe-images --region "$REGION" --owners amazon \
              --filters 'Name=name,Values=suse-sles-15-sp*-v*-hvm-ssd-x86_64' \
                        'Name=state,Values=available' \
              --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)"
  fi
  [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]] && { echo "Nessuna AMI SLES trovata in ${REGION}" >&2; exit 1; }
  ok "AMI ${AMI_ID}"

  INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=${PROFILE_NAME}" \
    --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
    --user-data "file://${SCRIPT_DIR}/userdata-sles-ssm.sh" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=AnsibleManaged,Value=true},{Key=OS,Value=sles},{Key=Environment,Value=demo},{Key=Role,Value=webserver}]" \
    --query 'Instances[0].InstanceId' --output text)"
  ok "istanza ${INSTANCE_ID} avviata"

  say "Attendo la registrazione in Systems Manager (può richiedere 2-5 minuti)"
  for i in $(seq 1 40); do
    PING="$(aws ssm describe-instance-information --region "$REGION" \
            --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"
    if [[ "$PING" == "Online" ]]; then ok "registrata in SSM"; break; fi
    printf '    ... tentativo %s/40 (stato: %s)\n' "$i" "$PING"
    sleep 15
  done
fi

# ===========================================================================
# Riepilogo
# ===========================================================================
cat <<EOF

────────────────────────────────────────────────────────────────────────────
 Setup completato
────────────────────────────────────────────────────────────────────────────
 Regione                : ${REGION}
 Bucket di transito     : ${BUCKET}
 Instance profile EC2   : ${PROFILE_NAME}
 Policy per AAP         : ${CONTROLLER_POLICY_ARN}
EOF
[[ "$WITH_INSTANCE" == "true" ]] && echo " Istanza di prova       : ${INSTANCE_ID:-n/d}"
cat <<EOF

 Prossimi passi
 1. Aggancia ${CONTROLLER_POLICY} all'utente/ruolo IAM usato dalla credential
    "Amazon Web Services" di AAP.
 2. Aggiorna inventory/group_vars/all.yml:
       aws_region: ${REGION}
       ssm_transfer_bucket: ${BUCKET}
 3. Verifica il setup:
       ansible-playbook playbooks/99_preflight_check.yml \\
         -e aws_region=${REGION} -e ssm_transfer_bucket=${BUCKET} \\
         -e target_instance_id=${INSTANCE_ID:-i-xxxxxxxx}
────────────────────────────────────────────────────────────────────────────
EOF

#!/usr/bin/env bash
#
# Build e push dell'Execution Environment custom.
#
#   ./build.sh                                   # build locale, tag :latest
#   IMAGE_TAG=1.2.0 ./build.sh                   # tag esplicito
#   REGISTRY=quay.io/acea PUSH=true ./build.sh   # build + push
#
# Prerequisiti:
#   pip install ansible-builder
#   podman login registry.redhat.io      # per l'immagine base Red Hat
#   podman login "$REGISTRY"             # se PUSH=true
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="${REGISTRY:-localhost}"
IMAGE_NAME="${IMAGE_NAME:-aap-acea-aws-ssm-ee}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
PUSH="${PUSH:-false}"

FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

echo ">> Build di ${FULL_IMAGE}"
ansible-builder build \
  --file execution-environment.yml \
  --context ./context \
  --tag "${FULL_IMAGE}" \
  --container-runtime "${CONTAINER_RUNTIME}" \
  --verbosity 2

echo
echo ">> Verifica del contenuto dell'immagine"
"${CONTAINER_RUNTIME}" run --rm "${FULL_IMAGE}" \
  /usr/local/bin/session-manager-plugin --version

"${CONTAINER_RUNTIME}" run --rm "${FULL_IMAGE}" \
  python3 -c "import boto3, botocore; print('boto3', boto3.__version__, '/ botocore', botocore.__version__)"

"${CONTAINER_RUNTIME}" run --rm "${FULL_IMAGE}" \
  ansible-galaxy collection list 2>/dev/null | grep -E 'amazon\.aws|community\.(aws|general)|ansible\.posix'

echo
echo ">> Verifica di ansible-core e del connection plugin"
"${CONTAINER_RUNTIME}" run --rm "${FULL_IMAGE}" ansible --version | head -1

# Due modi in cui la coppia (base image, amazon.aws) puo' essere incoerente:
#
#   1. amazon.aws < 10.0.0 -> il connection plugin aws_ssm non esiste proprio
#      (e' stato promosso da community.aws con la 10.0.0).
#   2. amazon.aws >= 10.0.0 su una base image troppo vecchia -> la collection
#      si installa lo stesso, ma dichiara di non supportare quel core e lo
#      segnala con "does not support Ansible version". Funziona a meta': ad
#      esempio l'inventario dinamico parte ma non e' piu' terreno supportato.
#
# Entrambi si scoprono qui in pochi secondi, invece che al primo job in AAP.
if ! ssm_doc=$("${CONTAINER_RUNTIME}" run --rm "${FULL_IMAGE}" \
     ansible-doc -t connection amazon.aws.aws_ssm 2>&1); then
  echo "ERRORE: amazon.aws.aws_ssm non si risolve nell'immagine." >&2
  echo "        amazon.aws e' < 10.0.0: alza il pin in requirements.yml," >&2
  echo "        oppure usa community.aws.aws_ssm impostando" >&2
  echo "        ssm_connection_plugin in inventory/group_vars/all.yml." >&2
  exit 1
fi

if grep -q 'does not support Ansible version' <<<"${ssm_doc}"; then
  echo "ERRORE: la base image e' troppo vecchia per questa amazon.aws." >&2
  grep 'does not support Ansible version' <<<"${ssm_doc}" >&2
  echo "        Allinea images.base_image in execution-environment.yml alla" >&2
  echo "        tua versione di AAP (il suffisso -NN del repository)." >&2
  exit 1
fi

echo "   amazon.aws.aws_ssm: risolto, versioni coerenti"

if [[ "${PUSH}" == "true" ]]; then
  echo
  echo ">> Push di ${FULL_IMAGE}"
  "${CONTAINER_RUNTIME}" push "${FULL_IMAGE}"
  echo
  echo "Ora registralo in AAP:"
  echo "  Administration > Execution Environments > Add"
  echo "    Name  : AWS SSM EE"
  echo "    Image : ${FULL_IMAGE}"
  echo "    Pull  : Always"
  echo "    Registry credential: <container registry credential>"
fi

echo
echo ">> Fatto: ${FULL_IMAGE}"

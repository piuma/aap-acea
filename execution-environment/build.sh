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

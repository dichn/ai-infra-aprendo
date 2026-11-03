#!/usr/bin/env bash
#
# Deploy the GuideLLM client pod and copy the model's tokenizer into it
# (no PVC, internet or HF token needed). Safe to re-run.
#
# Usage:
#   scripts/guidellm-deploy.sh [--host-alias HOST=IP]
#

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="${NAMESPACE:-demo}"
LLMISVC="${LLMISVC:-}"
MODEL_POD_SELECTOR="${MODEL_POD_SELECTOR:-app.kubernetes.io/name=${LLMISVC},app.kubernetes.io/component=llminferenceservice-workload}"
MODEL_CONTAINER="${MODEL_CONTAINER:-main}"
GUIDELLM_VERSION="${GUIDELLM_VERSION:-0.7.1}"
GUIDELLM_IMAGE="${GUIDELLM_IMAGE:-ghcr.io/vllm-project/guidellm:v${GUIDELLM_VERSION}}"
TOK_DIR="${TOK_DIR:-/tmp/tokenizer}"
HOST_ALIAS=""

usage() {
  cat <<EOF
Usage:
  $0 [--host-alias HOST=IP]

Options:
  --host-alias HOST=IP   Resolve HOST to IP in the pod, e.g. the MaaS gateway
                         hostname to its ClusterIP (TLS SNI must match HOST)

Environment:
  NAMESPACE              Default: demo
  LLMISVC                LLMInferenceService to copy the tokenizer from, e.g. qwen3-8b-fp8-maas
                         (required unless MODEL_POD_SELECTOR is set)
  MODEL_POD_SELECTOR     Model pod label selector. Default: the LLMISVC workload pod.
                         For a KServe InferenceService: serving.kserve.io/inferenceservice=<name>
  MODEL_CONTAINER        Container with /mnt/models. Default: main (InferenceService: kserve-container)
  GUIDELLM_VERSION       Default: 0.7.1
  TOK_DIR                Tokenizer path in the pod. Default: /tmp/tokenizer
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="${2:-}"; shift $(( $# > 1 ? 2 : 1 ))
                  [[ "${HOST_ALIAS}" == ?*=?* ]] || { echo "ERROR: --host-alias needs HOST=IP"; exit 1; } ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERROR: Unknown argument: $1"; usage; exit 1 ;;
  esac
done
if [ -z "${LLMISVC}" ] && [[ "${MODEL_POD_SELECTOR}" == *"name=,"* ]]; then
  echo "ERROR: Set LLMISVC (or MODEL_POD_SELECTOR)"; usage; exit 1
fi

# oc exec streams drop on flaky API connections
retry() {
  for i in 1 2 3 4 5; do "$@" && return 0; sleep $((i * 2)); done
  return 1
}
gl()    { oc exec -n "${NAMESPACE}" deploy/guidellm -- "$@"; }
model() { oc exec -n "${NAMESPACE}" "${MODEL_POD}" -c "${MODEL_CONTAINER}" -- "$@"; }

echo "=== Deploying guidellm to ${NAMESPACE} (${GUIDELLM_IMAGE}) ==="
NAMESPACE="${NAMESPACE}" GUIDELLM_IMAGE="${GUIDELLM_IMAGE}" \
  envsubst '$NAMESPACE $GUIDELLM_IMAGE' < "${BASE}/yaml/guidellm-deployment.yaml" | oc apply -f -

if [ -n "${HOST_ALIAS}" ]; then
  echo "=== Pinning ${HOST_ALIAS%%=*} to ${HOST_ALIAS#*=} ==="
  # Restarts the pod (wiping /tmp) only if the alias changed, so do it before the copy.
  oc patch deploy/guidellm -n "${NAMESPACE}" --type=merge -p "$(jq -n \
    --arg host "${HOST_ALIAS%%=*}" --arg ip "${HOST_ALIAS#*=}" \
    '{spec: {template: {spec: {hostAliases: [{ip: $ip, hostnames: [$host]}]}}}}')"
fi

oc rollout status deploy/guidellm -n "${NAMESPACE}" --timeout=900s   # first pull: ~5-10 min

echo "=== Copying tokenizer (${MODEL_POD_SELECTOR}) ==="
MODEL_POD=$(oc get pod -n "${NAMESPACE}" -l "${MODEL_POD_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')
[ -n "${MODEL_POD}" ] || { echo "❌ No model pod matches ${MODEL_POD_SELECTOR}"; exit 1; }

retry gl mkdir -p "${TOK_DIR}"
# Everything except the weights: tokenizer.json, vocab/merges, configs, ...
FILES=$(retry model find -L /mnt/models -maxdepth 1 -type f -size -100M \
  ! -name '*.index.json' ! -name '*.md' -printf '%f\n')

for f in ${FILES}; do
  want=$(retry model sha256sum "/mnt/models/${f}")
  # Large oc exec streams can be silently truncated: copy gzip'd, verify, retry.
  for i in 1 2 3 4 5 6; do
    got=$(gl sha256sum "${TOK_DIR}/${f}" 2>/dev/null || true)
    [ "${got%% *}" = "${want%% *}" ] && { echo "✅ ${f}"; break; }
    [ "$i" -lt 6 ] || { echo "❌ ${f}: checksum mismatch after retries"; exit 1; }
    model gzip -c "/mnt/models/${f}" \
      | oc exec -i -n "${NAMESPACE}" deploy/guidellm -- sh -c "gunzip -c > ${TOK_DIR}/${f}" || sleep $((i * 2))
  done
done

echo "=== Checking GuideLLM version ==="
VERSION=$(gl guidellm --version)
[[ "${VERSION}" == *"${GUIDELLM_VERSION}"* ]] || { echo "❌ Expected ${GUIDELLM_VERSION}, got: ${VERSION}"; exit 1; }
echo "✅ ${VERSION}"
echo
echo "🎉 guidellm is ready in ${NAMESPACE}"

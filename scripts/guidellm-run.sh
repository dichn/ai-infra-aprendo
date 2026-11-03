#!/usr/bin/env bash
#
# Run a GuideLLM 0.7 benchmark in the guidellm pod (see guidellm-deploy.sh),
# wait for it, and fetch the results to OUT_DIR/<name>.{json,log,version}.
#
# Usage:
#   scripts/guidellm-run.sh <name> <target-url> <model>
#

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="${NAMESPACE:-demo}"
OUT_DIR="${OUT_DIR:-${BASE}/results}"   # git-ignored
TOK_DIR="${TOK_DIR:-/tmp/tokenizer}"
CONC="${CONC:-8}"
MAX_REQUESTS="${MAX_REQUESTS:-100}"
PROMPT_TOKENS="${PROMPT_TOKENS:-768}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-768}"
SEED="${SEED:-42}"
PROFILE="${PROFILE:-kind=throughput,max_concurrency=${CONC}}"
CONSTRAINT="${CONSTRAINT:-kind=max_requests,count=${MAX_REQUESTS}}"
DATA="${DATA:-kind=synthetic_text,prompt_tokens=${PROMPT_TOKENS},output_tokens=${OUTPUT_TOKENS}}"
OVERRIDE="${OVERRIDE:-}"
TIMEOUT="${TIMEOUT:-3600}"

usage() {
  cat <<EOF
Usage:
  $0 <name> <target-url> <model>

Environment:
  NAMESPACE        Namespace of deploy/guidellm. Default: demo
  OUT_DIR          Local results directory. Default: <repo>/results (git-ignored)
  CONC, MAX_REQUESTS, PROMPT_TOKENS, OUTPUT_TOKENS
                   Default workload: 8, 100, 768, 768
  SEED             Synthetic data seed; use a new one per run (vLLM prefix cache). Default: 42
  PROFILE, CONSTRAINT, DATA
                   Full GuideLLM specs, overriding the values above
  OVERRIDE         Sweep values, e.g. "profile.streams 1,2,4,8" with PROFILE=kind=concurrent
  API_KEY          Bearer token (MaaS). Passed via a 0600 file in the pod, never argv
  TIMEOUT          Seconds to wait. Default: 3600. The run keeps going in the pod after
                   a timeout or Ctrl-C; stop it with the command printed on timeout.
  TOK_DIR          Tokenizer path in the pod. Default: /tmp/tokenizer

Examples:
  SEED=101 $0 direct https://qwen3-8b-fp8-maas-kserve-workload-svc.demo.svc.cluster.local:8000 qwen3-8b-fp8-maas
  SEED=102 API_KEY=\$MAAS_KEY $0 gateway https://maas.apps.<domain>/demo/qwen3-8b-fp8-maas publishers/demo/models/qwen3-8b-fp8-maas
EOF
}

[ "$#" -eq 3 ] || { usage; exit 1; }
NAME="$1"
TARGET="$2"
MODEL="$3"
F="/tmp/${NAME}"   # pod-side files: $F.{scenario.json,pid,rc,log,json,version}

# These are interpolated into a shell in the pod: only allow safe characters.
for v in "${NAME}" "${PROFILE}" "${CONSTRAINT}" "${DATA}" "${SEED}" "${TOK_DIR}" "${OVERRIDE// /:}"; do
  [[ "$v" =~ ^[A-Za-z0-9_.,=:/-]*$ ]] || { echo "❌ Unsafe characters in: $v"; exit 1; }
done

# oc exec streams drop on flaky API connections
retry() {
  for i in 1 2 3 4 5; do "$@" && return 0; sleep $((i * 2)); done
  return 1
}
gl() { oc exec -n "${NAMESPACE}" deploy/guidellm -- "$@"; }

echo "=== Checking guidellm pod ==="
gl test -s "${TOK_DIR}/tokenizer_config.json" || { echo "❌ No tokenizer in the pod: run scripts/guidellm-deploy.sh"; exit 1; }
if gl sh -c "test -f $F.pid && test ! -f $F.rc && kill -0 \$(cat $F.pid) 2>/dev/null" 2>/dev/null; then
  echo "❌ Run ${NAME} is already in progress"; exit 1
fi

echo "=== Starting ${NAME}: ${TARGET} (${MODEL}), seed ${SEED} ==="
# jq reads API_KEY from the environment, so it never appears on a command line.
jq -n --arg target "${TARGET}" --arg model "${MODEL}" '{spec: {backend: (
    {kind: "openai_http", target: $target, model: $model}
    + (if (env.API_KEY // "") != "" then {api_key: env.API_KEY} else {} end))}}' \
  | oc exec -i -n "${NAMESPACE}" deploy/guidellm -- sh -c "umask 077; cat > $F.scenario.json"

# Detached with nohup: a dropped oc exec session must not kill the run.
gl sh -c "rm -f $F.json $F.rc $F.log $F.version; cd /tmp && nohup sh -c '
  guidellm --version > $F.version 2>&1
  guidellm run --scenario $F.scenario.json \
    --tokenizer kind=hf_auto,model=${TOK_DIR} \
    --profile ${PROFILE} ${OVERRIDE:+--override ${OVERRIDE}} \
    --constraint ${CONSTRAINT} \
    --data ${DATA} \
    --seed kind=static,value=${SEED} \
    --output kind=json,path=$F.json --output kind=console \
    --disable-progress > $F.log 2>&1
  echo \$? > $F.rc
  rm -f $F.scenario.json' >/dev/null 2>&1 & echo \$! > $F.pid"

echo "Waiting (follow: oc exec -n ${NAMESPACE} deploy/guidellm -- tail -f $F.log)"
START=${SECONDS}
while sleep 15; do
  # done:<rc> | running | dead (killed) | gone (pod restarted, /tmp wiped) | unreachable
  STATE=$(gl sh -c "if [ -f $F.rc ]; then echo done:\$(cat $F.rc)
    elif [ ! -f $F.pid ]; then echo gone
    elif kill -0 \$(cat $F.pid) 2>/dev/null; then echo running
    else echo dead; fi" 2>/dev/null || echo unreachable)
  case "${STATE}" in
    done:0)    break ;;
    done:*)    echo "❌ guidellm exited ${STATE#done:}:"; gl tail -20 "$F.log" || true; exit 1 ;;
    gone|dead) echo "❌ Run ${STATE}: the pod restarted or the process was killed"; exit 1 ;;
  esac
  if (( SECONDS - START > TIMEOUT )); then
    echo "❌ Timed out after ${TIMEOUT}s (${STATE}). Stop it with:"
    echo "   oc exec -n ${NAMESPACE} deploy/guidellm -- sh -c 'pkill -P \$(cat $F.pid); kill \$(cat $F.pid)'"
    exit 1
  fi
done

echo "=== Fetching results ==="
mkdir -p "${OUT_DIR}"
fetch() {   # fetch <ext>: pod $F.<ext> -> OUT_DIR/NAME.<ext>, gzip'd (large streams get truncated)
  gl gzip -c "$F.$1" | gunzip > "${OUT_DIR}/${NAME}.$1" \
    && { [ "$1" != json ] || jq -e '.benchmarks | length > 0' "${OUT_DIR}/${NAME}.json" >/dev/null; }
}
for ext in json log version; do
  retry fetch "${ext}" || { echo "❌ Failed to fetch $F.${ext}"; exit 1; }
done

ERRORS=$(jq '[.benchmarks[].metrics.request_totals.errored] | add' "${OUT_DIR}/${NAME}.json")
if [ "${ERRORS}" -ne 0 ]; then
  echo "❌ ${ERRORS} errored requests (e.g. 429 quota):"
  grep HTTPStatusError "${OUT_DIR}/${NAME}.log" | sort | uniq -c | head -3 || true
  exit 1
fi

"${BASE}/scripts/guidellm-summary.sh" "${OUT_DIR}/${NAME}.json"
echo
echo "✅ Saved ${OUT_DIR}/${NAME}.{json,log,version}"

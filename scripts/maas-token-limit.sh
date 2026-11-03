#!/usr/bin/env bash
#
# Show, change and restore a MaaSSubscription token rate limit for one model and
# window, waiting until the generated TokenRateLimitPolicy enforces it.
#
# Usage:
#   scripts/maas-token-limit.sh show
#   scripts/maas-token-limit.sh set <limit>
#   scripts/maas-token-limit.sh restore
#

set -euo pipefail

SUB_NS="${SUB_NS:-models-as-a-service}"
SUB="${SUB:-}"
MODEL_NS="${MODEL_NS:-}"
MODEL="${MODEL:-}"
WINDOW="${WINDOW:-1h}"
STATE_DIR="${STATE_DIR:-${HOME}/.cache/maas-token-limit}"
STATE="${STATE_DIR}/${SUB_NS}_${SUB}_${MODEL_NS}_${MODEL}_${WINDOW}"   # "<ref> <rate> <original> <new>"

usage() {
  cat <<EOF
Usage:
  $0 show                Limits per subscription/model, and policy rules with Enforced status
  $0 set <limit>         Save the original limit, patch it, wait for enforcement
  $0 restore             Patch back to the saved original, wait for enforcement

Environment:
  SUB_NS                 Default: models-as-a-service
  SUB, MODEL_NS, MODEL   Target subscription and model (required for set/restore)
  WINDOW                 Rate window, as written in the subscription. Default: 1h
  STATE_DIR              Where the original limit is saved. Default: ~/.cache/maas-token-limit

The limit is shared by every user of the subscription: restore it right after the test.

Example:
  export SUB=qwen3-8b-fp8-maas-premium MODEL_NS=demo MODEL=qwen3-8b-fp8-maas
  trap '$0 restore' EXIT
  $0 set 200000
EOF
}

show() {
  echo "=== MaaSSubscription limits ==="
  oc get maassubscription -A -o json | jq -r '
    .items[] | "\(.metadata.namespace)/\(.metadata.name)" as $sub
    | .spec.modelRefs[] | "\(.namespace)/\(.name)" as $model
    | .tokenRateLimits[] | "\($sub)  \($model)  \(.limit)/\(.window)"' | column -t
  echo
  echo "=== TokenRateLimitPolicy rules ==="
  oc get tokenratelimitpolicy -A -l app.kubernetes.io/managed-by=maas-controller -o json | jq -r '
    .items[]
    | (any(.status.conditions[]?; .type == "Enforced" and .status == "True")
       and .status.observedGeneration == .metadata.generation) as $enforced
    | "\(.metadata.namespace)/\(.metadata.name)" as $policy
    | .spec.limits // {} | to_entries[]
    | "\($policy)  \(.key)  \(.value.rates | map("\(.limit)/\(.window)") | join(","))  enforced=\($enforced)"' | column -t
}

# Prints "<ref-index> <rate-index> <limit>" of the one matching modelRef/window.
find_limit() {
  oc get maassubscription "${SUB}" -n "${SUB_NS}" -o json | jq -er \
    --arg ns "${MODEL_NS}" --arg model "${MODEL}" --arg window "${WINDOW}" '
    [ .spec.modelRefs | to_entries[] | select(.value.namespace == $ns and .value.name == $model)
      | .key as $ref | .value.tokenRateLimits | to_entries[] | select(.value.window == $window)
      | "\($ref) \(.key) \(.value.limit)" ]
    | if length == 1 then .[0] else error("expected one \($ns)/\($model) \($window) limit, found \(length)") end'
}

# JSON Patch with test ops: fails instead of overwriting a concurrent change.
patch_limit() {   # patch_limit <ref> <rate> <expected> <new>
  local path="/spec/modelRefs/$1"
  oc patch maassubscription "${SUB}" -n "${SUB_NS}" --type=json -p "$(jq -n \
    --arg ref "${path}" --arg limit "${path}/tokenRateLimits/$2/limit" \
    --arg model "${MODEL}" --arg ns "${MODEL_NS}" --argjson expected "$3" --argjson new "$4" '[
      {op: "test",    path: "\($ref)/name",      value: $model},
      {op: "test",    path: "\($ref)/namespace", value: $ns},
      {op: "test",    path: $limit,              value: $expected},
      {op: "replace", path: $limit,              value: $new}]')"
}

# Waits until the policy rule for this subscription/model enforces <limit>. The rule
# key embeds the limit (tokens-100000-per-1h), so match the rule by its predicate.
wait_enforced() {   # wait_enforced <limit>
  echo "Waiting for the TokenRateLimitPolicy to enforce $1/${WINDOW}..."
  for _ in $(seq 60); do
    if oc get tokenratelimitpolicy -n "${MODEL_NS}" -l "maas.opendatahub.io/model=${MODEL}" -o json | jq -e \
      --arg key "\"${SUB_NS}/${SUB}@${MODEL_NS}/${MODEL}\"" --arg window "${WINDOW}" --argjson limit "$1" '
      [ .items[]
        | select(.status.observedGeneration == .metadata.generation)
        | select(any(.status.conditions[]?; .type == "Enforced" and .status == "True"))
        | (.spec.limits // {})[] | select(any(.when[]?; .predicate | contains($key)))
        | .rates[] | select(.window == $window and .limit == $limit) ] | length > 0' >/dev/null; then
      echo "✅ Enforced: $1/${WINDOW}"
      return 0
    fi
    sleep 5
  done
  echo "❌ Not enforced after 5 min. Check: oc get tokenratelimitpolicy -n ${MODEL_NS} -o yaml"
  exit 1
}

require_target() {
  if [ -z "${SUB}" ] || [ -z "${MODEL_NS}" ] || [ -z "${MODEL}" ]; then
    echo "❌ Set SUB, MODEL_NS and MODEL"
    exit 1
  fi
}

case "${1:-}" in
  show)
    show
    ;;

  set)
    NEW="${2:-}"
    [[ "${NEW}" =~ ^[1-9][0-9]*$ ]] || { usage; exit 1; }
    require_target
    if [ -e "${STATE}" ]; then
      echo "❌ ${STATE} exists (it holds the original limit): run restore first"
      exit 1
    fi
    FOUND=$(find_limit)
    read -r REF RATE ORIGINAL <<< "${FOUND}"
    if [ "${ORIGINAL}" = "${NEW}" ]; then
      echo "Limit is already ${NEW}"
      exit 0
    fi

    mkdir -p "${STATE_DIR}"
    echo "${REF} ${RATE} ${ORIGINAL} ${NEW}" > "${STATE}"   # before patching, so restore always works
    echo "=== ${SUB}: ${MODEL_NS}/${MODEL} ${ORIGINAL} -> ${NEW} per ${WINDOW} ==="
    patch_limit "${REF}" "${RATE}" "${ORIGINAL}" "${NEW}"
    wait_enforced "${NEW}"
    ;;

  restore)
    require_target
    [ -e "${STATE}" ] || { echo "Nothing to restore (no ${STATE})"; exit 0; }
    read -r REF RATE ORIGINAL NEW < "${STATE}"
    FOUND=$(find_limit)
    read -r CUR_REF CUR_RATE CURRENT <<< "${FOUND}"
    if [ "${CUR_REF} ${CUR_RATE}" != "${REF} ${RATE}" ]; then
      echo "❌ The model/window moved in ${SUB}; restore ${ORIGINAL} by hand"
      exit 1
    fi

    echo "=== ${SUB}: ${MODEL_NS}/${MODEL} ${CURRENT} -> ${ORIGINAL} per ${WINDOW} ==="
    case "${CURRENT}" in
      "${NEW}")      patch_limit "${REF}" "${RATE}" "${NEW}" "${ORIGINAL}" ;;
      "${ORIGINAL}") ;;   # set was interrupted before its patch landed
      *)             echo "❌ Limit was changed to ${CURRENT} by someone else; restore ${ORIGINAL} by hand"; exit 1 ;;
    esac
    wait_enforced "${ORIGINAL}"
    rm -f "${STATE}"
    ;;

  -h|--help)
    usage
    ;;

  *)
    usage
    exit 1
    ;;
esac

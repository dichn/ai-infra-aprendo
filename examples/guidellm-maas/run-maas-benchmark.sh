#!/usr/bin/env bash
#
# Benchmark demo/qwen3-8b-fp8-maas through the MaaS gateway: 100 requests of
# 768/768 tokens at concurrency 8. Run deploy-guidellm.sh first.
#
# No `set -e` on purpose: the key revoke and limit restore at the end must run
# even if the benchmark fails.
#

MAAS_HOST=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[?(@.protocol=="HTTPS")].hostname}')
LIMIT_PATH=/spec/modelRefs/0/tokenRateLimits/0/limit   # qwen3-8b-fp8-maas, 1h window

# 1. Raise the token limit: the run needs ~153,600 tokens (100 x 1,536), the
#    subscription allows 100,000/1h. This applies to every user of the subscription.
oc patch maassubscription qwen3-8b-fp8-maas-premium -n models-as-a-service --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"${LIMIT_PATH}\",\"value\":200000}]"
sleep 30   # let maas-controller and Kuadrant apply it; the policy should show 200000:
oc get tokenratelimitpolicy maas-trlp-qwen3-8b-fp8-maas -n demo -o jsonpath='{.spec.limits}{"\n"}'

# 2. Mint an ephemeral MaaS key (1h).
KEY_JSON=$(curl -sk -X POST "https://${MAAS_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
  -d '{"ephemeral":true,"expiresIn":"1h","name":"guidellm-maas","subscription":"qwen3-8b-fp8-maas-premium"}')
KEY_ID=$(jq -r .id <<<"${KEY_JSON}")
MAAS_KEY=$(jq -r .key <<<"${KEY_JSON}")

# 3. Run. Use a new seed per run, so vLLM's prefix cache doesn't skew TTFT.
oc exec -n demo deploy/guidellm-maas -- guidellm run \
  --backend "kind=openai_http,target=https://${MAAS_HOST}/demo/qwen3-8b-fp8-maas,model=publishers/demo/models/qwen3-8b-fp8-maas,api_key=${MAAS_KEY}" \
  --tokenizer kind=hf_auto,model=RedHatAI/Qwen3-8B-FP8-dynamic \
  --profile kind=throughput,max_concurrency=8 \
  --constraint kind=max_requests,count=100 \
  --data kind=synthetic_text,prompt_tokens=768,output_tokens=768 \
  --seed kind=static,value=102 \
  --output kind=json,path=/tmp/gateway.json --output kind=console \
  --disable-progress
mkdir -p results
oc exec -n demo deploy/guidellm-maas -- cat /tmp/gateway.json > results/gateway.json

# 4. Revoke the key and restore the limit.
curl -sk -X DELETE "https://${MAAS_HOST}/maas-api/v1/api-keys/${KEY_ID}" \
  -H "Authorization: Bearer $(oc whoami -t)"
oc patch maassubscription qwen3-8b-fp8-maas-premium -n models-as-a-service --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"${LIMIT_PATH}\",\"value\":100000}]"

#!/usr/bin/env bash
#
# Deploy the GuideLLM pod (deploy/guidellm-maas in demo) for the MaaS benchmark.
#

MAAS_HOST=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[?(@.protocol=="HTTPS")].hostname}')
GATEWAY_IP=$(oc get svc maas-default-gateway-openshift-gateway-controller -n openshift-ingress \
  -o jsonpath='{.spec.clusterIP}')

oc process -n demo -f "$(dirname "$0")/guidellm.yaml" -p MAAS_HOST="${MAAS_HOST}" -p GATEWAY_IP="${GATEWAY_IP}" \
  | oc apply -n demo -f -
oc rollout status deploy/guidellm-maas -n demo --timeout=900s   # first image pull: ~5-10 min

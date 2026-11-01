---
name: rhoai-maas-gateway-wrong-domain
description: >-
  Fix RHOAI MaaS/inference Gateway endpoints, passthrough Routes, and the
  default-gateway-tls certificate being created for the wrong hostname
  (missing the cluster name) when install-rhoai-35.sh/setup-maas.sh's
  --domain flag is passed the Route53 base domain instead of the full
  apps domain. Use when maas.apps.<base-domain> or
  inference-gateway.apps.<base-domain> don't resolve/connect, or a
  Certificate's dnsNames don't match the cluster's real
  *.apps.<cluster>.<base-domain> wildcard. Verified against RHOAI-Toolkit
  (commit range Oct-Nov 2026), OpenShift 4.22, RHOAI 3.5.2, cert-manager
  1.20.1, Let's Encrypt production.
disable-model-invocation: true
---

# RHOAI-Toolkit: MaaS Gateway Created With Wrong Domain

## Symptom pattern

- `curl https://maas.apps.<base-domain>/` or
  `https://inference-gateway.apps.<base-domain>/` fail to connect (curl exit
  28/connection refused, or DNS doesn't resolve at all) -- NOT a 404/503 from
  a reachable server, a hard connection failure.
- `dig +short maas.apps.<base-domain>` returns nothing (no DNS record).
- The RHOAI dashboard and plain `oc get route` resources work fine; only the
  Gateway API-based MaaS/inference endpoints are unreachable.
- `oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}'`
  shows `maas.apps.<base-domain>` -- missing the cluster name segment that
  the cluster's real ingress domain has.

## Root cause

The install script's `--domain` flag (and `get_cluster_domain()`'s manual
override path) expects the **full apps domain**: `<cluster-name>.<base-domain>`
(e.g. `rhoai-demo.example.com`) -- matching what
`oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'`
returns with the `apps.` prefix stripped. It does **not** mean the bare
Route53 hosted zone name.

Passing just the base domain (e.g. `--domain example.com`,
omitting the cluster name) causes every downstream consumer of
`$CLUSTER_DOMAIN` to build hostnames one level shallower than the cluster's
real `*.apps.<cluster>.<base-domain>` wildcard DNS record that
`openshift-install` already created:

- The `default-gateway-tls` Certificate's `dnsNames`/`commonName`:
  `*.apps.<base-domain>` instead of `*.apps.<cluster>.<base-domain>`.
- `maas-default-gateway` and `openshift-ai-inference` Gateway listener
  `hostname` fields.
- The `maas-default-gateway-passthrough` and
  `openshift-ai-inference-passthrough` Route `spec.host` fields.

Since no DNS record exists for `*.apps.<base-domain>` (only for
`*.apps.<cluster>.<base-domain>`), these hostnames are simply unreachable,
and the Let's Encrypt certificate issued for them doesn't match what clients
actually connect to.

## Diagnosis

```bash
# Confirm the real ingress domain
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
# e.g. apps.rhoai-demo.example.com

# Compare against what was actually configured
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}'
oc get route maas-default-gateway-passthrough -n openshift-ingress -o jsonpath='{.spec.host}'
oc get certificate default-gateway-tls -n openshift-ingress -o jsonpath='{.spec.dnsNames}'
# If any of these are missing the cluster-name segment vs. the ingress domain above, this is the bug.
```

## Fix

Re-point the Certificate, both Gateways, and both Routes at the correct
`*.apps.<cluster>.<base-domain>` pattern -- no new Route53 record is needed,
since that wildcard already exists and covers any single-label subdomain
prefix like `maas.` or `inference-gateway.`.

```bash
CORRECT_DOMAIN="apps.<cluster-name>.<base-domain>"   # e.g. apps.rhoai-demo.example.com

# 1. Fix the certificate (must patch BOTH dnsNames and commonName --
#    cert-manager's ACME issuer rejects a commonName absent from dnsNames)
oc patch certificate default-gateway-tls -n openshift-ingress --type=merge \
  -p "{\"spec\":{\"dnsNames\":[\"*.${CORRECT_DOMAIN}\"]}}"
oc patch certificate default-gateway-tls -n openshift-ingress --type=merge \
  -p "{\"spec\":{\"commonName\":\"*.${CORRECT_DOMAIN}\"}}"

# Wait for cert-manager to re-issue (DNS-01 challenge, 1-3 min):
oc get certificate default-gateway-tls -n openshift-ingress -w

# 2. Fix both Gateway listener hostnames
oc patch gateway maas-default-gateway -n openshift-ingress --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"maas.${CORRECT_DOMAIN}\"}]"
oc patch gateway openshift-ai-inference -n openshift-ingress --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"inference-gateway.${CORRECT_DOMAIN}\"}]"

# 3. Fix both passthrough Route hosts
oc patch route maas-default-gateway-passthrough -n openshift-ingress --type=merge \
  -p "{\"spec\":{\"host\":\"maas.${CORRECT_DOMAIN}\"}}"
oc patch route openshift-ai-inference-passthrough -n openshift-ingress --type=merge \
  -p "{\"spec\":{\"host\":\"inference-gateway.${CORRECT_DOMAIN}\"}}"
```

## Verification

```bash
curl -sk -o /dev/null -w "%{http_code}\n" "https://maas.${CORRECT_DOMAIN}/"
curl -sk -o /dev/null -w "%{http_code}\n" "https://inference-gateway.${CORRECT_DOMAIN}/"
# A real HTTP response code (e.g. 404 if no model is published yet) -- not a
# connection failure -- confirms DNS + routing + TLS are now correct.

echo | openssl s_client -connect "maas.${CORRECT_DOMAIN}:443" -servername "maas.${CORRECT_DOMAIN}" 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# issuer should be Let's Encrypt, subject should match *.${CORRECT_DOMAIN}
```

## Prevention

Always pass `--domain` as the **full apps domain**, confirmed from the live
cluster rather than assumed from the Route53 zone name:

```bash
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | sed 's/^apps\.//')
./scripts/install-rhoai-35.sh --domain "$DOMAIN" ...
```

Or simply omit `--domain` entirely and let `get_cluster_domain()`
auto-detect it from the live `IngressController` config -- the flag only
exists to override auto-detection for edge cases (e.g. a custom DNS in
front of the cluster), not as a required input.

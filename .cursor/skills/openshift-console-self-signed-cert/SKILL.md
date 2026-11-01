---
name: openshift-console-self-signed-cert
description: >-
  Fix the OpenShift web console, OAuth, and RHOAI/OpenShift AI dashboard
  showing a browser "Not Secure"/certificate-warning page even though a
  valid Let's Encrypt wildcard certificate already exists on the cluster,
  caused by the default IngressController's spec.defaultCertificate never
  being set during install-rhoai-35.sh's "best-effort" TLS step. Use when
  https://console-openshift-console.apps.<cluster>.<domain> or the RHOAI
  dashboard route fails browser trust checks, or when a Certificate
  resource was issued for the wrong hostname (missing the cluster-name
  segment).
disable-model-invocation: true
---

# OpenShift Console / RHOAI Dashboard: Untrusted ("Self-Signed") Certificate

**Verified against:** RHOAI-Toolkit (Oct-Nov 2026 commits), OpenShift
4.22.18, cert-manager 1.20.1, Let's Encrypt production.

## Symptom pattern

- Browser shows "Your connection is not private" / "Not Secure" when
  visiting `https://console-openshift-console.apps.<cluster>.<domain>/`
  (the OpenShift web console) or the RHOAI dashboard route.
- `curl` to the same URL fails trust verification unless `-k`/`--insecure`
  is passed.
- A valid, `Ready` Let's Encrypt `Certificate` resource (e.g.
  `default-gateway-tls` in `openshift-ingress`, created by the RHOAI
  install's wildcard-TLS step) already exists on the cluster -- it's just
  not being served by the default router.

## Root cause

[`openshift-ai-setup`](../openshift-ai-setup/SKILL.md)'s install flow
creates a Let's Encrypt `ClusterIssuer` + wildcard `Certificate`, then
applies it to the Gateway API resources and, "best-effort," to the default
`IngressController`. That last step can silently fail or be skipped
entirely, leaving `IngressController.spec.defaultCertificate` **unset** --
in which case the router falls back to OpenShift's built-in self-signed CA
(`issuer=CN=ingress-operator@<timestamp>`) for every route that doesn't
carry its own per-route certificate. Since the OCP console, OAuth, and the
RHOAI dashboard are all `edge`-terminated routes on the **default** router
shard (not routes with custom certs), they all inherit this self-signed
fallback.

A related but separate bug can also produce a `Certificate` resource issued
for the wrong hostname: if the install's `--domain` flag (or
`get_cluster_domain()`'s override) was given the bare Route53 base domain
instead of the full `<cluster-name>.<base-domain>` apps domain, a
`Certificate`'s `dnsNames` end up as `*.<base-domain>` instead of
`*.apps.<cluster-name>.<base-domain>` -- see
[rhoai-maas-gateway-wrong-domain](../rhoai-maas-gateway-wrong-domain/SKILL.md)
for that specific pattern (same root mistake, different resource).

## Diagnosis

```bash
# What's actually being served right now?
echo | openssl s_client -connect console-openshift-console.apps.<cluster>.<domain>:443 \
  -servername console-openshift-console.apps.<cluster>.<domain> 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
# issuer=CN=ingress-operator@... -> confirms the self-signed fallback is in use

# Is defaultCertificate actually wired up?
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate}{"\n"}'
# empty output = not wired up (the bug)

# Does a usable Let's Encrypt cert already exist?
oc get certificate -n openshift-ingress
oc get certificate default-gateway-tls -n openshift-ingress \
  -o jsonpath='{.spec.dnsNames}{"\n"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# dnsNames should be *.apps.<cluster-name>.<base-domain> and Ready=True
```

If instead the only existing cert has `dnsNames: ['*.<base-domain>']`
(missing the cluster-name segment), that cert itself needs re-issuing --
see the Fix below.

## Fix

### If a correctly-scoped cert already exists (e.g. `default-gateway-tls`)

Point the router at it directly -- no re-issuance needed:

```bash
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge \
  -p '{"spec":{"defaultCertificate":{"name":"default-gateway-tls"}}}'
```

This triggers a rolling restart of the router pods (~1-2 min); both old
and new router pods will briefly coexist (old ones `Terminating`) during
the rollout -- this is expected, not a failure.

### If the only cert found has the wrong domain (e.g. `apps-wildcard-cert`
### scoped to `*.<base-domain>` instead of `*.apps.<cluster>.<base-domain>`)

Patch the `Certificate` resource's `dnsNames` to the correct apps domain;
cert-manager re-issues automatically via the existing `ClusterIssuer`'s
DNS-01 solver (~1-3 min):

```bash
oc patch certificate apps-wildcard-cert -n openshift-ingress --type=merge \
  -p '{"spec":{"dnsNames":["*.apps.<cluster-name>.<base-domain>"]}}'
```

Then apply the `defaultCertificate` patch above, pointing at whichever
secret now holds the correctly-scoped cert.

## Verification

```bash
# Router rollout complete (no stale pods left)
oc get pods -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default

# Trusted connection -- no -k needed
curl -sI https://console-openshift-console.apps.<cluster>.<domain>/
curl -sI https://<rhoai-dashboard-route>.apps.<cluster>.<domain>/

# Confirm issuer is Let's Encrypt, not ingress-operator
echo | openssl s_client -connect console-openshift-console.apps.<cluster>.<domain>:443 \
  -servername console-openshift-console.apps.<cluster>.<domain> 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

A `200`/`301` from plain `curl` (no `--insecure`) and `issuer=...Let's
Encrypt...` confirm the fix. Both the OCP console and the RHOAI dashboard
share the same default router shard, so one `defaultCertificate` patch
fixes HTTPS trust for both at once.

## Prevention

After running `install-rhoai-35.sh`'s wildcard-TLS step, don't assume the
"best-effort" `IngressController` patch succeeded -- explicitly check
`oc get ingresscontroller default -n openshift-ingress-operator -o
jsonpath='{.spec.defaultCertificate}'` is non-empty as part of post-install
verification, the same way [openshift-ai-setup](../openshift-ai-setup/SKILL.md)'s
Step 3 checks `DataScienceCluster`/MaaS status.

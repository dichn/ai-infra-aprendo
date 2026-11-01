---
name: openshift-csr-backlog-outage
description: >-
  Diagnose and fix an OpenShift cluster where the API server is healthy but
  the console/OAuth/router (apps.* routes) are unreachable, caused by a
  backlog of unapproved kubelet CSRs freezing kubelet<->API server trust.
  Use when console-openshift-console or oauth-openshift is unreachable
  (TLS handshake errors, EOF) while the API server itself responds fine,
  especially on self-managed/IPI OpenShift clusters where the
  machine-approver may have stopped auto-approving certificate renewals.
disable-model-invocation: true
---

# OpenShift Console/Router Down, API Healthy: CSR Backlog

## Symptom pattern

- `https://api.<cluster>:6443/version` works (200 OK)
- `https://console-openshift-console.apps.<cluster>/` and
  `https://oauth-openshift.apps.<cluster>/` fail TLS handshake (`EOF`,
  `SSL_ERROR_SYSCALL`, or `tls: internal error`)
- `oc login` fails with `Unable to connect to the server: EOF` (it fails
  during the OAuth redirect, not API auth)
- Cloud load balancer for the router/ingress shows backend instances
  `OutOfService`/unhealthy, while the API server's own LB shows healthy
  targets

This combination means the control plane is up but kubelet<->API-server
trust has broken, which starves the CNI's per-node Service health-check
listener (used by the cloud LB) of fresh state.

## Step 1: Get access that bypasses the broken OAuth path

If this is a self-managed cluster you (or someone on your team) installed
with `openshift-install`, the install directory's `auth/kubeconfig` uses
client-certificate auth straight to the API server — it never touches
OAuth/the router, so it works even while the console is down:

```bash
export KUBECONFIG=<install-dir>/auth/kubeconfig
oc whoami            # should print system:admin
oc get nodes -o wide
oc get clusteroperators
```

If that file doesn't exist, you need a pre-existing admin kubeconfig from
some other source (e.g., `system:admin` kubeconfig secret in a management
cluster, or a bastion that already has cluster access).

## Step 2: Confirm it's not a network/SG issue before blaming the app

Don't assume the cloud LB health check failure is a security-group problem
just because it "looks like" one. Check:

```bash
# Does the router Service's nodePort/healthCheckNodePort match the LB config?
oc get svc -n openshift-ingress router-default -o yaml | grep -E "nodePort|healthCheckNodePort"
# Compare against: aws elb describe-load-balancers --load-balancer-names <name> --query 'LoadBalancerDescriptions[].[HealthCheck,ListenerDescriptions]'

# Are the router pods actually running?
oc get pods -n openshift-ingress -o wide
```

If (as is common) the Service config matches the LB exactly and the pods
are `Running`, the LB-reported unhealthy status is a symptom, not the
disease — move to Step 3. Optionally use AWS VPC Reachability Analyzer to
definitively rule out SG/NACL blocking before digging further:

```bash
PATH_ID=$(aws ec2 create-network-insights-path --source <lb-eni-id> \
  --destination <instance-id> --destination-port <healthCheckNodePort> \
  --protocol tcp --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)
aws ec2 start-network-insights-analysis --network-insights-path-id "$PATH_ID"
# poll aws ec2 describe-network-insights-analyses, check NetworkPathFound
# then clean up: delete-network-insights-analysis / delete-network-insights-path
```

## Step 3: Check for frozen node heartbeats and a CSR backlog

This is the real diagnostic:

```bash
# Is oc exec/logs broken on EVERY node (not just one)?
oc exec -n openshift-ingress <any-pod> -- hostname
# "tls: internal error" or similar on ALL nodes (masters included) = cluster-wide
# kubelet<->apiserver trust problem, not a single-node issue.

# Are node heartbeats actually live, or frozen at some point in the past?
oc get nodes -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d['items']:
    for c in n['status']['conditions']:
        if c['type']=='Ready':
            print(n['metadata']['name'], c['status'], c['lastHeartbeatTime'])
"
# Status says Ready but lastHeartbeatTime is hours/days old = stale snapshot,
# not live health.

# The smoking gun: unapproved CSRs piling up
oc get csr | grep -v "Approved,Issued"
```

A large, continuously-regenerated backlog of `Pending`
`kubernetes.io/kube-apiserver-client-kubelet` CSRs (requested by
`system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`)
means the `machine-approver` has stopped approving routine kubelet
certificate renewals. Once a node's client cert fully expires, it can no
longer update its own heartbeat or let the API server reach its kubelet —
hence the frozen timestamps and `oc exec` failures across the board.

## Step 4: Fix — approve the backlog, then catch the follow-on serving CSRs

```bash
# Approve every pending CSR
oc get csr -o name | xargs -n1 -I{} oc adm certificate approve {}

# Nodes will immediately request kubelet-serving CSRs next (one per node).
# Catch them in a short poll loop:
for i in $(seq 1 15); do
  PENDING=$(oc get csr -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('items',[]):
    if not i.get('status',{}).get('conditions'):
        print(i['metadata']['name'])
")
  [ -n "$PENDING" ] && echo "$PENDING" | xargs -n1 -I{} oc adm certificate approve {}
  sleep 6
done
```

Expect within ~2 minutes:
- `lastHeartbeatTime` on all nodes becomes current/live again
- Cloud LB backend instances for router nodes flip to healthy/InService
  (nodes *without* router pods staying unhealthy is normal/expected when
  the Service uses `externalTrafficPolicy: Local` — only nodes with a
  local endpoint should pass that health check)
- `console-openshift-console` and `oauth-openshift` routes return 200
- `oc login` via OAuth succeeds

Investigate why `machine-approver` stopped auto-approving (check its pod
logs once `oc logs` works again) so the backlog doesn't silently recur —
this fix clears the symptom, not the underlying cause of the approver
going stale.

## Known follow-on issue: stale kube-apiserver trust bundle

After fixing the CSR backlog, `oc exec`/`oc logs` may still fail, but with
a *different*, more specific error: `x509: certificate signed by unknown
authority`. Check whether the CA that signed the new kubelet-serving certs
is already present in the trust ConfigMap:

```bash
oc get configmap kubelet-serving-ca -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' | openssl x509 -noout -subject -dates
```

If the correct CA is already in the ConfigMap but `kube-apiserver` static
pods haven't rolled to a new revision since the CA was rotated
(`oc get co kube-apiserver` shows an old, non-progressing revision), the
running apiserver processes are likely using a stale on-disk copy. Forcing
a new revision makes them re-render it:

```bash
oc patch kubeapiserver cluster --type merge -p \
  '{"spec":{"forceRedeploymentReason":"kubelet-serving-ca-refresh-'"$(date +%s)"'"}}'
```

This causes a rolling restart across all masters — more invasive, so only
do it if `oc exec`/`oc logs` access is actually needed (it is not required
for console/login access to work).

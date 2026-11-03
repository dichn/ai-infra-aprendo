# GuideLLM benchmark through the MaaS gateway

A minimal, hardcoded example: benchmark the LLMInferenceService `demo/qwen3-8b-fp8-maas`
through the MaaS gateway with GuideLLM 0.7.1, using plain `oc` commands and one YAML file.
For the generic, configurable version see
[misc/guidellm-maas-gateway-benchmark](../../misc/guidellm-maas-gateway-benchmark/SKILL.md).

## Architecture

```mermaid
flowchart LR
  Laptop["deploy-guidellm.sh<br/>run-maas-benchmark.sh"]
  HF["Hugging Face<br/>RedHatAI/Qwen3-8B-FP8-dynamic tokenizer"]
  MaaSAPI["maas-api<br/>(ephemeral key)"]
  subgraph demoNS ["demo namespace"]
    GL["guidellm-maas pod<br/>(hostAliases: maas.apps.&lt;domain&gt; → ClusterIP)"]
    VLLM["qwen3-8b-fp8-maas<br/>(EPP → vLLM)"]
  end
  subgraph ingressNS ["openshift-ingress namespace"]
    GW["maas-default-gateway"]
  end
  subgraph maasNS ["models-as-a-service namespace"]
    SUB["MaaSSubscription<br/>qwen3-8b-fp8-maas-premium"]
  end
  Laptop -->|"oc process + oc apply (guidellm.yaml)"| GL
  Laptop -->|"oc patch limit 200000 → 100000"| SUB
  Laptop -->|"curl: mint / revoke key"| MaaSAPI
  Laptop -->|"oc exec guidellm run"| GL
  HF -.->|"tokenizer download"| GL
  GL -->|"Bearer key, TLS SNI maas.apps.&lt;domain&gt;"| GW -->|"/demo/qwen3-8b-fp8-maas"| VLLM
  SUB -. "token quota (429)" .-> GW
```

## Files

| file | what it does |
|---|---|
| `guidellm.yaml` | OpenShift Template for `deploy/guidellm-maas`; the gateway hostname and ClusterIP are parameters |
| `deploy-guidellm.sh` | Looks up the gateway hostname and ClusterIP, then `oc process \| oc apply` |
| `run-maas-benchmark.sh` | Raises the token limit, mints a key, runs GuideLLM, saves `results/gateway.json`, revokes the key, restores the limit |

## Run

From the repo root, logged in with `oc` as a cluster admin (`jq` and `curl` installed):

```bash
examples/guidellm-maas/deploy-guidellm.sh
examples/guidellm-maas/run-maas-benchmark.sh   # ~3 min; console tables + results/gateway.json
```

The workload is 100 requests of 768 prompt / 768 output tokens at concurrency 8.
That needs ~153,600 tokens, so the run raises the subscription limit from
100,000 to 200,000 per hour, which **applies to every user of the subscription**
until the script restores it.

## Cleanup

```bash
oc delete deploy/guidellm-maas -n demo
```

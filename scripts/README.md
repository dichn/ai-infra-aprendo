# scripts

Standalone helpers used by the skills under `misc/`. Run them from the repo root;
`-h` prints usage. Each needs `oc`; most also need `jq`.

| script | purpose | skills |
|---|---|---|
| `guidellm-deploy.sh` | Deploy the GuideLLM pod (`yaml/guidellm-deployment.yaml`), optional host alias, copy tokenizer | guidellm-deploy |
| `guidellm-run.sh` | Run one GuideLLM benchmark in the pod and fetch `results/<name>.{json,log,version}` (git-ignored) | guidellm-vllm-benchmark, guidellm-maas-gateway-benchmark |
| `guidellm-summary.sh` | Markdown table from GuideLLM result JSON files | guidellm-vllm-benchmark, guidellm-maas-gateway-benchmark |
| `maas-token-limit.sh` | Show, set and restore a MaaSSubscription token rate limit | maas-token-rate-limit, guidellm-maas-gateway-benchmark |

Style follows `third_party/openshift-ai-bootstrap/scripts`:
- One script per task, with `set -euo pipefail` and a `usage()` heredoc.
- Settings come from `"${VAR:-default}"` env vars.
- Progress prints as `=== step ===` lines, with ✅/❌ results.
- JSON is handled with `jq`.

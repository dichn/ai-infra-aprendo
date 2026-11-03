#!/usr/bin/env bash
#
# Print GuideLLM 0.7 result files as one markdown table (one row per benchmark).
#
# Usage:
#   scripts/guidellm-summary.sh <result.json>...
#

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: $0 <result.json>..."
  echo "Example: $0 results/direct.json results/gateway.json"
  exit 1
fi

echo "| run | strategy | ok | err | req/s | out tok/s | TTFT p50 ms | TTFT p95 ms | ITL p50 ms | latency p50 s |"
echo "|---|---|---|---|---|---|---|---|---|---|"

for f in "$@"; do
  jq -r --arg run "$(basename "$f" .json)" '
    # stat("time_to_first_token_ms"; "p95") -> successful-request statistic, 2 decimals
    def stat(metric; s):
      .metrics[metric].successful
      | (if s == "mean" or s == "median" then .[s] else .percentiles[s] end)
      | . * 100 | round / 100;

    .benchmarks[]
    | [ $run,
        (.config.strategy | .type_ + ([.streams // .rate // .max_concurrency | values | "@\(.)"] | join(""))),
        .metrics.request_totals.successful,
        .metrics.request_totals.errored,
        stat("requests_per_second"; "mean"),
        stat("output_tokens_per_second"; "mean"),
        stat("time_to_first_token_ms"; "median"),
        stat("time_to_first_token_ms"; "p95"),
        stat("inter_token_latency_ms"; "median"),
        stat("request_latency"; "median") ]
    | "| " + (map(tostring) | join(" | ")) + " |"
  ' "$f"
done

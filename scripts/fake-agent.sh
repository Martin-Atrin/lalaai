#!/usr/bin/env bash
# Stand-in "LLM agent" for tests/demos without a subscription: talks to lalaai's MCP server with curl.
# Usage (lalaai Setup → AI → Custom): /path/to/scripts/fake-agent.sh
set -euo pipefail
call() { curl -s -X POST "$LALAAI_MCP_URL" -H 'content-type: application/json' -d "$1"; }
call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' >/dev/null
job=$(call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_icebreaker_job\",\"arguments\":{\"match_id\":\"$LALAAI_MATCH_ID\"}}}")
echo "$job" >&2
call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"submit_icebreakers\",\"arguments\":{\"match_id\":\"$LALAAI_MATCH_ID\",\"icebreakers_by_lang\":{\"en\":[{\"topic\":\"Scaling on device\",\"prompt\":\"Which part of your stack would you move onto the device first?\"},{\"topic\":\"Privacy\",\"prompt\":\"Has privacy ever killed a feature you wanted to ship?\"},{\"topic\":\"Hardware\",\"prompt\":\"What is the most surprising thing you have run on a laptop chip?\"}]}}}}"

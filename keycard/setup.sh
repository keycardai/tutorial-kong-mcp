#!/usr/bin/env bash
# Registers Kong's MCP endpoint as a Resource in your Keycard Zone, so the Zone
# can issue tokens for it.
#
# Needs a Keycard service account credential (KEYCARD_CLIENT_ID and
# KEYCARD_CLIENT_SECRET) and KEYCARD_ZONE_ID. MCP_RESOURCE defaults to
# http://localhost:8000/orders/mcp and must match kong/kong.yaml.
set -euo pipefail

: "${KEYCARD_CLIENT_ID:?Set KEYCARD_CLIENT_ID to a service account client ID}"
: "${KEYCARD_CLIENT_SECRET:?Set KEYCARD_CLIENT_SECRET to its secret}"
: "${KEYCARD_ZONE_ID:?Set KEYCARD_ZONE_ID to your Zone ID}"
mcp_resource="${MCP_RESOURCE:-http://localhost:8000/orders/mcp}"
api="https://api.keycard.ai"
zone="$KEYCARD_ZONE_ID"

# Trade the service account credential for a Management API token. Secrets go
# to curl on stdin so they never appear in the process list.
token=$(printf 'user = "%s:%s"\n' "$KEYCARD_CLIENT_ID" "$KEYCARD_CLIENT_SECRET" |
  curl -s --fail-with-body -K - -X POST "$api/service-account-token" -d grant_type=client_credentials |
  python3 -I -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

kc() {
  local method="$1" path="$2"
  shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -s --fail-with-body -K - -X "$method" "$api$path" -H 'Content-Type: application/json' "$@"
}

json() { python3 -I -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

provider_id=$(kc GET "/zones/$zone/providers?type=keycard-sts" | json 'd["items"][0]["id"]')

existing=$(kc GET "/zones/$zone/resources?filter%5Bidentifier%5D=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$mcp_resource")" |
  json '(d.get("items") or [{}])[0].get("id","")')
if [[ -n "$existing" ]]; then
  echo "Resource for $mcp_resource already exists: $existing"
else
  created=$(kc POST "/zones/$zone/resources" -d "{
    \"name\": \"Orders MCP (through Kong)\",
    \"identifier\": \"$mcp_resource\",
    \"scopes\": [\"mcp:tools\"],
    \"credential_provider_id\": \"$provider_id\"
  }" | json 'd["id"]')
  echo "Created the Resource for $mcp_resource: $created"
fi

echo
echo "Set these for kong/kong.yaml:"
echo "export KEYCARD_ZONE_URL=https://$zone.keycard.cloud"
echo "export KEYCARD_JWKS_URL=https://$zone.keycard.cloud/openidconnect/jwks"
echo "export MCP_RESOURCE=$mcp_resource"

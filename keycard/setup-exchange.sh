#!/usr/bin/env bash
# Sets up your Keycard Zone for Kong to exchange each caller's token per call:
#
#   1. An Application for Kong, with a client credential for the exchange
#   2. Kong's MCP endpoint Resource, now provided by that Application
#   3. A Resource for the orders MCP server itself
#   4. The orders server as a dependency of Kong, scoped to Kong's endpoint
#
# Needs the same environment as keycard/setup.sh. Writes Kong's client ID and
# secret to KONG_CREDENTIAL_FILE (default ./kong-gateway.env), which git ignores.
set -euo pipefail

: "${KEYCARD_CLIENT_ID:?Set KEYCARD_CLIENT_ID to a service account client ID}"
: "${KEYCARD_CLIENT_SECRET:?Set KEYCARD_CLIENT_SECRET to its secret}"
: "${KEYCARD_ISSUER:?Set KEYCARD_ISSUER to your Zone URL, https://<zone-id>.keycard.cloud}"
mcp_resource="${MCP_RESOURCE:-http://localhost:8000/orders/mcp}"
orders_resource="${ORDERS_RESOURCE:-http://localhost:8090/mcp}"
app_identifier="${KONG_APP_IDENTIFIER:-kong-ai-gateway}"
cred_file="${KONG_CREDENTIAL_FILE:-./kong-gateway.env}"
api="https://api.keycard.ai"
# The Zone ID is the first label of the issuer's host.
if [[ "$KEYCARD_ISSUER" =~ ^https://([^./]+)\.keycard\.cloud/?$ ]]; then
  zone="${BASH_REMATCH[1]}"
else
  echo "KEYCARD_ISSUER must be your Zone URL, https://<zone-id>.keycard.cloud, not $KEYCARD_ISSUER" >&2
  exit 1
fi

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
urlencode() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

resource_id() {
  kc GET "/zones/$zone/resources?filter%5Bidentifier%5D=$(urlencode "$1")" |
    json '(d.get("items") or [{}])[0].get("id","")'
}

provider_id=$(kc GET "/zones/$zone/providers?type=keycard-sts" | json 'd["items"][0]["id"]')

# 1. The Application Kong authenticates as when it exchanges tokens.
app_id=$(kc GET "/zones/$zone/applications" |
  json "next((a['id'] for a in d.get('items',[]) if a.get('identifier')=='$app_identifier'), '')")
if [[ -z "$app_id" ]]; then
  app_id=$(kc POST "/zones/$zone/applications" \
    -d "{\"name\": \"Kong AI Gateway\", \"identifier\": \"$app_identifier\"}" | json 'd["id"]')
  echo "Created the Application $app_identifier: $app_id"
else
  echo "Application $app_identifier already exists: $app_id"
fi

if [[ -f "$cred_file" ]]; then
  echo "Kong's client credential is already in $cred_file"
else
  # The secret is written straight to the file and never printed.
  umask 077
  kc POST "/zones/$zone/application-credentials" \
    -d "{\"application_id\": \"$app_id\", \"type\": \"password\"}" |
    python3 -I -c '
import sys, json
d = json.load(sys.stdin)
cid = d.get("identifier") or d.get("client_id")
secret = d.get("password") or d.get("secret") or d.get("client_secret")
if not cid or not secret:
    sys.exit("Unexpected credential response, fields: %s" % sorted(d))
print("KONG_KEYCARD_CLIENT_ID=%s\nKONG_KEYCARD_CLIENT_SECRET=%s" % (cid, secret))
' > "$cred_file"
  echo "Created Kong's client credential and saved it to $cred_file"
fi

# 2. Only the Application that provides a Resource may exchange tokens issued for it.
mcp_id=$(resource_id "$mcp_resource")
[[ -n "$mcp_id" ]] || { echo "No Resource for $mcp_resource. Run keycard/setup.sh first." >&2; exit 1; }
kc PATCH "/zones/$zone/resources/$mcp_id" -d "{\"application_id\": \"$app_id\"}" >/dev/null
echo "Kong's endpoint $mcp_resource is now provided by $app_identifier"

# 3. The orders MCP server, which receives the exchanged token.
orders_id=$(resource_id "$orders_resource")
if [[ -z "$orders_id" ]]; then
  orders_id=$(kc POST "/zones/$zone/resources" -d "{
    \"name\": \"Orders MCP server\",
    \"identifier\": \"$orders_resource\",
    \"credential_provider_id\": \"$provider_id\"
  }" | json 'd["id"]')
  echo "Created the Resource for $orders_resource: $orders_id"
else
  echo "Resource for $orders_resource already exists: $orders_id"
fi

# 4. Kong may reach the orders server, but only when a caller is using Kong's endpoint.
kc PUT "/zones/$zone/applications/$app_id/dependencies/$orders_id?when_accessing=$mcp_id" >/dev/null
echo "The orders server is a dependency of $app_identifier when accessing $mcp_resource"

echo
echo "export KEYCARD_TOKEN_URL=https://$zone.keycard.cloud/oauth/2/token"
echo "export ORDERS_RESOURCE=$orders_resource"

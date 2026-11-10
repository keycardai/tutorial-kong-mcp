#!/usr/bin/env bash
# Takes refund_order away from everyone in your Keycard organization, so Kong's exchange for it
# is refused while list_orders keeps working.
#
# A new Keycard organization runs the managed default-zone-policies set, which permits every
# tool. This copies that set as "kong-tutorial", adds one forbid to the copy,
# and activates it. To undo, activate default-zone-policies again in Console.
#
# Needs the same environment as keycard/setup.sh.
set -euo pipefail

: "${KEYCARD_CLIENT_ID:?Set KEYCARD_CLIENT_ID to a service account client ID}"
: "${KEYCARD_CLIENT_SECRET:?Set KEYCARD_CLIENT_SECRET to its secret}"
: "${KEYCARD_ISSUER:?Set KEYCARD_ISSUER to the Keycard issuer URL, https://<id>.keycard.cloud}"
orders_resource="${ORDERS_RESOURCE:-http://localhost:8090/mcp}"
set_name="${POLICY_SET_NAME:-kong-tutorial}"
api="https://api.keycard.ai"
# The issuer ID is the first label of the issuer's host.
if [[ "$KEYCARD_ISSUER" =~ ^https://([^./]+)\.keycard\.cloud/?$ ]]; then
  zone="${BASH_REMATCH[1]}"
else
  echo "KEYCARD_ISSUER must be the Keycard issuer URL, https://<id>.keycard.cloud, not $KEYCARD_ISSUER" >&2
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

set_id() {
  kc GET "/zones/$zone/policy-sets" |
    json "next((s['id'] for s in d.get('items',[]) if s.get('name')=='$1'), '')"
}

copy_id=$(set_id "$set_name")
if [[ -z "$copy_id" ]]; then
  default_id=$(set_id default-zone-policies)
  [[ -n "$default_id" ]] || { echo "No default-zone-policies set in Keycard" >&2; exit 1; }
  copy_id=$(kc POST "/zones/$zone/policy-sets/$default_id/clones" \
    -d "{\"name\": \"$set_name\", \"copy_policies\": \"none\"}" | json 'd["policy_set"]["id"]')
  echo "Copied default-zone-policies as $set_name: $copy_id"
else
  echo "Policy set $set_name already exists: $copy_id"
fi

cedar=$(cat <<EOF
@id("orders-no-refunds")
forbid (
  principal,
  action == Keycard::Action::"mcp::tools/call::refund_order",
  resource
) when {
  resource.identifier == "$orders_resource"
};
EOF
)

existing=$(kc GET "/zones/$zone/policies" |
  json "next((p['id'] for p in d.get('items',[]) if p.get('name')=='orders-no-refunds'), '')")
if [[ -n "$existing" ]]; then
  echo "The orders-no-refunds policy already exists: $existing. If refunds are allowed again, activate $set_name in Console."
  exit 0
fi

# Keep every policy the copy already pins, add the forbid, and activate the
# result in one step.
body=$(kc GET "/zones/$zone/policy-sets/$copy_id/manifest" |
  python3 -I -c '
import sys, json
manifest = json.load(sys.stdin)
entries = [{"policy_id": e["policy_id"], "policy_version_id": e["policy_version_id"]}
           for e in manifest.get("entries", [])]
entries.append({"new_policy": {"name": "orders-no-refunds",
                               "description": "Nobody may refund an order through Kong"},
                "cedar_raw": sys.argv[1]})
print(json.dumps({"schema_version": manifest["schema_version"], "activate": True, "entries": entries}))
' "$cedar")

kc PUT "/zones/$zone/policy-sets/$copy_id/manifest" -d "$body" >/dev/null
echo "Activated $set_name with orders-no-refunds"

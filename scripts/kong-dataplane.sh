#!/usr/bin/env bash
# Creates an AI Gateway in Konnect and runs a local data plane for it in Docker,
# on http://localhost:8000. These are the same steps Kong's AI quickstart
# (https://get.konghq.com/ai) takes, written out so you can read them first.
#
# Needs KONNECT_TOKEN (a Konnect personal access token) in the environment.
# Optional: AI_GATEWAY_NAME, KONNECT_REGION (default us), KONG_IMAGE.
set -euo pipefail

: "${KONNECT_TOKEN:?Set KONNECT_TOKEN to a Konnect personal access token}"
name="${AI_GATEWAY_NAME:-kong-keycard-tutorial}"
region="${KONNECT_REGION:-us}"
image="${KONG_IMAGE:-kong/kong-ai-gateway:latest}"
api="https://${region}.api.konghq.com/v1/ai-gateways"
certs="${HOME}/.kong/${name}"
container="${name}-gateway"

konnect() {
  # The token goes to curl on stdin so it never appears in the process list.
  printf 'header = "Authorization: Bearer %s"\n' "$KONNECT_TOKEN" |
    curl -s --fail-with-body -K - -H 'Accept: application/json' "$@"
}

json() { python3 -I -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

echo "Looking for AI Gateway '${name}' in Konnect (${region})"
gw=$(konnect "${api}?page%5Bsize%5D=100" |
  python3 -I -c "import sys,json; m=[g for g in json.load(sys.stdin).get('data',[]) if (g.get('name') or g.get('display_name'))=='${name}']; print(json.dumps(m[0]) if m else '')")
if [[ -z "$gw" ]]; then
  echo "Creating it"
  gw=$(konnect -X POST "$api" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${name}\",\"display_name\":\"${name}\",\"description\":\"Kong AI Gateway with Keycard\"}")
fi
gw_id=$(echo "$gw" | json 'd["id"]')
cp_endpoint=$(echo "$gw" | json 'd["endpoints"]["configuration"]')
tp_endpoint=$(echo "$gw" | json 'd["endpoints"]["telemetry"]')
echo "AI Gateway ID: ${gw_id}"

if [[ ! -f "${certs}/tls.crt" ]]; then
  echo "Generating the data plane certificate in ${certs}"
  mkdir -p "$certs"
  chmod 0711 "$certs"
  openssl req -new -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj "/CN=${name}/C=US" -keyout "${certs}/key.crt" -out "${certs}/tls.crt" 2>/dev/null
  # Kong runs as a non-root user inside the container and has to read both files.
  chmod 0644 "${certs}/tls.crt"
  chmod 0604 "${certs}/key.crt"
  cert=$(python3 -I -c 'import sys,json; print(json.dumps(open(sys.argv[1]).read()))' "${certs}/tls.crt")
  konnect -X POST "${api}/${gw_id}/data-plane-certificates" -H 'Content-Type: application/json' \
    -d "{\"cert\":${cert},\"title\":\"${name}-certificate\"}" >/dev/null
  echo "Uploaded the certificate to Konnect"
fi

docker rm -f "$container" >/dev/null 2>&1 || true
echo "Starting ${image} as ${container}"
docker run -d --name "$container" \
  -e KONG_ROLE=data_plane \
  -e KONG_DATABASE=off \
  -e KONG_KONNECT_MODE=on \
  -e KONG_CLUSTER_MTLS=pki \
  -e "KONG_CLUSTER_CONTROL_PLANE=${cp_endpoint#https://}:443" \
  -e "KONG_CLUSTER_SERVER_NAME=${cp_endpoint#https://}" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${tp_endpoint#https://}:443" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${tp_endpoint#https://}" \
  -e KONG_LUA_SSL_TRUSTED_CERTIFICATE=system \
  -e KONG_CLUSTER_CERT=/etc/kong/certs/tls.crt \
  -e KONG_CLUSTER_CERT_KEY=/etc/kong/certs/key.crt \
  -e KONG_PROXY_ACCESS_LOG=/dev/stdout \
  -e KONG_PROXY_ERROR_LOG=/dev/stderr \
  -v "${certs}:/etc/kong/certs:ro" \
  -p 8000:8000 \
  "$image" >/dev/null

for _ in $(seq 1 60); do
  if curl -s -o /dev/null http://localhost:8000; then
    echo "Data plane is up on http://localhost:8000"
    echo "export AI_GATEWAY_ID=${gw_id}"
    exit 0
  fi
  sleep 2
done
echo "The data plane didn't come up. Check: docker logs ${container}" >&2
exit 1

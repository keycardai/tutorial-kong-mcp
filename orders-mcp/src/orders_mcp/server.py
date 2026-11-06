"""Orders MCP server for the Kong AI Gateway and Keycard tutorial.

It has one tool that reads and one that writes, so an access policy can allow
one and refuse the other. The orders live in memory and reset on restart.

With KEYCARD_ZONE_URL and GATEWAY_CLIENT_ID set, the server accepts only
tokens your Zone issued to Kong for this server, which is what Kong sends after
it exchanges the caller's token. Without them, it accepts any request, which
is fine while Kong only checks sign-in.
"""

import logging
import os

from fastmcp import FastMCP
from fastmcp.server.auth import AccessToken
from fastmcp.server.auth.providers.jwt import JWTVerifier

logger = logging.getLogger("orders_mcp")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")

ZONE_URL = os.environ.get("KEYCARD_ZONE_URL", "").rstrip("/")
GATEWAY_CLIENT_ID = os.environ.get("GATEWAY_CLIENT_ID", "")
# The Resource identifier this server has in Keycard. Tokens must name it in aud.
SERVER_RESOURCE = os.environ.get("ORDERS_RESOURCE", "http://localhost:8090/mcp")


class GatewayTokenVerifier(JWTVerifier):
    """Accepts a Zone token for this server only if Kong is the client it was issued to.

    A token from the exchange doesn't say which tool it was issued for. Without
    the client check, a caller who got a token for this server some other way
    could call any tool and skip the per-tool decision Kong asked the Zone for.
    """

    async def verify_token(self, token: str) -> AccessToken | None:
        access = await super().verify_token(token)
        if access is None:
            logger.info("refused a token that failed issuer, audience or signature checks")
            return None
        client_id = access.claims.get("client_id")
        if client_id != GATEWAY_CLIENT_ID:
            logger.info("refused a token issued to client %s, not the gateway", client_id)
            return None
        logger.info("accepted a token for sub=%s from the gateway", access.claims.get("sub"))
        return access


auth = None
if ZONE_URL and GATEWAY_CLIENT_ID:
    auth = GatewayTokenVerifier(
        jwks_uri=f"{ZONE_URL}/openidconnect/jwks",
        issuer=ZONE_URL,
        audience=SERVER_RESOURCE,
    )

mcp = FastMCP("Orders", auth=auth)

ORDERS = {
    "A-1001": {"id": "A-1001", "customer": "ada@example.com", "item": "Mechanical keyboard", "total": 129.00, "status": "shipped"},
    "A-1002": {"id": "A-1002", "customer": "grace@example.com", "item": "USB-C dock", "total": 89.50, "status": "pending"},
    "A-1003": {"id": "A-1003", "customer": "alan@example.com", "item": "27-inch monitor", "total": 349.99, "status": "shipped"},
}


@mcp.tool(annotations={"title": "List orders", "readOnlyHint": True})
def list_orders(status: str | None = None) -> list[dict]:
    """List orders, optionally filtered by status: pending, shipped, or refunded."""
    return [o for o in ORDERS.values() if status is None or o["status"] == status]


@mcp.tool(annotations={"title": "Refund an order", "destructiveHint": True})
def refund_order(order_id: str) -> dict:
    """Refund an order by its ID, for example A-1001, and mark it refunded."""
    order = ORDERS.get(order_id)
    if order is None:
        raise ValueError(f"No order with ID {order_id}")
    order["status"] = "refunded"
    return order


def main() -> None:
    if auth is None:
        logger.info("no KEYCARD_ZONE_URL and GATEWAY_CLIENT_ID, so requests are not authenticated")
    mcp.run(
        transport="http",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8090")),
        path="/mcp",
    )


if __name__ == "__main__":
    main()

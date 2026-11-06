"""Orders MCP server for the Kong AI Gateway and Keycard tutorial.

It has one tool that reads and one that writes, so an access policy can allow
one and refuse the other. The orders live in memory and reset on restart.
"""

import os

from fastmcp import FastMCP

mcp = FastMCP("Orders")

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
    mcp.run(
        transport="http",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8090")),
        path="/mcp",
    )


if __name__ == "__main__":
    main()

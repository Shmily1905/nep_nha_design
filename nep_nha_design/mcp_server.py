"""Local stdio MCP server for the SketchUp AI Architect Ruby bridge."""

import argparse
import asyncio
import base64
import binascii
import json
from typing import Annotated, Any, Literal
from uuid import uuid4

from mcp.server.fastmcp import FastMCP, Image
from pydantic import Field
from pydantic import BaseModel

HOST = "127.0.0.1"
PORT = 9876
MAX_IMAGE = 4 * 1024 * 1024
MAX_REPLY = 6 * 1024 * 1024
mcp = FastMCP("Nếp Nhà Design")

ImageSize = Annotated[int, Field(ge=64, le=1600, strict=True)]
AssetName = Annotated[str, Field(min_length=1, max_length=100)]
HexColor = Annotated[str, Field(pattern=r"^#[0-9A-Fa-f]{6}$")]
Opacity = Annotated[float, Field(ge=0.0, le=1.0)]


class BridgeError(RuntimeError):
    """SketchUp rejected the request or the local bridge was unavailable."""


async def rpc(method: str, **params: Any) -> dict[str, Any]:
    request_id = uuid4().hex
    request = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params,
    }
    writer = None
    sent = False
    try:
        async with asyncio.timeout(30):
            reader, writer = await asyncio.open_connection(HOST, PORT, limit=MAX_REPLY)
            writer.write(json.dumps(request, allow_nan=False).encode("utf-8") + b"\n")
            sent = True
            await writer.drain()
            line = await reader.readuntil(b"\n")
    except (TimeoutError, OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as exc:
        if not sent:
            message = "Could not reach SketchUp on 127.0.0.1:9876. Start the Ruby bridge."
        else:
            message = "No complete bridge reply. Check the active model before retrying a mutation."
        raise BridgeError(message) from exc
    finally:
        if writer is not None:
            writer.close()

    try:
        reply = json.loads(line)
    except (UnicodeDecodeError, ValueError) as exc:
        raise BridgeError("Invalid JSON from the SketchUp bridge.") from exc

    if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0" or reply.get("id") != request_id:
        raise BridgeError("SketchUp bridge reply did not match the request.")
    if "error" in reply:
        error = reply["error"]
        if isinstance(error, dict) and "result" not in reply:
            raise BridgeError(f"SketchUp RPC {error.get('code')}: {error.get('message')}")
        raise BridgeError("Invalid error envelope from the SketchUp bridge.")
    if not isinstance(reply.get("result"), dict):
        raise BridgeError("Missing object result from the SketchUp bridge.")
    return reply["result"]


@mcp.tool()
async def ping_sketchup() -> dict[str, Any]:
    """Check the SketchUp bridge and report its SketchUp and Ruby versions."""
    return await rpc("ping_sketchup")


@mcp.tool()
async def get_model_info() -> dict[str, Any]:
    """Read the active model's title, root entity count, and bounds in millimeters."""
    return await rpc("get_model_info")


@mcp.tool()
async def clear_scene(confirm: Annotated[bool, Field(strict=True)] = False) -> dict[str, Any]:
    """Delete all root entities of the active model in one undoable operation. Requires explicit user authorization."""
    if confirm is not True:
        raise BridgeError("Set confirm=true only after the user authorizes deleting the active model's entities.")
    return await rpc("clear_scene", confirm=confirm)


@mcp.tool()
async def capture_viewport(width: ImageSize = 960, height: ImageSize = 540) -> Image:
    """Return a JPEG of the active SketchUp viewport as MCP image content. Dimensions are pixels."""
    result = await rpc("capture_viewport", width=width, height=height)
    encoded = result.get("image_base64")
    if result.get("mime_type") != "image/jpeg" or not isinstance(encoded, str):
        raise BridgeError("The bridge did not return a JPEG.")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise BridgeError("Invalid Base64 viewport image.") from exc
    if len(data) > MAX_IMAGE or not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        raise BridgeError("Invalid or oversized JPEG viewport image.")
    return Image(data=data, format="jpeg")


@mcp.tool()
async def ensure_tag(name: AssetName) -> dict[str, Any]:
    """Find or create a model Tag by name. Returns whether it was created."""
    return await rpc("ensure_tag", name=name)


@mcp.tool()
async def upsert_material(name: AssetName, hex_color: HexColor, opacity: Opacity = 1.0) -> dict[str, Any]:
    """Create a named material or update its color and opacity. Existing assignments see the update."""
    return await rpc("upsert_material", name=name, hex_color=hex_color, opacity=opacity)


class Solid(BaseModel):
    name: AssetName
    footprint_mm: Annotated[list[tuple[float, float]], Field(min_length=3, max_length=32)]
    base_mm: Annotated[float, Field(ge=-100_000, le=100_000)]
    height_mm: Annotated[float, Field(ge=1, le=100_000)]
    hex_color: HexColor
    opacity: Opacity = 1.0
    category: Literal["roof", "wall", "floor", "door", "window", "planter", "other"] = "other"


@mcp.tool()
async def edit_selection(
    ids: Annotated[list[int], Field(min_length=1, max_length=100)],
    action: Literal["rename", "material", "move_mm", "hide_edges"],
    value: str | list[float] | None = None,
) -> dict[str, Any]:
    """Edit exactly the objects selected when the user sent the prompt. Rename
    uses a string, material uses an existing SketchUp material name, move_mm
    uses XYZ offsets, hide_edges hides only the explicitly selected edges."""
    return await rpc("edit_selection", ids=ids, action=action, value=value)


@mcp.tool()
async def prepare_hip_roof_face(
    roof_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")],
    footprint_mm: Annotated[list[tuple[float, float]], Field(min_length=3, max_length=32)],
    elevation_mm: Annotated[float, Field(ge=-100_000, le=100_000)],
) -> dict[str, Any]:
    """Create and select a horizontal roof footprint for the user to run
    1001bit Pro Create Hip Roof. Use exterior wall XY coordinates without
    overhang and the wall plate elevation in mm. Reuse identical input and
    roof_id when retrying. This prepares the face, not the sloped roof."""
    return await rpc(
        "prepare_hip_roof_face", roof_id=roof_id, footprint_mm=footprint_mm,
        elevation_mm=elevation_mm,
    )


@mcp.tool()
async def build_model(
    build_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")],
    name: AssetName,
    scale_basis: Annotated[str, Field(min_length=1, max_length=500)],
    solids: Annotated[list[Solid], Field(min_length=1, max_length=200)],
) -> dict[str, Any]:
    """Add one editable SketchUp group of solid extrusions in mm. Give each solid
    a simple XY polygon without a repeated closing vertex, base Z, height and
    color. Split wall polygons around openings and use sill/header solids.
    Describe the scale anchor or approved concept assumption in scale_basis.
    Reuse the same ID and identical input when retrying an uncertain response.
    """
    return await rpc(
        "build_model", build_id=build_id, name=name, scale_basis=scale_basis,
        solids=[solid.model_dump(mode="json") for solid in solids],
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ping", action="store_true", help="Check the bridge without an MCP client.")
    args = parser.parse_args()
    if args.ping:
        try:
            print(json.dumps(asyncio.run(ping_sketchup()), ensure_ascii=False, indent=2))
        except BridgeError as exc:
            parser.exit(1, f"{exc}\n")
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()

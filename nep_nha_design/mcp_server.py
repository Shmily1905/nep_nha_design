"""Local stdio MCP server for the SketchUp AI Architect Ruby bridge."""

import argparse
import asyncio
import base64
import binascii
import json
import math
from pathlib import Path
from runpy import run_path
from typing import Annotated, Any, Literal
from uuid import uuid4

from mcp.server.fastmcp import FastMCP, Image
from pydantic import Field
from pydantic import BaseModel

HOST = "127.0.0.1"
PORT = 9876
MAX_IMAGE = 4 * 1024 * 1024
MAX_REPLY = 6 * 1024 * 1024
MODEL_GUARD: str | None = None
mcp = FastMCP("Nếp Nhà Design")

ImageSize = Annotated[int, Field(ge=64, le=1600, strict=True)]
AssetName = Annotated[str, Field(min_length=1, max_length=100)]
HexColor = Annotated[str, Field(pattern=r"^#[0-9A-Fa-f]{6}$")]
Opacity = Annotated[float, Field(ge=0.0, le=1.0)]
roof_surfaces = run_path(str(Path(__file__).with_name("hip_roof.py")))["roof_surfaces"]


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
    if MODEL_GUARD:
        request["model_guard"] = MODEL_GUARD
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


Coordinate = Annotated[float, Field(ge=-10_000_000, le=10_000_000, allow_inf_nan=False)]
Point3 = tuple[Coordinate, Coordinate, Coordinate]
Segments = Annotated[int, Field(ge=3, le=180)]
DrawingId = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")]
Ring = Annotated[list[Point3], Field(min_length=1, max_length=180)]


class DrawingItem(BaseModel):
    name: AssetName
    shape: Literal[
        "line", "freehand", "rectangle", "rotated_rectangle", "face", "circle", "polygon",
        "arc", "two_point_arc", "three_point_arc", "pie", "extrusion", "sweep", "revolve",
        "loft", "mesh", "offset", "guide_line", "guide_point", "angle_guide", "dimension",
        "text", "text_3d",
    ]
    points_mm: Annotated[list[Point3], Field(max_length=4096)] = Field(default_factory=list)
    path_mm: Annotated[list[Point3], Field(min_length=2, max_length=256)] | None = None
    direction: Point3 | None = None
    profile_rz_mm: Annotated[list[tuple[Annotated[Coordinate, Field(ge=0)], Coordinate]],
                              Field(min_length=3, max_length=64)] | None = None
    sections_mm: Annotated[list[Ring], Field(min_length=2, max_length=32)] | None = None
    faces: Annotated[list[Annotated[list[int], Field(min_length=3, max_length=180)]],
                     Field(min_length=1, max_length=8192)] | None = None
    segments: Segments = 32
    sweep_deg: Annotated[float, Field(ge=-360, le=360)] | None = None
    solid: bool = False
    filled: bool = False
    smooth_angle_deg: Annotated[float, Field(ge=0, le=90)] | None = None
    depth_mm: Annotated[float, Field(ge=-100_000, le=100_000)] = 0
    offset_mm: Annotated[float, Field(ge=-100_000, le=100_000)] | None = None
    height_mm: Annotated[float, Field(ge=1, le=10_000)] | None = None
    text: Annotated[str, Field(min_length=1, max_length=300)] | None = None
    material: AssetName | None = None
    tag: AssetName | None = None


def revolve_mesh(item: DrawingItem) -> tuple[list, list]:
    profile = item.profile_rz_mm
    if len(item.points_mm) != 1 or not profile or len(set(profile)) != len(profile):
        raise BridgeError("Revolve needs one origin and a simple closed radius/Z profile with no repeated point.")
    if not simple_loop(profile):
        raise BridgeError("Revolve profile must not intersect itself.")
    area = sum(r * next_z - next_r * z for (r, z), (next_r, next_z)
               in zip(profile, profile[1:] + profile[:1]))
    if abs(area) < 1e-6:
        raise BridgeError("Revolve profile must enclose an area.")
    if area < 0:
        profile = list(reversed(profile))
    x, y, base_z = item.points_mm[0]
    points, rings = [], []
    for radius, z in profile:
        rings.append(list(range(len(points), len(points) + (item.segments if radius else 1))))
        angles = (math.tau * i / item.segments for i in range(len(rings[-1])))
        points.extend((x + radius * math.cos(a), y + radius * math.sin(a), base_z + z) for a in angles)
    faces = []
    for bottom, top in zip(rings, rings[1:] + rings[:1]):
        faces.extend(join_rings(bottom, top))
    return points, faces


def join_rings(lower: list[int], upper: list[int], *, split: bool = False) -> list[list[int]]:
    sides = max(len(lower), len(upper))
    if sides == 1:
        return []
    faces = []
    for i in range(sides):
        j = (i + 1) % sides
        if len(lower) == 1:
            faces.append([lower[0], upper[j], upper[i]])
        elif len(upper) == 1:
            faces.append([lower[i], lower[j], upper[0]])
        elif split:
            faces.extend(([lower[i], lower[j], upper[j]], [lower[i], upper[j], upper[i]]))
        else:
            faces.append([lower[i], lower[j], upper[j], upper[i]])
    return faces


def loft_mesh(item: DrawingItem) -> tuple[list, list]:
    sections = item.sections_mm
    if not sections:
        raise BridgeError("Loft needs at least two ordered sections.")
    sides = max(map(len, sections))
    if sides < 3 or any(len(section) != sides and
                        not (len(section) == 1 and index in (0, len(sections) - 1))
                        for index, section in enumerate(sections)):
        raise BridgeError("Loft rings must have matching vertex counts; only end sections can be a single apex.")
    points, rings = [], []
    for section in sections:
        rings.append(list(range(len(points), len(points) + len(section))))
        points.extend(section)
    faces = [face for lower, upper in zip(rings, rings[1:]) for face in join_rings(lower, upper, split=True)]
    if item.solid:
        if len(rings[0]) > 1:
            faces.append(rings[0][::-1])
        if len(rings[-1]) > 1:
            faces.append(rings[-1])
    return points, faces


@mcp.tool()
async def draw_geometry(
    operation_id: DrawingId,
    name: AssetName,
    items: Annotated[list[DrawingItem], Field(min_length=1, max_length=32)],
) -> dict[str, Any]:
    """Create independent editable groups together in one undoable operation. World XYZ in mm.
    Reuse ID and identical inputs after an uncertain reply. Results include IDs, bounds, faces and Solid status.
    Line/freehand: ordered points. Face/rectangle: ordered planar corners, without repeated first vertex.
    Circle/polygon/arc/pie: center, radius point, point on plane; arc/pie need sweep_deg.
    Two/three-point arc: start, point on arc (e.g. bulge), end. Circle/polygon support filled.
    Extrusion: profile in points_mm, normal direction, signed depth_mm; creates a closed solid.
    Sweep: profile in points_mm normal to the first segment, path_mm ordered (repeat first point for a loop).
    Revolve: points_mm=[axis origin], closed profile_rz_mm as [radius, relative Z], no repeated first point.
    For a cone give [0,0], [radius,0], [0,height]; for a cylinder add [radius,height] before [0,height].
    Loft: consecutive planar rings with matching ordered vertices; optional single-point end apex.
    Orient rings counterclockwise looking from the last section towards the first. Set solid=true to cap.
    Mesh: unique XYZ vertices and oriented planar faces referencing zero-based indices. Triangulate warped faces.
    Offset: simple constant-Z polygon and signed offset_mm (positive outward); filled fills the new boundary.
    Guides: point, line endpoints, or angle vertex/baseline/plane point plus sweep_deg.
    Dimension: endpoints, then offset vector. Text: insertion point and text; 3D text also needs height_mm.
    Existing material and tag names are optional. smooth_angle_deg applies to mesh, loft and revolve.
    """
    prepared = []
    face_count = 0
    for item in items:
        data = item.model_dump(mode="json", exclude_none=True)
        if item.shape in ("revolve", "loft"):
            points, faces = revolve_mesh(item) if item.shape == "revolve" else loft_mesh(item)
            data.update(shape="mesh", points_mm=points, faces=faces)
            data.pop("profile_rz_mm" if item.shape == "revolve" else "sections_mm", None)
            if item.shape == "revolve":
                data["solid"] = True
                data.setdefault("smooth_angle_deg", 30)
        if len(data["points_mm"]) > 4096:
            raise BridgeError("Use at most 4096 vertices per object.")
        face_count += len(data.get("faces", ()))
        prepared.append(data)
    if face_count > 8192 or len(json.dumps(prepared).encode("utf-8")) > 500 * 1024:
        raise BridgeError("Drawing batch too large; reduce subdivision or split into separate builds.")
    return await rpc("draw_geometry", operation_id=operation_id, name=name, items=prepared)


SelectionIds = Annotated[list[int], Field(min_length=1, max_length=100)]


@mcp.tool()
async def inspect_drawing(ids: SelectionIds | None = None) -> dict[str, Any]:
    """Inspect explicit IDs or the current selection. With no selection, lists entities in the active context.
    Returns bounds, face loops and edge endpoints. With no IDs also lists materials and tags."""
    return await rpc("inspect_drawing", ids=ids)


@mcp.tool()
async def select_drawing(ids: SelectionIds) -> dict[str, Any]:
    """Select explicit inspected entity IDs in the active editing context. Use when the user asks to locate/select objects."""
    return await rpc("select_drawing", ids=ids)


@mcp.tool()
async def edit_drawing(
    ids: SelectionIds,
    action: Literal["tag", "push_pull", "rotate", "scale", "flip", "paint", "erase",
                    "hide", "soften", "unsoften", "component", "follow_me", "move",
                    "union", "subtract", "intersect", "position_texture", "make_unique"],
    pivot_mm: Point3 | None = None,
    axis: Point3 | None = None,
    angle_deg: float | None = None,
    factors: Point3 | None = None,
    axis_name: Literal["x", "y", "z"] | None = None,
    distance_mm: float | None = None,
    copy: bool = False,
    tag: AssetName | None = None,
    material: AssetName | None = None,
    back: bool = False,
    path_ids: Annotated[list[int], Field(max_length=99)] | None = None,
    offset_mm: Point3 | None = None,
    mapping: Annotated[list[tuple[Point3, tuple[Coordinate, Coordinate]]], Field(min_length=2, max_length=4)] | None = None,
) -> dict[str, Any]:
    """Modify exactly the checked selection. Move uses offset_mm. Rotate uses pivot, axis, angle.
    Scale uses pivot/factors. Flip uses pivot and axis_name or an arbitrary plane normal axis.
    Copy for transforms repeats the selected groups/components as independent placements.
    Erase removes selected edges and may remove adjacent faces; use only when deletion was requested.
    Follow Me uses the one selected face and ordered path_ids. For new geometry prefer draw_geometry sweep.
    Boolean operations use two selected solid groups (first minus second for subtract), replacing both.
    position_texture uses a selected face, existing textured material, and pairs of [point in active axes mm, UV].
    make_unique gives selected instances independent definitions.
    """
    return await rpc("edit_drawing", ids=ids, action=action, pivot_mm=pivot_mm, axis=axis,
                     angle_deg=angle_deg, factors=factors, axis_name=axis_name, distance_mm=distance_mm,
                     copy=copy, tag=tag, material=material, back=back, path_ids=path_ids, offset_mm=offset_mm,
                     mapping=mapping)


@mcp.tool()
async def drawing_camera(
    action: Literal["extents", "selection", "position", "zoom", "previous", "orbit", "pan", "walk", "look", "fov"],
    eye_mm: Point3 | None = None,
    target_mm: Point3 | None = None,
    up: Point3 = (0, 0, 1),
    fov_deg: Annotated[float, Field(ge=1, le=120)] | None = None,
    factor: Annotated[float, Field(ge=0.1, le=10)] | None = None,
    delta_mm: Point3 | None = None,
    axis: Point3 = (0, 0, 1),
    angle_deg: Annotated[float, Field(ge=-360, le=360)] | None = None,
    perspective: bool = True,
) -> dict[str, Any]:
    """Adjust the active viewport. Position sets eye/target/up; orbit rotates around target;
    look rotates about eye; pan translates eye/target; walk translates horizontally by delta_mm.
    Zoom uses factor; selection frames selected geometry; previous restores the last MCP camera."""
    return await rpc("drawing_camera", action=action, eye_mm=eye_mm, target_mm=target_mm, up=up,
                     fov_deg=fov_deg, factor=factor, delta_mm=delta_mm, axis=axis,
                     angle_deg=angle_deg, perspective=perspective)


@mcp.tool()
async def measure_drawing(points_mm: Annotated[list[Point3], Field(min_length=2, max_length=3)]) -> dict[str, Any]:
    """Measure distance in mm between two points or angle in degrees at the middle of three points."""
    return await rpc("measure_drawing", points_mm=points_mm)


@mcp.tool()
async def set_drawing_axes(origin_mm: Point3, red_mm: Point3, green_mm: Point3) -> dict[str, Any]:
    """Set drawing origin, red direction and green side from three world points in mm."""
    return await rpc("set_drawing_axes", origin_mm=origin_mm, red_mm=red_mm, green_mm=green_mm)


class Solid(BaseModel):
    name: AssetName
    footprint_mm: Annotated[list[tuple[float, float]], Field(min_length=3, max_length=32)]
    base_mm: Annotated[float, Field(ge=-100_000, le=100_000)]
    height_mm: Annotated[float, Field(ge=1, le=100_000)]
    hex_color: HexColor
    opacity: Opacity = 1.0
    material_key: AssetName | None = None
    category: Literal["roof", "wall", "floor", "door", "window", "planter", "other"] = "other"


@mcp.tool()
async def build_hip_roof(
    operation_id: DrawingId,
    footprint_mm: Annotated[list[tuple[Coordinate, Coordinate]], Field(min_length=3, max_length=32)],
    elevation_mm: Coordinate,
    pitch_deg: Annotated[float, Field(ge=1, le=80)] = 30,
    overhang_mm: Annotated[float, Field(ge=0, le=10_000)] = 500,
    fascia_mm: Annotated[float, Field(ge=0, le=3000)] = 150,
) -> dict[str, Any]:
    """Build a sloped hip roof with fascia on a convex or orthogonal L footprint.
    Supply outside wall outline before overhang and plate elevation. World mm."""
    if len(set(footprint_mm)) != len(footprint_mm):
        raise BridgeError("Roof footprint repeats vertices.")
    try:
        # Check simplicity before passing the outline to the roof solver.
        if not simple_loop(footprint_mm):
            raise ValueError("Roof footprint is self-intersecting.")
        surfaces = roof_surfaces(footprint_mm, elevation_mm, pitch=pitch_deg, overhang=overhang_mm)
    except ValueError as exc:
        raise BridgeError(str(exc)) from exc
    if not surfaces:
        raise BridgeError("No hip roof generated from this outline. Check the outline or construct explicit roof surfaces.")
    return await rpc("build_hip_roof", operation_id=operation_id, roof_faces_mm=surfaces,
                     height_mm=elevation_mm, pitch=pitch_deg, overhang_mm=overhang_mm, fascia_mm=fascia_mm)


def simple_loop(points):
    edges = list(zip(points, points[1:] + points[:1]))
    return not any(segments_cross(a, b, c, d)
                   for i, (a, b) in enumerate(edges) for j, (c, d) in enumerate(edges[i + 2:], i + 2)
                   if not (i == 0 and j == len(edges) - 1))


def segments_cross(a, b, c, d):
    def turn(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])

    return (all(max(min(a[k], b[k]), min(c[k], d[k])) <= min(max(a[k], b[k]), max(c[k], d[k]))
                for k in range(2)) and
            turn(a, b, c) * turn(a, b, d) <= 0 and turn(c, d, a) * turn(c, d, b) <= 0)


class WallOpening(BaseModel):
    start_mm: tuple[float, float]
    end_mm: tuple[float, float]
    wall_thickness_mm: Annotated[float, Field(ge=20, le=3000)]
    sill_mm: Annotated[float, Field(ge=0, le=100_000)] = 0
    height_mm: Annotated[float, Field(ge=50, le=100_000)]
    kind: Literal["door", "window"] = "door"


class Opening(WallOpening):
    wall_index: Annotated[int, Field(ge=0, lt=200)]


@mcp.tool()
async def inspect_wall(wall_id: int) -> dict[str, Any]:
    """Read the one selected solid wall: bounds and outer face loops in mm,
    relative to the current edit context. Use before cutting an existing wall."""
    return await rpc("inspect_wall", wall_id=wall_id)


@mcp.tool()
async def cut_existing_wall(wall_id: int, opening: WallOpening) -> dict[str, Any]:
    """Cut one opening in the inspected selected solid only. Coordinates are in
    the active editing context. Use opening width endpoints on the wall centerline,
    measured thickness, sill from wall base and height in mm. SketchUp returns a
    replacement group with a new ID. Tall doors get fixed glazing above 2400 mm."""
    return await rpc("cut_existing_wall", wall_id=wall_id, opening=opening.model_dump(mode="json"))


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
    openings: Annotated[list[Opening], Field(max_length=100)] | None = None,
) -> dict[str, Any]:
    """Add one editable SketchUp group of solid extrusions in mm. Give each solid
    a simple XY polygon without a repeated closing vertex, base Z, height and
    color. Supply complete wall solids, then openings with zero-based wall
    index, width endpoints along the wall centerline and actual wall thickness.
    Sill is relative to that wall base. Door heights: 2200/2400/2600/2700/2800.
    Taller doors get fixed glazing above 2400 mm. Use distinct material_key
    values for distinct materials, and reuse keys and colors for matching ones.
    Describe the scale anchor or approved concept assumption in scale_basis.
    Reuse the same ID and identical input when retrying an uncertain response.
    """
    return await rpc(
        "build_model", build_id=build_id, name=name, scale_basis=scale_basis,
        solids=[solid.model_dump(mode="json", exclude_none=True) for solid in solids],
        **({"openings": [opening.model_dump(mode="json") for opening in openings]} if openings else {}),
    )


def main() -> None:
    global MODEL_GUARD

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ping", action="store_true", help="Check the bridge without an MCP client.")
    parser.add_argument("--model-guard", help=argparse.SUPPRESS)
    args = parser.parse_args()
    MODEL_GUARD = args.model_guard
    if args.ping:
        try:
            print(json.dumps(asyncio.run(ping_sketchup()), ensure_ascii=False, indent=2))
        except BridgeError as exc:
            parser.exit(1, f"{exc}\n")
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()

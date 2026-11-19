"""Convert a reviewed floor plan into one SketchUp build operation."""

import json
from math import cos, hypot, isfinite, sin, tau
from pathlib import Path
import re
from runpy import run_path
import unicodedata
from uuid import uuid4

_roof = run_path(str(Path(__file__).with_name("hip_roof.py")))
FLOOR = r"(?:tang\s+(?:tret|ap mai|\d+)|(?:lau|tum)\b(?:\s+\d+)?|ap mai|tret)"
ATTIC = "tang ap mai"
GARDEN_FINISHES = {
    "water": ("#449FB9", "Mặt nước", 0.55),
    "path": ("#ACA59B", "Nền lát", 1.0),
    "wood": ("#937456", "Gỗ sân vườn", 1.0),
    "gravel": ("#CABFB1", "Sỏi sân vườn", 1.0),
    "planter": ("#78865A", "Bồn cây", 1.0),
    "rock": ("#85827C", "Đá cảnh", 1.0),
    "soil": ("#82694F", "Đất sân vườn", 1.0),
    "grass": ("#7A9364", "Cỏ sân vườn", 1.0),
}


def with_finish(part, finish):
    color, material, opacity = finish
    specified_color = part.get("hex_color")
    specified_material = part.get("material_key")
    specified_opacity = part.get("opacity")
    return {
        **part,
        "hex_color": specified_color if isinstance(specified_color, str)
        and re.fullmatch(r"#[0-9a-fA-F]{6}", specified_color) else color,
        "material_key": specified_material if isinstance(specified_material, str)
        and 1 <= len(specified_material.strip()) <= 100 else material,
        "opacity": specified_opacity if number(specified_opacity, 0, 1) else opacity,
    }


class PlanReplyNeedsBuild(ValueError):
    """The planner asked about an item already resolved by the user."""


def normalized(value):
    value = unicodedata.normalize("NFD", value.lower().replace("đ", "d"))
    return "".join(c for c in value if not unicodedata.combining(c))


def floor_key(name):
    key = " ".join(normalized(name).split())
    return {"tret": "tang tret", "ap mai": "tang ap mai"}.get(key, key)


def plan_omissions(latest, reviewed, known, pending_floor, previous):
    omitted = {ATTIC} if isinstance(previous, list) and ATTIC in previous else set()
    latest = normalized(latest).strip()
    if re.search(r"\b(?:dung|ve|lam)\s+(?:lai\s+)?(?:tuong\s+)?(?:tang\s+)?ap mai\b", latest) and not re.search(
        r"\b(?:chua|khong|bo qua|de sau|tam bo)\b", latest
    ):
        omitted.discard(ATTIC)
    skip = re.search(r"\b(?:chua can|khong can|chua dung|khong dung|tam bo|bo qua|de sau)\b", latest)
    if not skip:
        return omitted
    if "ap mai" in latest:
        return omitted | {ATTIC}
    if re.search(r"\b(?:tuong|tang|phan)\s+(?:nay|do)\b", latest):
        missing = {floor_key(name) for name in (reviewed or []) if isinstance(name, str)}
        missing -= known.get("heights_mm", {}).keys()
        if pending_floor == ATTIC or (not pending_floor and missing == {ATTIC}):
            return omitted | {ATTIC}
    return omitted


def plan_dimensions(message):
    """Recognize labelled replies even if a previous UI cannot send review state."""
    plain = normalized(message)
    amount = r"\s*[:=]?\s*(\d+(?:[.,]\d+)?)[ \t]*(mm\b|cm\b|m\b|do\b|°|%)?"

    def convert(match, index, *, length):
        raw, unit = match.group(index, index + 1)
        value = float(raw.replace(",", "."))
        if length and unit in (None, "mm", "cm", "m"):
            return value * {None: 1, "mm": 1, "cm": 10, "m": 1000}[unit]
        if not length and unit in (None, "do", "°"):
            return value
        return None

    values = {"heights_mm": {}}
    for match in re.finditer(r"\b(" + FLOOR + r")" + amount, plain):
        # In a label such as “sàn đến sàn”, conversion also depends on slab thickness.
        prefix = plain[plain.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"san\s+(?:den|toi)\s+san|cao do|cot\s*$", prefix):
            continue
        value = convert(match, 2, length=True)
        if number(value, 1000, 30_000):
            values["heights_mm"][floor_key(match[1])] = value
    for key, label, limit, length in (
        ("pitch_deg", r"(?:do\s+)?doc\s+mai", 80, False),
        ("overhang_mm", r"(?:do\s+)?(?:vuon|dua)\s+mai", 10_000, True),
    ):
        for match in re.finditer(r"\b" + label + amount, plain):
            value = convert(match, 1, length=length)
            if number(value, 0, limit):
                values[key] = value
    if not values["heights_mm"]:
        del values["heights_mm"]
    return values


def number(value, minimum=-100_000, maximum=100_000):
    return type(value) in (int, float) and isfinite(value) and minimum <= value <= maximum


def point(value, size=2):
    return isinstance(value, list) and len(value) == size and all(number(v) for v in value)


def polygon(value, size=2):
    return (isinstance(value, list) and 3 <= len(value) <= 32
            and all(point(p, size) for p in value) and len(set(map(tuple, value))) == len(value))


def entries(data, key, limit=200):
    items = data.get(key, [])
    if not isinstance(items, list) or len(items) > limit or any(not isinstance(item, dict) for item in items):
        raise ValueError(f"Dữ liệu {key} trên mặt bằng không hợp lệ.")
    return items


def railing_solids(data, level, default_z):
    a, b = data.get("start_mm"), data.get("end_mm")
    height = data.get("height_mm", 1100)
    base = data.get("base_mm", default_z)
    style = data.get("style", "metal")
    if (not point(a) or not point(b) or not number(height, 200, 3000) or not number(base)
            or style not in ("metal", "glass", "solid")):
        raise ValueError("Vị trí hoặc kiểu lan can không hợp lệ.")
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = hypot(dx, dy)
    if length < 100:
        raise ValueError("Đoạn lan can phải dài ít nhất 100 mm.")
    ux, uy = dx / length, dy / length

    def bar(name, x0, x1, z, h, thickness, color="#41474D", opacity=1.0):
        footprint = [[a[0] + ux * x - uy * y, a[1] + uy * x + ux * y]
                     for x, y in ((x0, thickness / 2), (x1, thickness / 2),
                                  (x1, -thickness / 2), (x0, -thickness / 2))]
        return dict(name=name, footprint_mm=footprint, base_mm=base + z, height_mm=h,
                    hex_color=color, opacity=opacity, category="railing", level=level)

    if style == "solid":
        return [bar("Lan can xây", 0, length, 0, height, 120, "#B4B4B2")]
    parts = [bar("Tay vịn", 0, length, height - 50, 50, 50)]
    if style == "glass":
        parts.append(bar("Kính lan can", 0, length, 60, height - 110, 15, "#77BDD6", 0.45))
        return parts
    parts.append(bar("Thanh ngang dưới", 0, length, 60, 30, 30))
    divisions = max(1, round(length / 140))
    if divisions > 300:
        raise ValueError("Hãy chia lan can dài thành nhiều đoạn.")
    for position in range(divisions + 1):
        x = 12 + (length - 24) * position / divisions
        parts.append(bar("Thanh đứng", x - 12, x + 12, 0, height - 50, 24))
    return parts


def tree_solids(data):
    center = data.get("center_mm")
    height = data.get("height_mm")
    radius = data.get("radius_mm")
    base = data.get("base_mm", 0)
    style = data.get("style", "general")
    if (not point(center) or not number(height, 200, 30_000) or not number(radius, 50, 15_000)
            or not number(base) or style not in ("general", "zen", "tropical")):
        raise ValueError("Thiếu vị trí hoặc kích thước cây trên mặt bằng.")
    canopy = {"zen": (0.42, "#657652"), "tropical": (0.60, "#24764A"),
              "general": (0.48, "#46854B")}
    crown_base, color = canopy[style]
    x, y = center

    def part(name, r, z, h, finish):
        ring = [[x + r * cos(tau * i / 12), y + r * sin(tau * i / 12)] for i in range(12)]
        return dict(name=name, footprint_mm=ring, base_mm=base + z, height_mm=h,
                    hex_color=finish, category="tree")

    name = str(data.get("name") or "Cây")[:75]
    crown = height * (1 - crown_base)
    z = height * crown_base
    return [part(f"{name} · thân", max(15, radius * 0.10), 0, z, "#695443"),
            part(f"{name} · tán dưới", radius * 0.72, z, crown * 0.24, color),
            part(f"{name} · tán giữa", radius, z + crown * 0.24, crown * 0.49, color),
            part(f"{name} · tán trên", radius * 0.60, z + crown * 0.73, crown * 0.27, color)]


def prepare_roof(roof, highest_level, *, defer):
    if not isinstance(roof, dict):
        raise ValueError("Chưa xác định được thông số đặt mái.")
    pitch, overhang = roof.get("pitch_deg"), roof.get("overhang_mm")
    footprint = roof.get("footprint_mm")
    kind = roof.get("type", "hip")
    elevation = roof.get("elevation_mm", highest_level)
    if (not polygon(footprint) or not number(pitch, 0, 80) or not number(overhang, 0, 10_000)
            or not number(elevation) or kind not in ("hip", "gable", "shed", "flat", "custom")
            or (kind != "flat" and pitch < 1)):
        raise ValueError("Kiểm tra độ dốc, độ vươn, cao độ hoặc đường bao đặt mái.")
    geometry = dict(type=kind, footprint_mm=footprint, pitch_deg=pitch,
                    overhang_mm=overhang, elevation_mm=elevation)
    if defer:
        return None, None, geometry
    if kind == "hip":
        faces = _roof["roof_surfaces"](footprint, elevation, pitch=pitch, overhang=overhang)
        if faces:
            return "hip_roof", dict(roof_faces_mm=faces, height_mm=elevation, pitch=pitch,
                                    overhang_mm=overhang, fascia_mm=_roof["FASCIA"]), geometry
    faces = roof.get("faces_mm")
    if not isinstance(faces, list) or not 1 <= len(faces) <= 128 or not all(polygon(face, 3) for face in faces):
        raise ValueError("Chưa xác định được các mặt mái từ đường bao và thông số đã chốt.")
    name = {"hip": "Mái hông", "gable": "Mái hai dốc", "shed": "Mái một dốc",
            "flat": "Mái bằng", "custom": "Mái"}[kind]
    return "roof_faces", dict(name=name, faces_mm=faces), geometry


def ask_missing(missing, known, omitted):
    if not isinstance(missing, list) or not missing or len(missing) > 15:
        raise ValueError("Trợ lý chưa chỉ rõ thông tin còn thiếu. Hãy gửi lại câu trả lời.")
    questions = []
    targets = []
    for item in missing:
        if not isinstance(item, dict):
            raise ValueError("Câu hỏi bổ sung không hợp lệ.")
        field, name = item.get("field"), item.get("floor", "")
        if field == "height" and isinstance(name, str) and 1 <= len(name.strip()) <= 80:
            if floor_key(name) not in known.get("heights_mm", {}) and floor_key(name) not in omitted:
                questions.append(f"Chiều cao từ sàn đến đỉnh tường của {name} là bao nhiêu mm?")
                targets.append(floor_key(name))
        elif field == "attic":
            if ATTIC not in omitted and ATTIC not in known.get("heights_mm", {}):
                questions.append("Phần áp mái là một tầng có tường riêng hay chỉ là mặt bằng mái?"
                                 " Nếu có tầng riêng, bạn cho tôi chiều cao từ sàn đến đỉnh tường của tầng đó.")
                targets.append(ATTIC)
        elif field == "pitch":
            if "pitch_deg" not in known:
                questions.append("Độ dốc mái là bao nhiêu độ?")
        elif field == "overhang":
            if "overhang_mm" not in known:
                questions.append("Độ vươn mái là bao nhiêu mm?")
        elif field in ("scale", "opening", "other"):
            detail = item.get("detail")
            if isinstance(detail, str) and detail.strip():
                questions.append(detail.strip()[:400])
    if not questions:
        raise PlanReplyNeedsBuild("Trợ lý chưa lập được dữ liệu dựng cho phần đã chốt.")
    pending = targets[0] if len(questions) == len(targets) and len(set(targets)) == 1 else None
    return "\n".join(dict.fromkeys(questions)), pending


def exterior_build(result, reviewed_floors=None, known=None, omitted=()):
    known = known or {}
    raw = result["text"].strip()
    fenced = re.fullmatch(r"```(?:json)?\s*([\s\S]*?)\s*```", raw, re.IGNORECASE)
    proposal = json.loads(fenced[1] if fenced else raw)
    if not isinstance(proposal, dict):
        raise ValueError("Trợ lý chưa trả thông số dựng hợp lệ.")
    if not reviewed_floors and not known and not omitted:
        names = proposal.get("floor_names")
        if not (isinstance(names, list) and len(names) <= 10
                and all(isinstance(name, str) and 0 < len(name.strip()) <= 80 for name in names)):
            raise ValueError("Chưa đọc được danh sách tầng từ mặt bằng. Hãy gửi lại yêu cầu.")
        description = ", ".join(names) if names else "từng tầng"
        question = f"Bạn cho tôi chiều cao từ sàn hoàn thiện đến đỉnh tường của {description}, độ dốc mái (°) và độ vươn mái (mm) nhé."
        detail = proposal.get("question")
        if isinstance(detail, str) and detail.strip():
            question += "\n" + detail.strip()[:1200]
        return dict(ok=True, text=question, needs_dimensions=True, review_floors=names or ["Chưa xác định"])
    if "missing" in proposal:
        question, pending = ask_missing(proposal["missing"], known, omitted)
        return dict(ok=True, text=question, needs_dimensions=True, pending_plan_floor=pending,
                    omitted_plan_floors=sorted(omitted), review_floors=reviewed_floors or ["Chưa xác định"])
    levels = entries(proposal, "levels", 10)
    if any(isinstance(level.get("name"), str) and floor_key(level["name"]) in omitted for level in levels):
        raise PlanReplyNeedsBuild("Dữ liệu dựng vẫn chứa phần áp mái đã yêu cầu bỏ qua.")
    if reviewed_floors:
        reviewed_floors = [name for name in reviewed_floors if floor_key(name) not in omitted]
    floor_count_reason = proposal.get("floor_count_reason")
    if not isinstance(floor_count_reason, str) or not floor_count_reason.strip():
        floor_count_reason = ""
    if not levels or (reviewed_floors and reviewed_floors != ["Chưa xác định"]
                      and len(levels) != len(reviewed_floors) and not floor_count_reason):
        raise ValueError("Số tầng dựng chưa khớp với mặt bằng đã đọc.")
    scale = proposal.get("scale_basis")
    if not isinstance(scale, str) or not scale.strip():
        raise ValueError("Chưa có mốc tỷ lệ đáng tin cậy.")
    solids, openings, details = [], [], []
    roof_elevation, next_base = None, 0
    for level in levels:
        name = level.get("name")
        height = level.get("height_mm")
        if isinstance(name, str):
            height = known.get("heights_mm", {}).get(floor_key(name), height)
        base = level.get("base_mm", next_base)
        slab = level.get("slab_mm", 150)
        if (not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or not number(height, 1000, 30_000)
                or not number(base) or not number(slab, 30, 1500) or any(d["name"] == name for d in details)):
            raise ValueError("Thiếu chiều cao, cao độ hoặc tên phân biệt của một tầng.")
        walls, floors = entries(level, "walls"), entries(level, "floors")
        if not walls or not floors:
            raise ValueError(f"Chưa đọc được tường hoặc sàn của {name}.")
        first_wall = len(solids)
        for part in walls:
            solids.append({**part, "category": "wall", "level": name, "base_mm": base,
                           "height_mm": height, "hex_color": "#777777", "material_key": "Tường"})
        for part in entries(level, "columns"):
            solids.append({**part, "category": "column", "level": name, "base_mm": base,
                           "height_mm": height, "hex_color": "#171717", "material_key": "Cột"})
        for part in floors:
            floor = with_finish(part, ("#BCB6AA", "Sàn", 1.0))
            solids.append(dict(floor, category="floor", level=name, base_mm=part.get("base_mm", base - slab),
                               height_mm=part.get("height_mm", slab)))
        for opening in entries(level, "openings", 100):
            index = opening.get("wall_index")
            counts = opening.get("leaves_per_frame")
            if (type(index) is not int or not 0 <= index < len(walls)
                    or not isinstance(counts, list) or not 1 <= len(counts) <= 12
                    or any(type(count) is not int or not 0 <= count <= 12 for count in counts)):
                raise ValueError(f"Chưa rõ số khung hoặc số cánh của một ô cửa tại {name}.")
            openings.append(dict(opening, wall_index=first_wall + index, frame_count=len(counts)))
        for rail in entries(level, "railings", 64):
            solids.extend(railing_solids(rail, name, base))
        if level.get("roof_bearing") is True:
            if roof_elevation is not None:
                raise ValueError("Chọn một tầng sát mái làm mặt đặt mái.")
            roof_elevation = base + height
        details.append(dict(name=name, base_mm=base, height_mm=height))
        next_base = base + height + slab
    if roof_elevation is None:
        roof_elevation = details[-1]["base_mm"] + details[-1]["height_mm"]
    for item in entries(proposal, "garden"):
        kind = item.get("kind")
        kind = kind if isinstance(kind, str) else ""
        name = item.get("name")
        if kind == "path" and isinstance(name, str) and re.search(r"\bgo\b", normalized(name)):
            kind = "wood"
        finish = GARDEN_FINISHES.get(kind, ("#ACA59B", "Sân vườn", 1.0))
        category = "water" if kind == "water" else "garden"
        solids.append(dict(with_finish(item, finish), category=category))
    for tree in entries(proposal, "trees", 100):
        solids.extend(tree_solids(tree))
    if len(solids) > 1200 or len(openings) > 300:
        raise ValueError("Mặt bằng có quá nhiều cấu kiện để dựng trong một lần.")
    multi = len(levels) >= 2
    roof = proposal.get("roof")
    if isinstance(roof, dict):
        roof = {**roof, **{key: known[key] for key in ("pitch_deg", "overhang_mm") if key in known}}
    roof_key, roof_payload, roof_context = prepare_roof(roof, roof_elevation, defer=multi)
    build = dict(build_id=uuid4().hex, name="Nhà theo mặt bằng", scale_basis=scale.strip()[:500],
                 solids=solids, openings=openings, fit_openings=True, plan_levels=True)
    if roof_key:
        build[roof_key] = roof_payload
    scope_note = "Đã để phần áp mái lại cho lượt sau theo yêu cầu." if ATTIC in omitted else ""
    notes = "\n".join(filter(None, (str(proposal.get("notes", "")), floor_count_reason, scope_note)))
    return dict(ok=True, text=notes[:1800], exterior_build=build,
                plan_context=dict(levels=details, roof=roof_context, roof_deferred=multi))

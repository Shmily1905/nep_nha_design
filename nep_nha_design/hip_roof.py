"""Generate concept hip-roof faces from a horizontal footprint in millimeters."""

from math import hypot, radians, tan

PITCH = 30
OVERHANG = 500
FASCIA = 150
EPS = 1e-6


def edges(points):
    return zip(points, points[1:] + points[:1])


def area2(points):
    return sum(x * v - y * u for (x, y), (u, v) in edges(points))


def clip(points, plane):
    """Keep the portion where the affine plane is nonnegative."""
    a, b, c = plane
    result = []
    for start, end in edges(points):
        ds = a * start[0] + b * start[1] + c
        de = a * end[0] + b * end[1] + c
        if ds >= -EPS:
            result.append(start)
        if (ds < -EPS and de > EPS) or (ds > EPS and de < -EPS):
            t = ds / (ds - de)
            result.append(tuple(s + t * (e - s) for s, e in zip(start, end)))
    return result if len(result) >= 3 and abs(area2(result)) > 1 else []


def subtract(left, right):
    return tuple(a - b for a, b in zip(left, right))


def eave_planes(points, overhang):
    """Inward unit distance from each offset eave line."""
    result = []
    for (x, y), (u, v) in edges(points):
        length = hypot(u - x, v - y)
        if length < 1:
            raise ValueError("Cạnh mái quá ngắn.")
        a, b = (y - v) / length, (u - x) / length
        result.append((a, b, overhang - a * x - b * y))
    return result


def planes_on(region, planes):
    faces = []
    for plane in planes:
        face = region
        for other in planes:
            face = clip(face, subtract(other, plane))
        if face:
            faces.append((face, plane))
    return faces


def rectangle(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def hip_wings(points):
    """Split an orthogonal L into two overlapping rectangular wings."""
    xs = sorted(set(x for x, _ in points))
    ys = sorted(set(y for _, y in points))
    if len(points) != 6 or len(xs) != 3 or len(ys) != 3:
        return []
    if any(x != u and y != v for (x, y), (u, v) in edges(points)):
        return []
    x0, xm, x1 = xs
    y0, ym, y1 = ys
    corners = {(x0, y0), (x0, y1), (x1, y0), (x1, y1)}
    missing = corners.difference(tuple(point) for point in points)
    if len(missing) != 1 or not any(x == xm and y == ym for x, y in points):
        return []
    x, y = missing.pop()
    return [
        rectangle(xm if x == x0 else x0, y0, xm if x == x1 else x1, y1),
        rectangle(x0, ym if y == y0 else y0, x1, ym if y == y1 else y1),
    ]


def roof_surfaces(points, elevation, *, pitch=PITCH, overhang=OVERHANG):
    if area2(points) < 0:
        points = points[::-1]
    planes = eave_planes(points, overhang)
    convex = all(a * x + b * y + c >= overhang - EPS
                 for a, b, c in planes for x, y in points)
    walls = [points] if convex else hip_wings(points)
    if not walls:
        return []

    # For an L, take the upper envelope of the two intersecting hip roofs.
    # Each overlap is divided into planar regions at the valley lines.
    roofs = []
    for wall in walls:
        planes = eave_planes(wall, overhang)
        size = max(hypot(x - u, y - v) for x, y in wall for u, v in wall) + 10 * overhang
        x, y = wall[0]
        domain = rectangle(x - size, y - size, x + size, y + size)
        for plane in planes:
            domain = clip(domain, plane)
        if any(abs(u - x) >= size - EPS or abs(v - y) >= size - EPS for u, v in domain):
            return []
        roofs.append(planes_on(domain, planes))

    if len(roofs) == 1:
        patches = roofs[0]
    else:
        expanded = []
        for wall in walls:
            (x0, y0), _, (x1, y1), _ = wall
            expanded.append((x0 - overhang, y0 - overhang, x1 + overhang, y1 + overhang))
        xs = sorted({x for x0, _, x1, _ in expanded for x in (x0, x1)})
        ys = sorted({y for _, y0, _, y1 in expanded for y in (y0, y1)})
        patches = []
        for x0, x1 in zip(xs, xs[1:]):
            for y0, y1 in zip(ys, ys[1:]):
                region = rectangle(x0, y0, x1, y1)
                cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                active = [eave_planes(wall, overhang) for wall, (a, b, c, d) in zip(walls, expanded)
                          if a < cx < c and b < cy < d]
                if len(active) == 1:
                    patches.extend(planes_on(region, active[0]))
                elif len(active) == 2:
                    for face, first in planes_on(region, active[0]):
                        for overlap, second in planes_on(face, active[1]):
                            delta = subtract(first, second)
                            if all(abs(value) < EPS for value in delta):
                                patches.append((overlap, first))
                            else:
                                patches.extend((part, plane) for part, plane in (
                                    (clip(overlap, delta), first),
                                    (clip(overlap, subtract(second, first)), second),
                                ) if part)

    slope = tan(radians(pitch))
    eave = elevation - overhang * slope
    return [[[round(x, 4), round(y, 4), round(eave + (a * x + b * y + c) * slope, 4)]
             for x, y in face] for face, (a, b, c) in patches]

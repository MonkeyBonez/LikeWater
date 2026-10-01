"""Render the engine's own output on a slippy map — PRD build-order step 3.

Reads GeoJSON written by Engine's `lwtool`, so what you see is exactly what the
app computes, not a second implementation that might agree by accident.

    .venv/bin/python check_maps.py ../check ../check/maps
"""
import json, sys
from pathlib import Path
import folium

CORRIDOR_COLORS = [("#1f6fd0", 5, 0.95), ("#4f9ae8", 4, 0.75), ("#6fc3cb", 3, 0.5)]
SUN_COLORS = {2: ("#f5a300", 5, 0.95), 1: ("#d8c37a", 4, 0.85), 0: ("#33475c", 4, 0.9)}


def load(path):
    with open(path) as f:
        return json.load(f)


def corridor_map(doc, title):
    meta = doc["meta"]
    origin, dest = meta["origin"], meta["destination"]
    m = folium.Map(location=[(origin[0] + dest[0]) / 2, (origin[1] + dest[1]) / 2],
                   zoom_start=16, tiles="OpenStreetMap")
    span = max(meta["distance"] * meta["slack"], 1.0)
    for feat in doc["features"]:
        excess = feat["properties"]["excess"]
        band = 0 if excess <= max(2.0, meta["distance"] * 0.004) else (1 if excess <= span * 0.4 else 2)
        color, weight, opacity = CORRIDOR_COLORS[band]
        coords = [[c[1], c[0]] for c in feat["geometry"]["coordinates"]]
        folium.PolyLine(coords, color=color, weight=weight, opacity=opacity,
                        tooltip=f"+{excess:.0f} m").add_to(m)
    for feat in doc["features"]:
        if feat["properties"]["crossing"]:
            c = feat["geometry"]["coordinates"][0]
            folium.CircleMarker([c[1], c[0]], radius=2.5, color="#1a9e4b",
                                fill=True, fill_opacity=0.9, weight=0).add_to(m)
    folium.Marker(origin, tooltip="start", icon=folium.Icon(color="blue")).add_to(m)
    folium.Marker(dest, tooltip="destination", icon=folium.Icon(color="red")).add_to(m)
    folium.map.Marker(
        [origin[0], origin[1]],
        icon=folium.DivIcon(html=(
            f'<div style="font:600 13px -apple-system;background:#fff;padding:6px 9px;'
            f'border-radius:7px;box-shadow:0 1px 6px rgba(0,0,0,.25);white-space:nowrap">'
            f'{title}<br><span style="font-weight:400;color:#556">'
            f'{meta["distance"]:.0f} m · s={meta["slack"]:.0%} · {meta["edges"]} edges · '
            f'{meta["crossings"]} crossings</span></div>'))).add_to(m)
    return m


def sun_map(doc, title):
    meta = doc["meta"]
    m = folium.Map(location=meta["center"], zoom_start=17, tiles="OpenStreetMap")
    for feat in doc["features"]:
        color, weight, opacity = SUN_COLORS[feat["properties"]["bucket"]]
        coords = [[c[1], c[0]] for c in feat["geometry"]["coordinates"]]
        props = feat["properties"]
        kind = "synthesised sidewalk" if props.get("synthetic") and props.get("sidewalk") else (
               "synthesised crossing" if props.get("synthetic") and props.get("crossing") else (
               "synthesised link" if props.get("synthetic") else (
               "OSM sidewalk" if props.get("sidewalk") else ("crossing" if props.get("crossing") else "other"))))
        folium.PolyLine(coords, color=color, weight=weight, opacity=opacity,
                        dash_array="6 4" if props.get("synthetic") else None,
                        tooltip=f"sun {props['sun']:.1f} · {kind}").add_to(m)
    folium.map.Marker(
        meta["center"],
        icon=folium.DivIcon(html=(
            f'<div style="font:600 13px -apple-system;background:#111;color:#fff;'
            f'padding:6px 9px;border-radius:7px;white-space:nowrap">{title}<br>'
            f'<span style="font-weight:400;color:#bbb">az {meta["azimuth"]:.0f}° · '
            f'el {meta["elevation"]:.0f}° · {meta["edges"]} edges · '
            f'{meta["computeMs"]:.1f} ms</span></div>'))).add_to(m)
    return m


def shape_report(doc):
    """Measure what the PRD asks you to eyeball: how wide the corridor is across
    the straight line between the endpoints. A grid corridor fills a rectangle;
    a diagonal like Market St stays a sliver."""
    import math
    meta = doc["meta"]
    o, d = meta["origin"], meta["destination"]
    mid_lat = (o[0] + d[0]) / 2
    mx = 111320 * math.cos(math.radians(mid_lat))
    my = 110540

    ox, oy = o[1] * mx, o[0] * my
    dx, dy = d[1] * mx, d[0] * my
    axis_x, axis_y = dx - ox, dy - oy
    length = math.hypot(axis_x, axis_y) or 1.0
    axis_x, axis_y = axis_x / length, axis_y / length

    along, across = [], []
    for feat in doc["features"]:
        for lon, lat in feat["geometry"]["coordinates"]:
            px, py = lon * mx - ox, lat * my - oy
            along.append(px * axis_x + py * axis_y)
            across.append(px * -axis_y + py * axis_x)
    if not across:
        return {}
    across_span = max(across) - min(across)
    return {
        "straight_m": round(length),
        "walk_m": round(meta["distance"]),
        "detour": round(meta["distance"] / length, 3),
        "width_m": round(across_span),
        "width_over_length": round(across_span / length, 3),
        "edges": meta["edges"],
        "crossings": meta["crossings"],
    }


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "../check")
    dst = Path(sys.argv[2] if len(sys.argv) > 2 else "../check/maps")
    dst.mkdir(parents=True, exist_ok=True)

    titles = {
        "soma1": "SoMa · 3rd & Howard to 2nd & Bryant",
        "soma2": "SoMa · 4th & Mission to Brannan",
        "soma3": "SoMa · 6th & Folsom to 4th & Townsend",
        "market": "Market St · Union Square to Embarcadero",
        "sun10am": "SoMa sun · 10:00 am, 23 Sep",
        "sun4pm": "SoMa sun · 4:00 pm, 23 Sep",
    }
    for path in sorted(src.glob("*.geojson")):
        key = path.stem
        doc = load(path)
        title = titles.get(key, key)
        m = sun_map(doc, title) if "sun" in doc["meta"] or "azimuth" in doc["meta"] else corridor_map(doc, title)
        out = dst / f"{key}.html"
        m.save(str(out))
        if "excess" in (doc["features"][0]["properties"] if doc["features"] else {}):
            print(f"{key:8s} {shape_report(doc)}")
        else:
            print(f"{key:8s} az {doc['meta']['azimuth']:.0f} el {doc['meta']['elevation']:.0f} "
                  f"{doc['meta']['edges']} edges {doc['meta']['computeMs']:.1f} ms -> {out.name}")


if __name__ == "__main__":
    main()

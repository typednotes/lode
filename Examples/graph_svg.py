#!/usr/bin/env python3
"""Render Lun's compiled graph topology and optional runtime outcomes as SVG.

Only Python's standard library is needed; no Graphviz, network assets or scripts
are embedded. Import write_graphs in a client, or pass saved Lun JSON to this CLI.
"""
import argparse
from collections import deque
import json
from pathlib import Path
import re
import textwrap
import unicodedata
import webbrowser
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)
CARD_W, CARD_H, COL_GAP, ROW_GAP, MARGIN = 264, 204, 120, 36, 40


def _element(parent, tag, text=None, **attributes):
    """Let ElementTree escape every label/value, including XML metacharacters."""
    node = ET.SubElement(parent, f"{{{SVG}}}{tag}", {k.replace("_", "-"): str(v) for k, v in attributes.items()})
    if text is not None:
        node.text = str(text)
    return node


def _lines(text, width, limit=None):
    def columns(character):
        return 0 if unicodedata.combining(character) else (2 if unicodedata.east_asian_width(character) in ("W", "F") else 1)

    lines = []
    for part in textwrap.wrap(" ".join(str(text).split()), width=width, break_on_hyphens=False):
        line, used = "", 0
        for character in part:
            size = columns(character)
            if used + size > width:
                lines.append(line.rstrip())
                line, used = "", 0
            line += character
            used += size
        lines.append(line.rstrip())
    lines = lines or [""]
    if limit is not None and len(lines) > limit:
        lines = lines[:limit]
        while sum(columns(character) for character in lines[-1]) >= width:
            lines[-1] = lines[-1][:-1]
        lines[-1] += "…"
    return lines


def _layout(graph):
    """Layer a DAG, keeping long edges in their own intermediate routing lanes."""
    nodes = graph.get("nodes", [])
    if not nodes:
        raise ValueError("The compiled graph has no nodes")
    by_id = {}
    for node in nodes:
        identity = node.get("id")
        if type(identity) is not int or identity < 0 or identity in by_id:
            raise ValueError("Graph node IDs must be distinct nonnegative integers")
        labels = [node.get(field) for field in ("input", "function") if field in node]
        if len(labels) != 1 or not isinstance(labels[0], str) or not labels[0]:
            raise ValueError("Each graph node needs an input or function name")
        by_id[identity] = node
    parents, children = {}, {identity: set() for identity in by_id}
    edges = []
    for identity, node in by_id.items():
        args = node.get("args", [])
        if not isinstance(args, list) or any(type(arg) is not int or arg not in by_id for arg in args):
            raise ValueError("Graph arguments must refer to existing node IDs")
        parents[identity] = set(args)
        for port, arg in enumerate(args, 1):
            children[arg].add(identity)
            edges.append((arg, identity, port))
    remaining = {identity: len(args) for identity, args in parents.items()}
    ready = deque(identity for identity in by_id if not remaining[identity])
    ranks = {identity: 0 for identity in ready}
    visited = []
    while ready:
        identity = ready.popleft()
        visited.append(identity)
        for child in sorted(children[identity]):
            ranks[child] = max(ranks.get(child, 0), ranks[identity] + 1)
            remaining[child] -= 1
            if not remaining[child]:
                ready.append(child)
    if len(visited) != len(nodes):
        raise ValueError("The compiled graph must be acyclic")
    columns = [[] for _ in range(max(ranks.values()) + 1)]
    for identity in visited:
        columns[ranks[identity]].append(identity)
    chains, routing_parents = {}, {}
    for source, target, port in edges:
        chain = [source]
        for rank in range(ranks[source] + 1, ranks[target]):
            lane = (source, target, port, rank)
            columns[rank].append(lane)
            chain.append(lane)
        chain.append(target)
        chains[source, target, port] = chain
        for before, after in zip(chain, chain[1:]):
            routing_parents.setdefault(after, []).append(before)
    # Order each layer by its predecessors to reduce crossings, while keeping
    # equal barycentres stable. IDs need not be contiguous or in list order.
    order = {identity: index for index, identity in enumerate(columns[0])}
    for column in columns[1:]:
        column.sort(key=lambda key: sum(order[p] for p in routing_parents[key]) / len(routing_parents[key]))
        order.update({key: index for index, key in enumerate(column)})
    return by_id, edges, columns, chains


def render_graph(graph, *, build=None, snapshot=None):
    """Draw compiled nodes/argument edges; runtime outcomes only decorate them."""
    by_id, edges, columns, chains = _layout(graph)
    build, snapshot = build or {}, snapshot or {}
    functions = {function["name"]: function for function in build.get("functions", [])}
    outcomes = {node["id"]: node for node in snapshot.get("nodes", [])}
    changed = {node["id"] for node in snapshot.get("changed", [])}
    width = 2 * MARGIN + len(columns) * CARD_W + (len(columns) - 1) * COL_GAP
    name = graph.get("name", "graph")
    title_lines = _lines(name, max(12, int((width - 2 * MARGIN) / 18)))
    header = 114 + 32 * len(title_lines)
    rows = max(map(len, columns))
    body_height = rows * (CARD_H + ROW_GAP) - ROW_GAP
    footer_lines = _lines("Input: gold · function: white · producer: green. Teal border: changed · red: error · amber: skipped.",
                          int((width - 2 * MARGIN) / 8))
    height = header + body_height + 64 + len(footer_lines) * 18
    positions = {}
    for rank, column in enumerate(columns):
        offset = (rows - len(column)) * (CARD_H + ROW_GAP) / 2
        for row, key in enumerate(column):
            positions[key] = (MARGIN + rank * (CARD_W + COL_GAP), header + offset + row * (CARD_H + ROW_GAP))

    root = ET.Element(f"{{{SVG}}}svg", {"viewBox": f"0 0 {width} {height}", "width": str(width),
                       "height": str(height), "role": "img", "aria-labelledby": "title description"})
    _element(root, "title", f"Lun graph: {name}", id="title")
    _element(root, "desc", f"Compiled topology: {len(by_id)} nodes, {len(edges)} ordered argument edges. "
             "Arrows point from an argument to the function using it. Runtime outcomes are shown when available.", id="description")
    _element(root, "rect", x=0, y=0, width=width, height=height, fill="#f4f6f5")
    defs = _element(root, "defs")
    marker = _element(defs, "marker", id="arrow", viewBox="0 0 10 10", refX=10, refY=5,
                      markerWidth=7, markerHeight=7, orient="auto-start-reverse")
    _element(marker, "path", d="M 0 0 L 10 5 L 0 10 z", fill="#687b7b")
    text_style = {"font_family": "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace", "fill": "#183235"}
    _element(root, "text", "LUN / COMPILED GRAPH", x=MARGIN, y=30, font_size=11, **text_style)
    for index, line in enumerate(title_lines):
        _element(root, "text", line, x=MARGIN, y=64 + index * 32, font_size=28, font_weight=700, **text_style)
    subtitle_y = 86 + (len(title_lines) - 1) * 32
    identity = f"{len(by_id)} nodes · {len(edges)} argument edges"
    if build.get("id"):
        identity += " · build " + build["id"][:12]
    if (build.get("source") or {}).get("commit"):
        identity += " · commit " + build["source"]["commit"][:12]
    for index, line in enumerate(_lines(identity, int((width - 2 * MARGIN) / 8))):
        _element(root, "text", line, x=MARGIN, y=subtitle_y + index * 16, font_size=12, **text_style)

    for source, target, port in edges:
        points = []
        chain = chains[source, target, port]
        for index, key in enumerate(chain):
            x, y = positions[key]
            x += CARD_W if index == 0 else (0 if index == len(chain) - 1 else CARD_W / 2)
            y += CARD_H / 2
            if index == len(chain) - 1:
                y += (port - (len(by_id[target].get("args", [])) + 1) / 2) * min(24, CARD_H / (len(by_id[target]["args"]) + 1))
            points.append((x, y))
        path = f"M {points[0][0]} {points[0][1]}"
        for (x1, y1), (x2, y2) in zip(points, points[1:]):
            middle = (x1 + x2) / 2
            path += f" C {middle} {y1}, {middle} {y2}, {x2} {y2}"
        edge = _element(root, "path", d=path, fill="none", stroke="#687b7b", stroke_width=1.8,
                        marker_end="url(#arrow)", data_source=source, data_target=target, data_arg=port)
        _element(edge, "title", f"Node {source} → node {target}, argument {port}")
        x, y = points[-1]
        _element(root, "text", str(port), x=x - 18, y=y - 7, font_size=11, text_anchor="middle", **text_style)

    sources = set(graph.get("sources", [identity for identity, node in by_id.items() if not node.get("args")]))
    sinks = set(graph.get("sinks", set(by_id) - {source for source, _, _ in edges}))
    for identity, node in by_id.items():
        x, y = positions[identity]
        function = functions.get(node.get("function"), {})
        kind = "input" if "input" in node else ("producer" if function.get("producer") else "function")
        label = node.get("input", node.get("function"))
        outcome = outcomes.get(identity, {})
        state = "error" if "error" in outcome else ("skipped" if "skipped" in outcome else "ok")
        border = {"error": "#bd473e", "skipped": "#a66b19"}.get(state, "#168777" if identity in changed else "#c5d1cd")
        group = _element(root, "g", id=f"node-{identity}", data_node_id=identity, data_kind=kind,
                         data_status=state, data_changed=str(identity in changed).lower())
        detail = function.get("signature", "External input" if kind == "input" else f"{len(node.get('args', []))} arguments")
        value = "Not run yet"
        if "error" in outcome:
            value = "Error: " + str(outcome["error"])
        elif "skipped" in outcome:
            value = f"Skipped: dependency #{outcome['skipped']}"
        elif "output" in outcome:
            value = "Value: " + json.dumps(outcome["output"], ensure_ascii=False)
        _element(group, "title", f"{kind} #{identity}: {label}\n{detail}\n{value}")
        _element(group, "rect", x=x, y=y, width=CARD_W, height=CARD_H, rx=12,
                 fill={"input": "#fff8e7", "function": "#ffffff", "producer": "#e9f4ee"}[kind],
                 stroke=border, stroke_width=2.5 if identity in changed or state != "ok" else 1)
        _element(group, "text", f"{kind.upper()} · #{identity}", x=x + 16, y=y + 25, font_size=11, **text_style)
        badge = "SINK" if identity in sinks else ("SOURCE" if identity in sources else "")
        if badge:
            _element(group, "text", badge, x=x + CARD_W - 16, y=y + 25, font_size=10, text_anchor="end", **text_style)
        for index, line in enumerate(_lines(label, 24, 2)):
            _element(group, "text", line, x=x + 16, y=y + 56 + index * 20, font_size=16, font_weight=700, **text_style)
        for index, line in enumerate(_lines(detail, 30, 2)):
            _element(group, "text", line, x=x + 16, y=y + 104 + index * 16, font_size=12, **text_style)
        _element(group, "line", x1=x + 16, x2=x + CARD_W - 16, y1=y + 136, y2=y + 136, stroke="#dce4df")
        for index, line in enumerate(_lines(value, 30, 3)):
            _element(group, "text", line, x=x + 16, y=y + 156 + index * 16, font_size=12,
                     **{**text_style, "fill": border if state != "ok" else "#183235"})

    for index, line in enumerate(footer_lines):
        _element(root, "text", line, x=MARGIN, y=header + body_height + 32 + index * 18, font_size=12, **text_style)
    return ET.tostring(root, encoding="unicode", xml_declaration=True) + "\n"


def write_graphs(build, directory, *, snapshots=None, name=None):
    """Export all or one compiled graph, using filenames confined to directory."""
    graphs = build.get("graphs") or []
    selected = [(index, graph) for index, graph in enumerate(graphs) if name is None or graph["name"] == name]
    if not selected:
        raise ValueError("No matching compiled graph. Available: " + (", ".join(g["name"] for g in graphs) or "none"))
    rendered = [(index, graph, render_graph(graph, build=build, snapshot=(snapshots or {}).get(graph["name"])))
                for index, graph in selected]
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for index, graph, svg in rendered:
        slug = re.sub(r"[^A-Za-z0-9_.-]", "_", graph["name"])[:80] or "graph"
        path = directory / f"graph-{index:02d}-{slug}.svg"
        path.write_text(svg, encoding="utf-8")
        paths.append(path)
    return paths


def open_svg(path):
    """Best-effort default-browser launch; callers can always use the file URI."""
    try:
        return webbrowser.open(Path(path).resolve().as_uri(), new=2)
    except (webbrowser.Error, OSError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="saved GET /v0/builds/ID JSON (raw body or client envelope)")
    parser.add_argument("--output", type=Path, default=Path("graph-svg"), help="SVG output directory")
    parser.add_argument("--graph", help="export one graph instead of all graphs")
    parser.add_argument("--snapshot", type=Path, help="saved graph-step JSON for values/errors")
    parser.add_argument("--open", action="store_true", help="open exported SVGs in the default browser")
    args = parser.parse_args()

    def load(path):
        data = json.loads(path.read_text(encoding="utf-8"))
        return data["body"] if "status" in data and "body" in data else data

    build = load(args.build)
    snapshots = None
    if args.snapshot:
        snapshot = load(args.snapshot)
        name = snapshot["state"]["graphName"]
        if snapshot["state"]["build"] != build["id"]:
            parser.error("the runtime snapshot belongs to a different build")
        snapshots = {name: snapshot}
    for path in write_graphs(build, args.output, snapshots=snapshots, name=args.graph):
        print(path.as_uri())
        if args.open and not open_svg(path):
            print("Could not open the browser; open the printed file URI manually.")


if __name__ == "__main__":
    main()

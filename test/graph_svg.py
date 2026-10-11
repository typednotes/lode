#!/usr/bin/env python3
"""Graph rendering regressions: ordered topology, outcomes and safe SVG text."""
import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unicodedata
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from Examples.graph_svg import open_svg, render_graph, write_graphs  # noqa: E402

NS = {"s": "http://www.w3.org/2000/svg"}
GRAPH = {"name": "basket", "nodes": [
    {"id": 0, "input": "value"}, {"id": 1, "function": "double", "args": [0]},
    {"id": 2, "function": "seed", "args": []}, {"id": 3, "function": "add", "args": [1, 2]},
], "sources": [0, 2], "sinks": [3]}
BUILD = {"id": "a" * 64, "source": {"commit": "b" * 40}, "graphs": [GRAPH],
         "functions": [{"name": "double", "signature": "Nat → Eff [] Nat", "producer": False}]}


def element(root, selector):
    found = root.find(selector, NS)
    assert found is not None, selector
    return found


class GraphSvgTest(unittest.TestCase):
    def test_compiled_edges_preserve_argument_order_and_noncontiguous_ids(self):
        graph = {"name": "shared", "nodes": [
            {"id": 90, "function": "add", "args": [42, 42]},
            {"id": 42, "input": "x"}, {"id": 8, "function": "constant", "args": []},
        ]}
        root = ET.fromstring(render_graph(graph))
        edges = root.findall("s:path[@data-source]", NS)
        self.assertEqual([(edge.get("data-source"), edge.get("data-target"), edge.get("data-arg"))
                          for edge in edges], [("42", "90", "1"), ("42", "90", "2")])
        groups = {int(group.attrib["data-node-id"]): group for group in root.findall("s:g", NS)}
        source = element(groups[42], "s:rect")
        target = element(groups[90], "s:rect")
        self.assertLess(float(source.attrib["x"]), float(target.attrib["x"]))
        self.assertEqual(len(groups), 3)  # The disconnected source is not lost.

    def test_labels_and_runtime_errors_are_escaped_and_visible(self):
        graph = copy.deepcopy(GRAPH)
        graph["name"] = '<script>alert("graph")</script> & λ'
        graph["nodes"][0]["input"] = '<image href="evil"> & input'
        snapshot = {"nodes": [{"id": 1, "error": '<script>alert("output")</script> & failure'},
                              {"id": 3, "skipped": 1}], "changed": [{"id": 1}]}
        root = ET.fromstring(render_graph(graph, build=BUILD, snapshot=snapshot))
        self.assertEqual(element(root, "s:title").text, "Lun graph: " + graph["name"])
        self.assertFalse(root.findall(".//s:script", NS))
        self.assertFalse(root.findall(".//s:image", NS))
        failed = element(root, "s:g[@data-node-id='1']")
        self.assertEqual(failed.get("data-status"), "error")
        self.assertEqual(failed.get("data-changed"), "true")
        self.assertIn(snapshot["nodes"][0]["error"], element(failed, "s:title").text or "")
        self.assertEqual(element(root, "s:g[@data-node-id='3']").get("data-status"), "skipped")

    def test_producer_metadata_and_long_values_are_kept_in_tooltips(self):
        build = copy.deepcopy(BUILD)
        build["functions"][0]["producer"] = True
        value = "W" * 600
        root = ET.fromstring(render_graph(GRAPH, build=build, snapshot={"nodes": [{"id": 1, "output": value}]}))
        producer = element(root, "s:g[@data-node-id='1']")
        self.assertEqual(producer.get("data-kind"), "producer")
        self.assertIn(value, element(producer, "s:title").text or "")
        self.assertTrue(any("…" in (text.text or "") for text in producer.findall("s:text", NS)))

    def test_refuses_ambiguous_or_impossible_topology(self):
        for nodes in ([], [{"id": 1, "input": "x"}, {"id": 1, "input": "y"}],
                      [{"id": 1, "function": "f", "args": [99]}],
                      [{"id": 1, "function": "f", "args": [2]}, {"id": 2, "function": "g", "args": [1]}]):
            with self.subTest(nodes=nodes), self.assertRaises(ValueError):
                render_graph({"nodes": nodes})

    def test_wide_unicode_values_fit_the_card_text_columns(self):
        value = "世界🌍" * 40
        root = ET.fromstring(render_graph(GRAPH, snapshot={"nodes": [{"id": 1, "output": value}]}))
        group = element(root, "s:g[@data-node-id='1']")
        self.assertIn(value, element(group, "s:title").text or "")
        for text in group.findall("s:text[@font-size='12']", NS):
            columns = sum(2 if unicodedata.east_asian_width(char) in ("W", "F") else 1 for char in text.text or "")
            self.assertLessEqual(columns, 30)

    def test_export_stays_in_directory_and_handles_colliding_names(self):
        graphs = [copy.deepcopy(GRAPH), copy.deepcopy(GRAPH)]
        graphs[0]["name"], graphs[1]["name"] = "../../a/b", ".._.._a_b"
        with tempfile.TemporaryDirectory() as scratch:
            paths = write_graphs({**BUILD, "graphs": graphs}, scratch)
            self.assertEqual(len(set(paths)), 2)
            for path in paths:
                self.assertEqual(path.parent, Path(scratch).resolve())
                ET.parse(path)
            selected = write_graphs({**BUILD, "graphs": graphs}, scratch, name=graphs[1]["name"])
            self.assertEqual(selected, [paths[1]])
            with self.assertRaises(ValueError):
                write_graphs(BUILD, scratch, name="missing")

    def test_browser_uses_file_uri_and_reports_unavailable_browser(self):
        with patch("Examples.graph_svg.webbrowser.open", return_value=True) as browser:
            self.assertTrue(open_svg(ROOT / "a graph.svg"))
            browser.assert_called_once_with((ROOT / "a graph.svg").as_uri(), new=2)
        with patch("Examples.graph_svg.webbrowser.open", side_effect=OSError("no browser")):
            self.assertFalse(open_svg(ROOT / "a graph.svg"))

    def test_cli_reads_client_envelopes_and_refuses_a_snapshot_from_another_build(self):
        snapshot = {"state": {"graphName": "basket", "build": BUILD["id"]},
                    "nodes": [{"id": 3, "output": 123}]}
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            build_json, step_json = work / "build.json", work / "step.json"
            build_json.write_text(json.dumps({"status": 200, "body": BUILD}), encoding="utf-8")
            step_json.write_text(json.dumps({"status": 200, "body": snapshot}), encoding="utf-8")
            args = [sys.executable, str(ROOT / "Examples/graph_svg.py"), str(build_json),
                    "--snapshot", str(step_json), "--output", str(work / "svg")]
            reply = subprocess.run(args, capture_output=True, text=True, check=True)
            path = work / "svg/graph-00-basket.svg"
            self.assertIn(path.resolve().as_uri(), reply.stdout)
            root = ET.parse(path).getroot()
            self.assertIn("Value: 123", [text.text for text in root.findall(".//s:text", NS)])
            snapshot["state"]["build"] = "c" * 64
            step_json.write_text(json.dumps(snapshot), encoding="utf-8")
            refused = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("different build", refused.stderr)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Attribute each traced frame's wall time to the enhancement stages.

Usage: attribute-frame-trace.py RUN.trace

RUN.trace is a Metal System Trace with os_signpost, attached to hdr-benchmark
after its warm-up frames:
  xcrun xctrace record --template "Metal System Trace" --instrument os_signpost \\
    --attach PID --time-limit 8s --output RUN.trace
A frame runs from the previous frame's end to its own end. Each stage also
reports this process's GPU busy time and other processes' GPU time inside it.
"""
import os
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

STAGES = ["import", "proxy", "identity", "motion", "inference graph", "inference eval", "resolve", "pack"]
ENV = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))


def rows(trace, schema):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    output = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                            check=True, capture_output=True, env=ENV).stdout
    node = ET.fromstring(output).find("node")
    if node is None:
        return []
    columns = [c.findtext("mnemonic") for c in node.find("schema").findall("col")]
    ids = {}

    def resolve(element):
        if element.get("ref") is not None:
            return ids[element.get("ref")]
        if element.get("id") is not None:
            ids[element.get("id")] = element
        for child in element:
            resolve(child)
        return element

    return [{column: resolve(element) for column, element in zip(columns, row)} for row in node.findall("row")]


def interval(row):
    start = int(row["start"].text)
    return start, start + int(row["duration"].text)


def union(intervals):
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def overlap(merged, start, end):
    return sum(max(0, min(e, end) - max(s, start)) for s, e in merged)


def main():
    trace = sys.argv[1]
    signposts = {}
    for row in rows(trace, "OSSignpostIntervals"):
        if row["subsystem"].get("fmt") == "com.scripttype.mlxdlss" and row["duration"].text:
            signposts.setdefault(row["name"].get("fmt"), []).append(interval(row))
    own, other = [], []
    for row in rows(trace, "metal-gpu-intervals"):
        (own if "hdr-benchmark" in (row["process"].get("fmt") or "") else other).append(interval(row))
    own, other = union(own), union(other)
    frames = sorted(signposts["frame"])
    records = []
    for (_, previous_end), (start, end) in zip(frames, frames[1:]):
        inside = {name: [(s, e) for s, e in signposts.get(name, []) if s >= start and e <= end] for name in STAGES}
        if any(len(found) != 1 for found in inside.values()):
            continue
        stages = {"hand-off between frames": (previous_end, start)} | {name: found[0] for name, found in inside.items()}
        record = {name: (e - s, overlap(own, s, e), overlap(other, s, e)) for name, (s, e) in stages.items()}
        wall = end - previous_end
        record["unlabelled actor hops"] = (wall - sum(duration for duration, _, _ in record.values()), 0, 0)
        records.append((wall, record))
    walls = sorted(wall for wall, _ in records)
    wall, median = min(records, key=lambda item: abs(item[0] - walls[len(walls) // 2]))
    print(f"{trace}: {len(records)} frames, wall p50 {statistics.median(walls) / 1e6:.2f} ms")
    print(f"{'stage':26} {'median frame':>12} {'share':>6} {'own GPU':>8} {'other GPU':>9}")
    for name, (duration, gpu, foreign) in median.items():
        print(f"{name:26} {duration / 1e6:12.2f} {duration / wall * 100:5.1f}% {gpu / 1e6:8.2f} {foreign / 1e6:9.2f}")
    named = wall - median["unlabelled actor hops"][0]
    print(f"named stages cover {named / wall * 100:.1f}% of the median frame ({wall / 1e6:.2f} ms)")
    states = {}
    for row in rows(trace, "gpu-performance-state-intervals"):
        s, e = interval(row)
        name = row["gpu-performance-state"].get("fmt")
        states[name] = states.get(name, 0) + max(0, min(e, frames[-1][1]) - max(s, frames[0][1]))
    total = sum(states.values()) or 1
    print("GPU performance state: " + ", ".join(f"{k} {v / total * 100:.0f}%" for k, v in sorted(states.items())))


if __name__ == "__main__":
    main()

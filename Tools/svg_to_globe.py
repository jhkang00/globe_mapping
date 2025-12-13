#!/usr/bin/env python3
"""
SVG to Globe Format Converter v2.0

Converts Mercator-projected SVG world maps to .globe format.
Preserves cubic Bézier curves for smooth rendering.

Usage:
    python svg_to_globe.py --inner InnerWorld.svg --outer OuterWorld.svg -o world.globe
"""

import re
import json
import math
import argparse
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Tuple, Dict, Any, Optional
import xml.etree.ElementTree as ET
from uuid import uuid4

# Coordinate system constants
SVG_WIDTH = 4170.0
SVG_HEIGHT = 1668.0
LON_RANGE = 180.0
LAT_RANGE = 72.0
INNER_SHIFT = -69.5
OUTER_SHIFT = 2015.5


def parse_svg_file(filepath: str) -> List[str]:
    """Parse SVG file and extract path d attributes."""
    if not Path(filepath).exists():
        print(f"  Warning: File not found: {filepath}")
        return []
    
    try:
        tree = ET.parse(filepath)
        root = tree.getroot()
        
        namespaces = {'svg': 'http://www.w3.org/2000/svg'}
        paths = []
        
        for path in root.findall('.//svg:path', namespaces):
            d = path.get('d')
            if d:
                paths.append(d)
        
        if not paths:
            for path in root.iter():
                if path.tag.endswith('path') or path.tag == 'path':
                    d = path.get('d')
                    if d:
                        paths.append(d)
        
        return paths
    except ET.ParseError as e:
        print(f"  Error parsing {filepath}: {e}")
        return []


def parse_path_commands(d: str) -> List[Tuple[str, List[float]]]:
    """Parse SVG path d attribute into commands."""
    commands = []
    pattern = r'([MCmcLlHhVvZzSsQqTtAa])([^MCmcLlHhVvZzSsQqTtAa]*)'
    
    for match in re.finditer(pattern, d):
        cmd = match.group(1)
        coords_str = match.group(2).strip()
        
        if coords_str:
            numbers = re.findall(r'-?\d+\.?\d*', coords_str)
            coords = [float(n) for n in numbers]
        else:
            coords = []
        
        commands.append((cmd, coords))
    
    return commands


def svg_to_geographic(x: float, y: float) -> Tuple[float, float]:
    """Convert unified SVG coordinates to geographic [lat, lon]."""
    lon = (x - SVG_WIDTH / 2) * (LON_RANGE / (SVG_WIDTH / 2))
    lat = -(y - SVG_HEIGHT / 2) * (LAT_RANGE / (SVG_HEIGHT / 2))
    lat = max(-LAT_RANGE, min(LAT_RANGE, lat))
    return (round(lat, 4), round(lon, 4))


def point_to_coord(x: float, y: float, shift: float) -> List[float]:
    """Convert SVG point to [lat, lon] compact coordinate."""
    lat, lon = svg_to_geographic(x + shift, y)
    return [lat, lon]


class PathSegment:
    """Represents a continuous path segment."""
    def __init__(self):
        self.cubic_segments: List[List[List[float]]] = []
        self.is_closed: bool = False
        self.start_point: Optional[List[float]] = None
        self.current_point: Optional[List[float]] = None


def extract_path_segments(path_data: str, shift: float) -> List[Dict[str, Any]]:
    """Extract path segments preserving Bézier curves."""
    commands = parse_path_commands(path_data)
    segments: List[PathSegment] = []
    current_segment: Optional[PathSegment] = None
    current_pos = (0.0, 0.0)
    
    for cmd, coords in commands:
        if cmd == 'M':
            if len(coords) >= 2:
                if current_segment and len(current_segment.cubic_segments) > 0:
                    segments.append(current_segment)
                
                current_segment = PathSegment()
                current_pos = (coords[0], coords[1])
                current_segment.start_point = point_to_coord(current_pos[0], current_pos[1], shift)
                current_segment.current_point = current_segment.start_point
                
                # Additional coordinate pairs are implicit line-to
                for i in range(2, len(coords) - 1, 2):
                    prev_pos = current_pos
                    current_pos = (coords[i], coords[i + 1])
                    p0 = point_to_coord(prev_pos[0], prev_pos[1], shift)
                    p3 = point_to_coord(current_pos[0], current_pos[1], shift)
                    p1 = [p0[0] + (p3[0] - p0[0]) / 3, p0[1] + (p3[1] - p0[1]) / 3]
                    p2 = [p0[0] + (p3[0] - p0[0]) * 2 / 3, p0[1] + (p3[1] - p0[1]) * 2 / 3]
                    current_segment.cubic_segments.append([p0, p1, p2, p3])
                    current_segment.current_point = p3
                    
        elif cmd == 'm':
            if len(coords) >= 2:
                if current_segment and len(current_segment.cubic_segments) > 0:
                    segments.append(current_segment)
                
                current_segment = PathSegment()
                current_pos = (current_pos[0] + coords[0], current_pos[1] + coords[1])
                current_segment.start_point = point_to_coord(current_pos[0], current_pos[1], shift)
                current_segment.current_point = current_segment.start_point
                
        elif cmd == 'C':
            if current_segment is None:
                current_segment = PathSegment()
                current_segment.start_point = point_to_coord(current_pos[0], current_pos[1], shift)
                current_segment.current_point = current_segment.start_point
            
            for i in range(0, len(coords) - 5, 6):
                p0 = point_to_coord(current_pos[0], current_pos[1], shift)
                p1 = point_to_coord(coords[i], coords[i + 1], shift)
                p2 = point_to_coord(coords[i + 2], coords[i + 3], shift)
                p3 = point_to_coord(coords[i + 4], coords[i + 5], shift)
                
                current_segment.cubic_segments.append([p0, p1, p2, p3])
                current_pos = (coords[i + 4], coords[i + 5])
                current_segment.current_point = p3
                
        elif cmd == 'c':
            if current_segment is None:
                current_segment = PathSegment()
                current_segment.start_point = point_to_coord(current_pos[0], current_pos[1], shift)
                current_segment.current_point = current_segment.start_point
            
            for i in range(0, len(coords) - 5, 6):
                p0 = point_to_coord(current_pos[0], current_pos[1], shift)
                p1 = point_to_coord(current_pos[0] + coords[i], current_pos[1] + coords[i + 1], shift)
                p2 = point_to_coord(current_pos[0] + coords[i + 2], current_pos[1] + coords[i + 3], shift)
                p3 = point_to_coord(current_pos[0] + coords[i + 4], current_pos[1] + coords[i + 5], shift)
                
                current_segment.cubic_segments.append([p0, p1, p2, p3])
                current_pos = (current_pos[0] + coords[i + 4], current_pos[1] + coords[i + 5])
                current_segment.current_point = p3
                
        elif cmd == 'L':
            if current_segment is None:
                current_segment = PathSegment()
                current_segment.start_point = point_to_coord(current_pos[0], current_pos[1], shift)
                current_segment.current_point = current_segment.start_point
            
            for i in range(0, len(coords) - 1, 2):
                p0 = point_to_coord(current_pos[0], current_pos[1], shift)
                current_pos = (coords[i], coords[i + 1])
                p3 = point_to_coord(current_pos[0], current_pos[1], shift)
                p1 = [p0[0] + (p3[0] - p0[0]) / 3, p0[1] + (p3[1] - p0[1]) / 3]
                p2 = [p0[0] + (p3[0] - p0[0]) * 2 / 3, p0[1] + (p3[1] - p0[1]) * 2 / 3]
                current_segment.cubic_segments.append([p0, p1, p2, p3])
                current_segment.current_point = p3
                
        elif cmd == 'l':
            if current_segment is None:
                current_segment = PathSegment()
                current_segment.start_point = point_to_coord(current_pos[0], current_pos[1], shift)
                current_segment.current_point = current_segment.start_point
            
            for i in range(0, len(coords) - 1, 2):
                p0 = point_to_coord(current_pos[0], current_pos[1], shift)
                current_pos = (current_pos[0] + coords[i], current_pos[1] + coords[i + 1])
                p3 = point_to_coord(current_pos[0], current_pos[1], shift)
                p1 = [p0[0] + (p3[0] - p0[0]) / 3, p0[1] + (p3[1] - p0[1]) / 3]
                p2 = [p0[0] + (p3[0] - p0[0]) * 2 / 3, p0[1] + (p3[1] - p0[1]) * 2 / 3]
                current_segment.cubic_segments.append([p0, p1, p2, p3])
                current_segment.current_point = p3
                
        elif cmd in ('Z', 'z'):
            if current_segment and current_segment.start_point and current_segment.current_point:
                start = current_segment.start_point
                end = current_segment.current_point
                dist = math.sqrt((start[0] - end[0])**2 + (start[1] - end[1])**2)
                if dist > 0.01:
                    p0 = end
                    p3 = start
                    p1 = [p0[0] + (p3[0] - p0[0]) / 3, p0[1] + (p3[1] - p0[1]) / 3]
                    p2 = [p0[0] + (p3[0] - p0[0]) * 2 / 3, p0[1] + (p3[1] - p0[1]) * 2 / 3]
                    current_segment.cubic_segments.append([p0, p1, p2, p3])
                current_segment.is_closed = True
    
    if current_segment and len(current_segment.cubic_segments) > 0:
        segments.append(current_segment)
    
    # Convert to output format
    result = []
    for seg in segments:
        if len(seg.cubic_segments) > 0:
            path_dict = {
                "id": str(uuid4()),
                "pathType": "cubic",
                "cubicSegments": seg.cubic_segments,
                "isClosed": seg.is_closed,
                "style": {
                    "strokeColor": {"r": 0.9, "g": 0.9, "b": 0.9, "a": 1.0},
                    "strokeWidth": 1.5
                }
            }
            result.append(path_dict)
    
    return result


def process_svg_to_paths(svg_paths: List[str], shift: float) -> List[Dict[str, Any]]:
    """Process SVG paths to globe format paths."""
    result_paths = []
    
    for path_data in svg_paths:
        paths = extract_path_segments(path_data, shift)
        result_paths.extend(paths)
    
    return result_paths


def create_globe_document(inner_svg: str = None, outer_svg: str = None, name: str = "Converted World") -> Dict[str, Any]:
    """Create a .globe document from SVG files."""
    all_paths = []
    total_curves = 0
    
    if inner_svg:
        print(f"Processing {inner_svg}...")
        inner_paths = parse_svg_file(inner_svg)
        print(f"  Found {len(inner_paths)} SVG paths")
        converted = process_svg_to_paths(inner_paths, INNER_SHIFT)
        curves = sum(len(p.get("cubicSegments", [])) for p in converted)
        print(f"  Converted to {len(converted)} segments with {curves} Bézier curves")
        all_paths.extend(converted)
        total_curves += curves
    
    if outer_svg:
        print(f"Processing {outer_svg}...")
        outer_paths = parse_svg_file(outer_svg)
        print(f"  Found {len(outer_paths)} SVG paths")
        converted = process_svg_to_paths(outer_paths, OUTER_SHIFT)
        curves = sum(len(p.get("cubicSegments", [])) for p in converted)
        print(f"  Converted to {len(converted)} segments with {curves} Bézier curves")
        all_paths.extend(converted)
        total_curves += curves
    
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    
    document = {
        "formatVersion": "2.0",
        "meta": {
            "name": name,
            "created": now,
            "modified": now
        },
        "layers": [
            {
                "id": str(uuid4()),
                "name": "Coastlines",
                "isVisible": True,
                "isLocked": False,
                "paths": all_paths
            }
        ]
    }
    
    print(f"\nTotal: {len(all_paths)} paths, {total_curves} Bézier curves")
    
    return document


def main():
    parser = argparse.ArgumentParser(
        description="Convert Mercator SVG to .globe format (preserves Bézier curves)"
    )
    parser.add_argument("svg_files", nargs="*", help="SVG files to convert")
    parser.add_argument("-o", "--output", default="world.globe", help="Output .globe file")
    parser.add_argument("-n", "--name", default="Converted World", help="World name")
    parser.add_argument("--inner", help="InnerWorld SVG (eastern hemisphere)")
    parser.add_argument("--outer", help="OuterWorld SVG (western hemisphere)")
    
    args = parser.parse_args()
    
    inner_svg = args.inner
    outer_svg = args.outer
    
    for f in args.svg_files:
        if "inner" in f.lower():
            inner_svg = f
        elif "outer" in f.lower():
            outer_svg = f
        elif not inner_svg:
            inner_svg = f
        elif not outer_svg:
            outer_svg = f
    
    if not inner_svg and not outer_svg:
        print("No SVG files specified. Use --inner and/or --outer, or provide file paths.")
        return
    
    document = create_globe_document(inner_svg, outer_svg, args.name)
    
    output_path = Path(args.output)
    with open(output_path, 'w') as f:
        json.dump(document, f, separators=(',', ':'))
    
    file_size = output_path.stat().st_size
    if file_size > 1024 * 1024:
        size_str = f"{file_size / 1024 / 1024:.2f} MB"
    elif file_size > 1024:
        size_str = f"{file_size / 1024:.1f} KB"
    else:
        size_str = f"{file_size} bytes"
    
    print(f"\nCreated {output_path} ({size_str})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
TGML to SVG Converter — proof-of-concept.
Parses EcoStruxure BMS TGML graphics and produces static SVG output.

Usage:
    python tgml-to-svg.py path/to/file.tgml [output.svg]
    python tgml-to-svg.py folder/    (batch convert all .tgml files)
"""

import xml.etree.ElementTree as ET
import re, os, sys, textwrap, html
from pathlib import Path

GRADIENT_COUNTER = [0]  # mutable counter for unique gradient IDs
SKIPPED_ELEMENTS = {'Script', 'Bind', 'Expose', 'Animate', 'ConvertRange', 'ConvertValue',
                    'SignalChange', 'Animation'}

# Template components that are cloned at runtime — skip at their file positions
TEMPLATE_COMPONENT_IDS = {'AlarmGroup', 'ForceGroup', 'DatabaseGroup', 'NetworkGroup', 'BACOvrGroup',
                          'GlobScrTemp'}

def _next_grad_id():
    GRADIENT_COUNTER[0] += 1
    return f'grad_{GRADIENT_COUNTER[0]}'

def _parse_point(s):
    """Parse a 'x,y' string into (x, y) floats."""
    parts = s.strip().split(',')
    return float(parts[0]), float(parts[1])

def _collect_gradients(el, grad_map):
    """First pass: collect all gradient definitions into grad_map."""
    tag = el.tag
    if tag in ('LinearGradient', 'RadialGradient'):
        gid = _next_grad_id()
        grad_map[id(el)] = gid
    for child in el:
        _collect_gradients(child, grad_map)

def _make_gradient_def(el, gid):
    """Return SVG <linearGradient> or <radialGradient> def string."""
    tag = el.tag
    stops = []
    for child in el:
        if child.tag == 'GradientStop':
            color = child.get('Color', '#000000')
            if color == 'None' or not color:
                color = '#000000'
            offset = child.get('Offset', '0')
            stops.append(f'<stop offset="{offset}" stop-color="{color}"/>')

    if tag == 'LinearGradient':
        sp = _parse_point(el.get('StartPoint', '0,0'))
        ep = _parse_point(el.get('EndPoint', '1,0'))
        return (f'<linearGradient id="{gid}" x1="{sp[0]}" y1="{sp[1]}" '
                f'x2="{ep[0]}" y2="{ep[1]}">{chr(10).join(stops)}</linearGradient>')
    else:
        # RadialGradient
        cx = el.get('Center', '0.5,0.5')
        cx_p = _parse_point(cx)
        return (f'<radialGradient id="{gid}" cx="{cx_p[0]}" cy="{cx_p[1]}" '
                f'r="0.5">{chr(10).join(stops)}</radialGradient>')

def _get_fill_or_grad(el, attr, grad_map):
    """Get fill/stroke value, resolving gradients."""
    for child in el:
        if child.tag in ('LinearGradient', 'RadialGradient') and child.get('Attribute', '') == attr:
            gid = grad_map.get(id(child))
            if gid:
                return f'url(#{gid})'
    val = el.get(attr, 'None')
    if val == 'None' or not val:
        return 'none'
    return val

def _visibility_visible(el):
    """Check if element is visible (not hidden)."""
    vis = el.get('Visibility', 'Visible')
    return vis != 'Hidden'

def _points_to_path(points_str):
    """Convert TGML Curve points (x1,y1 x2,y2 ...) to SVG path d attribute."""
    coords = points_str.strip().split()
    if not coords:
        return ''
    parts = ['M']
    for i, c in enumerate(coords):
        xy = c.split(',')
        if len(xy) != 2:
            continue
        parts.append(xy[0])
        parts.append(xy[1])
        if i > 0:
            parts.append('L')
    if parts and parts[-1] == 'L':
        parts = parts[:-1]
    return ' '.join(parts)

def _opacity(el):
    """Get opacity value (default 1.0)."""
    return el.get('Opacity', '1.0')

def _common_attrs(el, grad_map, force_fill_none=False):
    """Return common SVG attributes string. If force_fill_none, always set fill='none'."""
    parts = []
    op = _opacity(el)
    if op != '1.0':
        parts.append(f'opacity="{op}"')
    if force_fill_none:
        parts.append('fill="none"')
    else:
        fill = _get_fill_or_grad(el, 'Fill', grad_map)
        parts.append(f'fill="{fill}"' if fill != 'none' else 'fill="none"')
    stroke = _get_fill_or_grad(el, 'Stroke', grad_map)
    sw = el.get('StrokeWidth')
    if stroke != 'none':
        parts.append(f'stroke="{stroke}"')
    if sw and sw != '0':
        parts.append(f'stroke-width="{sw}"')
    sda = el.get('StrokeDashArray', '0.0')
    if sda and sda != '0.0':
        parts.append(f'stroke-dasharray="{sda}"')
    return ' '.join(parts)

def _get_rotate_center(el, rotate_el):
    """Calculate absolute rotation center from TGML relative coordinates.
    Center="0.5,0.5" means 50% of parent element's width/height."""
    center = rotate_el.get('Center')
    if not center:
        return None

    c_parts = center.split(',')
    cx_rel = float(c_parts[0].strip())
    cy_rel = float(c_parts[1].strip())

    # Calculate absolute center based on element type and its coordinates
    tag = el.tag
    if tag == 'Line':
        x1 = float(el.get('X1', 0))
        y1 = float(el.get('Y1', 0))
        x2 = float(el.get('X2', 0))
        y2 = float(el.get('Y2', 0))
        return (x1 + (x2 - x1) * cx_rel, y1 + (y2 - y1) * cy_rel)
    elif tag in ('Rectangle', 'Image', 'TextBox'):
        left = float(el.get('Left', 0))
        top = float(el.get('Top', 0))
        w = float(el.get('Width', 100))
        h = float(el.get('Height', 100))
        return (left + w * cx_rel, top + h * cy_rel)
    elif tag == 'Ellipse':
        cx = float(el.get('Left', 0))
        cy = float(el.get('Top', 0))
        w = float(el.get('Width', 10))
        h = float(el.get('Height', 10))
        # Ellipse Left/Top is center, so bounding box is (cx-w/2, cy-h/2) to (cx+w/2, cy+h/2)
        bb_left = cx - w / 2
        bb_top = cy - h / 2
        return (bb_left + w * cx_rel, bb_top + h * cy_rel)
    elif tag == 'Path':
        # Paths don't have simple bounding box — guess from path data or skip
        return None
    else:
        # For other elements, try Left/Top/Width/Height
        left = float(el.get('Left', 0))
        top = float(el.get('Top', 0))
        w = float(el.get('Width', 100))
        h = float(el.get('Height', 100))
        return (left + w * cx_rel, top + h * cy_rel)


def _render_element(el, grad_map, depth=0):
    """Recursively render a TGML element to SVG lines. Returns list of SVG strings."""
    lines = []
    tag = el.tag
    indent = '  ' * depth

    # Skip non-visual elements
    if tag in SKIPPED_ELEMENTS:
        return lines

    # Skip gradient elements (handled in defs)
    if tag in ('LinearGradient', 'RadialGradient', 'GradientStop'):
        return lines

    if not _visibility_visible(el):
        return lines

    # ---- Groups and Layers ----
    if tag in ('Group', 'Layer', 'Tgml'):
        for child in el:
            lines.extend(_render_element(child, grad_map, depth))
        return lines

    # ---- Component ----
    if tag == 'Component':
        # Skip template components cloned at runtime
        comp_id = el.get('Id', '') or el.get('Name', '')
        if comp_id in TEMPLATE_COMPONENT_IDS:
            return lines

        left = float(el.get('Left', 0))
        top = float(el.get('Top', 0))
        inner = []
        for child in el:
            inner.extend(_render_element(child, grad_map, depth + 1))
        if inner:
            lines.append(f'{indent}<g transform="translate({left}, {top})">')
            lines.extend(inner)
            lines.append(f'{indent}</g>')
        return lines

    # Check for Rotate child that should modify this element
    rotate_child = None
    for child in el:
        if child.tag == 'Rotate':
            rotate_child = child
            break

    # Build transform string from Rotate if present
    transform_str = ''
    if rotate_child is not None:
        angle = rotate_child.get('Angle', '0')
        center_pt = _get_rotate_center(el, rotate_child)
        if center_pt:
            transform_str = f' transform="rotate({angle}, {center_pt[0]}, {center_pt[1]})"'
        elif angle and angle != '0':
            transform_str = f' transform="rotate({angle})"'

    # ---- Rectangle ----
    if tag == 'Rectangle':
        x = el.get('Left', '0')
        y = el.get('Top', '0')
        w = el.get('Width', '100')
        h = el.get('Height', '100')
        rx = el.get('RadiusX', '0')
        ry = el.get('RadiusY', '0')
        attrs = _common_attrs(el, grad_map)
        rect = f'<rect x="{x}" y="{y}" width="{w}" height="{h}"'
        if rx != '0':
            rect += f' rx="{rx}"'
        if ry != '0':
            rect += f' ry="{ry}"'
        rect += f'{transform_str} {attrs}/>'
        lines.append(f'{indent}{rect}')
        # Process non-Rotate children
        for child in el:
            if child.tag != 'Rotate':
                lines.extend(_render_element(child, grad_map, depth + 1))
        return lines

    # ---- Ellipse (Left/Top = center point in TGML) ----
    if tag == 'Ellipse':
        cx = el.get('Left', '0')
        cy = el.get('Top', '0')
        w = float(el.get('Width', '10'))
        h = float(el.get('Height', '10'))
        rx_val = w / 2.0
        ry_val = h / 2.0
        attrs = _common_attrs(el, grad_map)
        ell = (f'<ellipse cx="{cx}" cy="{cy}" rx="{rx_val}" ry="{ry_val}"{transform_str} {attrs}/>')
        lines.append(f'{indent}{ell}')
        for child in el:
            if child.tag != 'Rotate':
                lines.extend(_render_element(child, grad_map, depth + 1))
        return lines

    # ---- Curve (outline — usually stroke-only) ----
    if tag == 'Curve':
        pts = el.get('Points', '')
        if pts:
            path_d = _points_to_path(pts)
            attrs = _common_attrs(el, grad_map, force_fill_none=True)
            lines.append(f'{indent}<path d="{path_d}"{transform_str} {attrs}/>')
        for child in el:
            if child.tag != 'Rotate':
                lines.extend(_render_element(child, grad_map, depth + 1))
        return lines

    # ---- Path ----
    if tag == 'Path':
        path_d = el.get('PathData', '')
        if path_d:
            attrs = _common_attrs(el, grad_map)
            lines.append(f'{indent}<path d="{path_d}"{transform_str} {attrs}/>')
        for child in el:
            if child.tag != 'Rotate':
                lines.extend(_render_element(child, grad_map, depth + 1))
        return lines

    # ---- Line ----
    if tag == 'Line':
        x1 = el.get('X1', '0')
        y1 = el.get('Y1', '0')
        x2 = el.get('X2', '0')
        y2 = el.get('Y2', '0')
        attrs = _common_attrs(el, grad_map, force_fill_none=True)
        lines.append(f'{indent}<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"{transform_str} {attrs}/>')
        for child in el:
            if child.tag != 'Rotate':
                lines.extend(_render_element(child, grad_map, depth + 1))
        return lines

    # ---- Rotate (standalone — only if it has visual children) ----
    if tag == 'Rotate':
        # If we got here, the Rotate doesn't have a parent shape to attach to.
        # Render its children directly (should be rare)
        angle = rotate_child.get('Angle', '0') if rotate_child else el.get('Angle', '0')
        center = el.get('Center')
        inner = []
        for child in el:
            if child.tag not in ('Bind', 'Expose', 'ConvertRange', 'ConvertValue'):
                inner.extend(_render_element(child, grad_map, depth + 1))
        if inner:
            if center:
                c_parts = center.split(',')
                lines.append(f'{indent}<g transform="rotate({angle}, {c_parts[0].strip()}, {c_parts[1].strip()})">')
            else:
                lines.append(f'{indent}<g transform="rotate({angle})">')
            lines.extend(inner)
            lines.append(f'{indent}</g>')
        return lines

    # ---- Text / TextBox ----
    if tag in ('Text', 'TextBox'):
        # Extract content from: el.text, children's tails, and Content attribute
        content = ''

        # Check direct text content
        if el.text and el.text.strip():
            content = el.text.strip()

        # Check children's tails for CDATA content
        if not content:
            for child in el:
                if child.tail and child.tail.strip():
                    tail_clean = child.tail.strip()
                    if tail_clean.startswith('<![CDATA['):
                        tail_clean = tail_clean[9:-3]
                    if tail_clean.strip():
                        content = tail_clean.strip()
                        break

        # Check Content attribute as fallback
        if not content:
            content = el.get('Content', '')
        if not content:
            content = '...'

        x = el.get('Left', '0')
        y = el.get('Top', '0')
        font_family = el.get('FontFamily', 'Arial')
        font_size = el.get('FontSize', '12')
        font_weight = el.get('FontWeight', 'Normal')
        font_style = el.get('FontStyle', 'Normal')
        h_align = el.get('HorizontalAlign', 'Left')

        color = _get_fill_or_grad(el, 'Stroke', {})
        if color == 'none' or color is None:
            color = '#000000'

        text_anchor = 'start'
        if h_align.lower() == 'center':
            text_anchor = 'middle'
        elif h_align.lower() == 'right':
            text_anchor = 'end'

        # SVG y is baseline, TGML Top is top of text
        text_y = float(y) + float(font_size) * 0.85

        content_escaped = html.escape(content)
        text_el = (f'<text x="{x}" y="{text_y}" font-family="{font_family}" '
                   f'font-size="{font_size}" font-weight="{font_weight}" '
                   f'font-style="{font_style}" fill="{color}" '
                   f'text-anchor="{text_anchor}"{transform_str}>{content_escaped}</text>')
        lines.append(f'{indent}{text_el}')
        for child in el:
            if child.tag != 'Rotate':
                lines.extend(_render_element(child, grad_map, depth + 1))
        return lines

    # ---- Image ----
    if tag == 'Image':
        x = el.get('Left', '0')
        y = el.get('Top', '0')
        w = el.get('Width', '100')
        h = el.get('Height', '100')
        data = el.text or ''
        if data.startswith('<![CDATA['):
            data = data[9:-3]
        if data:
            img_type = 'png'
            if data.startswith('/9j/'):
                img_type = 'jpeg'
            elif data.startswith('R0lGOD'):
                img_type = 'gif'
            lines.append(f'{indent}<image x="{x}" y="{y}" width="{w}" height="{h}"{transform_str} '
                        f'href="data:image/{img_type};base64,{data}"/>')
        return lines

    # ---- Unknown ----
    for child in el:
        lines.extend(_render_element(child, grad_map, depth + 1))
    return lines


def convert_file(tgml_path, svg_path=None):
    """Convert a single TGML file to SVG."""
    tree = ET.parse(tgml_path)
    root = tree.getroot()

    if root.tag not in ('Tgml', 'TGML', 'tgml'):
        print(f"  Warning: root tag '{root.tag}' doesn't look like TGML")

    width = float(root.get('Width', '1600'))
    height = float(root.get('Height', '900'))
    bg_color = root.get('Background', '#FFFFFF')

    # First pass: collect all gradients
    GRADIENT_COUNTER[0] = 0
    grad_map = {}
    _collect_gradients(root, grad_map)

    # Build SVG
    svg_lines = []
    svg_lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" '
                     f'viewBox="0 0 {width} {height}" '
                     f'width="{width}" height="{height}">')

    # Background rect
    svg_lines.append(f'  <rect width="100%" height="100%" fill="{bg_color}"/>')

    # Defs
    svg_lines.append('  <defs>')
    all_gradients = root.findall('.//LinearGradient') + root.findall('.//RadialGradient')
    for grad_el in all_gradients:
        gid = grad_map.get(id(grad_el))
        if gid:
            svg_lines.append('    ' + _make_gradient_def(grad_el, gid))
    svg_lines.append('  </defs>')

    # Render elements
    for child in root:
        svg_lines.extend(_render_element(child, grad_map, depth=1))

    svg_lines.append('</svg>')

    svg_content = '\n'.join(svg_lines)

    if svg_path:
        with open(svg_path, 'w', encoding='utf-8') as f:
            f.write(svg_content)
        return svg_path
    return svg_content


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    path = sys.argv[1]

    if os.path.isdir(path):
        folder = Path(path)
        tgml_files = list(folder.glob('*.tgml')) + list(folder.glob('*.TGML'))
        if not tgml_files:
            print(f"No .tgml files found in {path}")
            sys.exit(1)
        print(f"Found {len(tgml_files)} TGML files in {path}")
        for tf in tgml_files:
            out_path = tf.with_suffix('.svg')
            try:
                convert_file(str(tf), str(out_path))
                print(f"  ✓ {tf.name} → {out_path.name}")
            except Exception as e:
                print(f"  ✗ {tf.name}: {e}")
    else:
        tgml_path = Path(path)
        if not tgml_path.exists():
            print(f"File not found: {path}")
            sys.exit(1)
        svg_path = sys.argv[2] if len(sys.argv) > 2 else str(tgml_path.with_suffix('.svg'))
        try:
            result = convert_file(str(tgml_path), str(svg_path))
            print(f"Converted: {tgml_path.name} → {svg_path}")
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()
            sys.exit(1)


if __name__ == '__main__':
    main()
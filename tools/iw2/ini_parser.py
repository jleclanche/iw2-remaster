"""Parser for IW2/Flux-flavored INI files.

Differences from vanilla INI:
- ``;`` starts a comment (whole line or trailing)
- keys may repeat as arrays via ``key[n]=value`` (n not necessarily dense)
- vector values: ``(a, b, c)``
- quoted strings keep their contents, unquoted values are trimmed
- resource references look like ``scheme:/path``
- the same key may appear twice without an index (last one wins)
"""

from __future__ import annotations

import re

_SECTION_RE = re.compile(r"^\[(.+?)\]\s*$")
_KEY_RE = re.compile(r"^([A-Za-z_][\w ]*?)(?:\[(\d+)\])?\s*=\s*(.*)$")
_VECTOR_RE = re.compile(r"^\(\s*([^)]*)\)$")


def _parse_scalar(raw: str):
    s = raw.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    m = _VECTOR_RE.match(s)
    if m:
        return [_parse_scalar(part) for part in m.group(1).split(",")]
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s


def _strip_comment(line: str) -> str:
    # a ';' inside double quotes does not start a comment
    in_quote = False
    for i, ch in enumerate(line):
        if ch == '"':
            in_quote = not in_quote
        elif ch == ";" and not in_quote:
            return line[:i]
    return line


def parse_ini(text: str) -> dict:
    """Parse to {section: {key: value | {index: value}}}.

    Indexed keys (``template[3]=``) become dicts keyed by int index; callers
    that want a dense list can use :func:`indexed_to_list`.
    """
    sections: dict = {}
    current: dict | None = None
    for raw_line in text.splitlines():
        line = _strip_comment(raw_line).strip()
        if not line:
            continue
        m = _SECTION_RE.match(line)
        if m:
            name = m.group(1).strip()
            current = sections.setdefault(name, {})
            continue
        if current is None:
            continue  # junk before first section
        m = _KEY_RE.match(line)
        if not m:
            continue
        key, index, value = m.group(1).strip(), m.group(2), _parse_scalar(m.group(3))
        if index is None:
            current[key] = value
        else:
            slot = current.get(key)
            if not isinstance(slot, dict):
                slot = current[key] = {}
            slot[int(index)] = value
    return sections


def indexed_to_list(indexed: dict) -> list:
    """{0: a, 2: c} -> [a, None, c] (preserves sparse indices)."""
    if not indexed:
        return []
    out = [None] * (max(indexed) + 1)
    for i, v in indexed.items():
        out[i] = v
    return out

"""Virtual filesystem over an Independence War 2 installation.

The Flux engine resolves resource references like ``ini:/subsims/systems/foo``
against a layered filesystem: loose files under ``<game>/resource/`` override
entries in ``<game>/resource.zip``. Reference schemes (``ini:``, ``lws:``,
``map:``, ``collision_hull:``…) name the loader; the path maps to a file with
the matching extension.
"""

from __future__ import annotations

import os
import zipfile
from pathlib import Path

DEFAULT_GAME_DIR = r"C:\Program Files (x86)\GOG Galaxy\Games\Independence War 2"

# scheme -> file extension
SCHEME_EXT = {
    "ini": ".ini",
    "lws": ".lws",
    "lwo": ".lwo",
    "map": ".map",
    "collision_hull": ".giz",
    "pso": ".pso",
}


class ResourceFS:
    def __init__(self, game_dir: str | os.PathLike | None = None):
        self.game_dir = Path(game_dir or os.environ.get("IW2_GAME_DIR") or DEFAULT_GAME_DIR)
        self.loose_root = self.game_dir / "resource"
        self.zip = zipfile.ZipFile(self.game_dir / "resource.zip")
        # zip entries use forward slashes; index case-insensitively
        self._zip_index = {n.lower(): n for n in self.zip.namelist()}

    def _normalize(self, path: str) -> str:
        return path.replace("\\", "/").lstrip("/").lower()

    def exists(self, path: str) -> bool:
        p = self._normalize(path)
        return (self.loose_root / p).is_file() or p in self._zip_index

    def read_bytes(self, path: str) -> bytes:
        p = self._normalize(path)
        loose = self.loose_root / p
        if loose.is_file():
            return loose.read_bytes()
        real = self._zip_index.get(p)
        if real is None:
            raise FileNotFoundError(path)
        return self.zip.read(real)

    def read_text(self, path: str) -> str:
        return self.read_bytes(path).decode("latin-1")

    def resolve_ref(self, ref: str) -> str | None:
        """Turn ``ini:/subsims/foo`` into a vfs path like ``subsims/foo.ini``.

        Returns None for refs whose scheme we don't map to a file (e.g. nulls).
        """
        if ":" not in ref:
            return None
        scheme, _, path = ref.partition(":")
        ext = SCHEME_EXT.get(scheme.lower())
        if ext is None:
            return None
        path = self._normalize(path)
        if not path.endswith(ext):
            path += ext
        return path

    def list(self, prefix: str = "", suffix: str = "") -> list[str]:
        """All vfs paths (zip + loose) under prefix with the given suffix."""
        prefix = self._normalize(prefix) if prefix else ""
        suffix = suffix.lower()
        found = {n for n in self._zip_index if n.startswith(prefix) and n.endswith(suffix)}
        if self.loose_root.is_dir():
            for f in self.loose_root.rglob("*"):
                if f.is_file():
                    rel = f.relative_to(self.loose_root).as_posix().lower()
                    if rel.startswith(prefix) and rel.endswith(suffix):
                        found.add(rel)
        return sorted(found)

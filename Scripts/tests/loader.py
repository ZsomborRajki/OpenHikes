"""Imports a script whose file name is not a Python identifier.

Every script in `Scripts/` is spelled with hyphens, so `import perf-report` is
a syntax error and no test can reach the code by name. Loading it from its path
keeps the scripts named after what they do — and, more to the point, keeps
these tests running the file CI runs rather than a renamed copy of it that can
drift away from it silently.

Nothing here is imported at module scope by the scripts themselves; each has a
`if __name__ == "__main__"` guard, and a module loaded under any other name
runs no `main()`.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

SCRIPTS = Path(__file__).resolve().parent.parent


def load(file_name: str) -> ModuleType:
    """The script at `Scripts/<file_name>`, as a module."""
    path = SCRIPTS / file_name
    name = "openhikes_" + path.stem.replace("-", "_")
    if (loaded := sys.modules.get(name)) is not None:
        return loaded
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"No module could be built from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

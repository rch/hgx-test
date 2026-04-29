"""Wrapper around the harbor CLI that applies local patches before invoking it.

Invoked by the justfile recipes. Don't call `harbor` directly when running the
benchmark — the patches in ../patches/ won't load.

Run with harbor's installed venv interpreter (the justfile detects it from the
`harbor` shebang); we add the repo root to sys.path so `import patches.*`
resolves regardless of cwd.
"""

import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _REPO_ROOT)

import patches.empty_content  # noqa: F401, E402 — monkeypatches Chat.chat on import

from harbor.cli.main import app  # noqa: E402

if __name__ == "__main__":
    sys.exit(app())

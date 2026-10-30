"""Hermes plugin entry point; all event production uses supported host hooks."""
from pathlib import Path
import sys

_PACKAGE = str(Path(__file__).resolve().parent)
if _PACKAGE not in sys.path:
    sys.path.insert(0, _PACKAGE)


def register(ctx):
    from botto_push.runtime import register as register_runtime
    register_runtime(ctx)


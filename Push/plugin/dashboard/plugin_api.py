"""Mounted by Hermes behind its authenticated profile-scoped plugin boundary."""
from pathlib import Path
import sys

_PACKAGE = str(Path(__file__).resolve().parents[1])
if _PACKAGE not in sys.path:
    sys.path.insert(0, _PACKAGE)

from botto_push.api import create_router
from botto_push.runtime import configured_service

router = create_router(configured_service)


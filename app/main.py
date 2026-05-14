from __future__ import annotations

import sys


try:
    from app.professional import main_runtime as _runtime
except ModuleNotFoundError as _professional_runtime_error:
    if _professional_runtime_error.name not in {"app.professional", "app.professional.main_runtime"}:
        raise
    from app.community import runtime as _runtime

sys.modules[__name__] = _runtime

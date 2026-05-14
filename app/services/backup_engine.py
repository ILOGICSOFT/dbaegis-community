from __future__ import annotations

try:
    from app.professional import backup_engine as _impl
except Exception as exc:
    _IMPORT_ERROR = exc
else:
    import sys as _sys
    _sys.modules[__name__] = _impl


if "_impl" not in globals():
    def __getattr__(name):
        raise RuntimeError(f"Professional backup engine overlay is not installed: {_IMPORT_ERROR}")

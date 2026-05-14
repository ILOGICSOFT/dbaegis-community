from __future__ import annotations

try:
    from app.professional import global_notifications as _impl
except Exception:
    _impl = None
else:
    import sys as _sys
    _sys.modules[__name__] = _impl


def _missing_result(*_args, **_kwargs):
    return {"ok": False, "message": "Professional notifications overlay is not installed"}


if _impl is None:
    DB = ""
    send_webhook_request = None

    async def send_backup_result_email(*args, **kwargs):
        return _missing_result(*args, **kwargs)

    async def send_restore_result_email(*args, **kwargs):
        return _missing_result(*args, **kwargs)

    def send_daily_summary_email(*args, **kwargs):
        return _missing_result(*args, **kwargs)

    def maybe_send_daily_summary_email(*args, **kwargs):
        return _missing_result(*args, **kwargs)

    def get_smtp_settings():
        return {}

    def get_global_notifications_config():
        return {}

    def save_smtp_settings(data):
        raise RuntimeError("Professional notifications overlay is not installed")

    def save_global_notifications_config(data):
        raise RuntimeError("Professional notifications overlay is not installed")

    def __getattr__(name):
        raise AttributeError(name)

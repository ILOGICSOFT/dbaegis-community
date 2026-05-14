from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any

PRODUCT_NAME = "DBAegis"
PRODUCT_VERSION = "1.0.0"
API_VERSION = "v1"
DB_SCHEMA_VERSION = 2
DEFAULT_BUILD_CHANNEL = "development"


def _candidate_manifest_paths() -> list[Path]:
    here = Path(__file__).resolve()
    base = here.parents[1] if len(here.parents) > 1 else here.parent
    paths: list[Path] = []
    env_path = os.environ.get("DBAEGIS_RELEASE_MANIFEST")
    if env_path:
        paths.append(Path(env_path))
    paths.extend(
        [
            base / "release.json",
            base / "conf" / "release.json",
            here.parent / "release.json",
        ]
    )
    return paths


def load_release_manifest() -> tuple[dict[str, Any], str | None]:
    for path in _candidate_manifest_paths():
        try:
            if not path.is_file():
                continue
            with path.open("r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                return data, str(path)
        except Exception:
            continue
    return {}, None


def _manifest_value(key: str) -> str | None:
    manifest, _ = load_release_manifest()
    value = manifest.get(key)
    if value in (None, ""):
        return None
    return str(value)


def get_git_commit() -> str | None:
    for value in (
        os.environ.get("DBAEGIS_GIT_COMMIT"),
        os.environ.get("GIT_COMMIT"),
        _manifest_value("git_commit"),
        _manifest_value("commit"),
    ):
        if value:
            return value[:40]

    try:
        repo_root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--short=12", "HEAD"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
        commit = result.stdout.strip()
        if result.returncode == 0 and commit:
            return commit
    except Exception:
        return None
    return None


def get_build_time() -> str | None:
    for value in (
        os.environ.get("DBAEGIS_BUILD_TIME"),
        os.environ.get("BUILD_TIME"),
        _manifest_value("build_time"),
        _manifest_value("built_at"),
    ):
        if value:
            return value
    return None


def get_build_channel() -> str:
    for value in (
        os.environ.get("DBAEGIS_BUILD_CHANNEL"),
        _manifest_value("build_channel"),
        _manifest_value("channel"),
    ):
        if value:
            return value
    return DEFAULT_BUILD_CHANNEL


def get_version_payload(db_schema_version: int | None = None) -> dict[str, Any]:
    manifest, manifest_path = load_release_manifest()
    build_channel = get_build_channel()
    payload: dict[str, Any] = {
        "product": PRODUCT_NAME,
        "version": PRODUCT_VERSION,
        "app_version": PRODUCT_VERSION,
        "api_version": API_VERSION,
        "db_schema_version": db_schema_version,
        "current_db_schema_version": DB_SCHEMA_VERSION,
        "build_channel": build_channel,
        "build_time": get_build_time(),
        "git_commit": get_git_commit(),
        "python_version": platform.python_version(),
        "platform": platform.platform(),
        "release_manifest": manifest_path,
    }
    release_name = manifest.get("release_name")
    if release_name:
        payload["release_name"] = str(release_name)
    elif build_channel and build_channel != DEFAULT_BUILD_CHANNEL:
        payload["release_name"] = f"{PRODUCT_NAME} {PRODUCT_VERSION}"
    edition = manifest.get("edition")
    if edition:
        payload["edition"] = str(edition)
    return payload


def format_version_line(payload: dict[str, Any] | None = None) -> str:
    info = payload or get_version_payload()
    line = f"{info.get('product') or PRODUCT_NAME} {info.get('version') or PRODUCT_VERSION}"
    commit = info.get("git_commit")
    if commit:
        line += f" ({commit})"
    channel = info.get("build_channel")
    if channel and channel != "stable":
        line += f" [{channel}]"
    return line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Show DBAegis version metadata")
    parser.add_argument("--json", action="store_true", help="print full version metadata as JSON")
    parser.add_argument("--line", action="store_true", help="print a single version line")
    args = parser.parse_args(argv)
    payload = get_version_payload()
    if args.json:
        print(json.dumps(payload, sort_keys=True))
    else:
        print(format_version_line(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

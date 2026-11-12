#!/usr/bin/env python3
"""把 GitHub Release 的产物同步到 CNB Release。

CNB 的 Release 附件走对象存储预签名上传：
  1. POST /releases/{id}/asset-upload-url 获取 upload_url / verify_url
  2. PUT 上传文件
  3. POST verify_url 确认

环境变量：
    CNB_TOKEN  CNB 访问令牌（repo-release:rw）
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cnb.cool"
DEFAULT_REPO = "yunfeiii/clipkeep"


def _request(
    method: str,
    url: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 180,
) -> tuple[int, bytes]:
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers=headers or {},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def _api(
    method: str,
    path: str,
    token: str,
    *,
    payload: dict[str, object] | None = None,
) -> tuple[int, dict[str, object]]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    status, body = _request(
        method,
        f"{API}{path}",
        body=data,
        headers={
            "Accept": "application/vnd.cnb.api+json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        parsed = json.loads(body.decode("utf-8")) if body else {}
    except json.JSONDecodeError:
        parsed = {}
    if isinstance(parsed, list):
        return status, {"data": parsed}
    if not isinstance(parsed, dict):
        parsed = {}
    return status, parsed


def _find_release(repo: str, tag: str, token: str) -> dict[str, object] | None:
    status, data = _api("GET", f"/{repo}/-/releases", token)
    if status >= 400:
        raise RuntimeError(f"读取 CNB Release 列表失败：HTTP {status}")
    releases = data.get("data") or data.get("releases") or data.get("list")
    if isinstance(releases, list):
        for item in releases:
            if isinstance(item, dict) and item.get("tag_name") == tag:
                return item
    return None


def _create_release(
    repo: str,
    tag: str,
    name: str,
    body: str,
    token: str,
) -> dict[str, object]:
    status, data = _api(
        "POST",
        f"/{repo}/-/releases",
        token,
        payload={
            "tag_name": tag,
            "name": name,
            "body": body,
            "prerelease": False,
            "draft": False,
            "make_latest": "true",
        },
    )
    if status == 409:
        existing = _find_release(repo, tag, token)
        if existing is not None:
            _mark_latest(repo, str(existing.get("id", "")), token)
            return existing
    if status >= 400:
        raise RuntimeError(f"创建 CNB Release 失败：HTTP {status}")
    if not data.get("id"):
        existing = _find_release(repo, tag, token)
        if existing is not None:
            return existing
    return data


def _mark_latest(repo: str, release_id: str, token: str) -> None:
    if not release_id:
        return
    status, _ = _api(
        "PATCH",
        f"/{repo}/-/releases/{release_id}",
        token,
        payload={"make_latest": "true"},
    )
    if status >= 400:
        raise RuntimeError(f"标记 CNB latest 失败：HTTP {status}")


def _existing_assets(release: dict[str, object]) -> set[str]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        return set()
    result: set[str] = set()
    for item in assets:
        if isinstance(item, dict):
            name = item.get("name")
            if isinstance(name, str) and name:
                result.add(name)
    return result


def _upload_asset(
    repo: str,
    release_id: str,
    path: pathlib.Path,
    token: str,
) -> None:
    size = path.stat().st_size
    status, data = _api(
        "POST",
        f"/{repo}/-/releases/{release_id}/asset-upload-url",
        token,
        payload={
            "asset_name": path.name,
            "size": size,
            "overwrite": True,
        },
    )
    if status >= 400:
        raise RuntimeError(f"获取 {path.name} 上传地址失败：HTTP {status}")
    upload_url = data.get("upload_url")
    verify_url = data.get("verify_url")
    if not isinstance(upload_url, str) or not isinstance(verify_url, str):
        raise RuntimeError(f"{path.name} 上传地址响应不完整")
    status, body = _request(
        "PUT",
        upload_url,
        body=path.read_bytes(),
        headers={"Content-Type": "application/octet-stream"},
        timeout=600,
    )
    if status >= 400:
        detail = body.decode("utf-8", "replace")[:200]
        raise RuntimeError(f"上传 {path.name} 失败：HTTP {status} {detail}")
    status, body = _request(
        "POST",
        verify_url,
        headers={
            "Accept": "application/vnd.cnb.api+json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    if status >= 400:
        detail = body.decode("utf-8", "replace")[:200]
        raise RuntimeError(f"确认 {path.name} 失败：HTTP {status} {detail}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--name", default="")
    parser.add_argument("--notes-file", required=True)
    parser.add_argument("--asset", action="append", default=[])
    parser.add_argument("--token-env", default="CNB_TOKEN")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    token = os.environ.get(args.token_env, "").strip()
    if not token:
        sys.exit(f"缺少环境变量 {args.token_env}")

    notes_path = pathlib.Path(args.notes_file)
    body = notes_path.read_text(encoding="utf-8")
    name = args.name or f"ClipKeep {args.tag}"
    assets = [pathlib.Path(item) for item in args.asset]
    missing = [str(path) for path in assets if not path.is_file()]
    if missing:
        sys.exit("附件不存在：" + ", ".join(missing))

    release = _find_release(args.repo, args.tag, token)
    if release is None:
        if args.dry_run:
            print(f"[dry-run] 将创建 CNB Release {args.tag}", flush=True)
            release = {}
        else:
            release = _create_release(args.repo, args.tag, name, body, token)
            print(f"已创建 CNB Release {args.tag}", flush=True)

    release_id = str(release.get("id", ""))
    if not release_id and not args.dry_run:
        found = _find_release(args.repo, args.tag, token)
        if found is not None:
            release = found
            release_id = str(release.get("id", ""))
    if release_id and not args.dry_run:
        _mark_latest(args.repo, release_id, token)
    existing = _existing_assets(release)
    uploaded = 0
    for path in assets:
        if path.name in existing:
            print(f"跳过已存在附件：{path.name}", flush=True)
            continue
        if args.dry_run:
            print(f"[dry-run] 将上传：{path.name}", flush=True)
            continue
        if not release_id:
            raise RuntimeError("Release 缺少 id，无法上传附件")
        print(f"开始上传：{path.name}（{path.stat().st_size} bytes）", flush=True)
        _upload_asset(args.repo, release_id, path, token)
        uploaded += 1
        print(f"已上传：{path.name}", flush=True)

    print(f"CNB 同步完成：新增 {uploaded} 个附件", flush=True)


if __name__ == "__main__":
    main()

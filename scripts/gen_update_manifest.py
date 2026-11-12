#!/usr/bin/env python3
"""从构建产物与 CHANGELOG 生成 update.json（App 检查更新用）。

版本号取自 pubspec.yaml 的 `version: x.y.z+n`，发布日期取自 CHANGELOG 对应版本块，
APK 的 size / sha256 现算，release 由 CI 传入当时的 tag。

用法：
    python3 scripts/gen_update_manifest.py --release-tag android-build-62
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

# ABI -> Release 资产名（与 android.yml 的上传列表保持一致）
APKS = {
    "arm64-v8a": "app-arm64-v8a-release.apk",
    "armeabi-v7a": "app-armeabi-v7a-release.apk",
    "x86_64": "app-x86_64-release.apk",
}


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_aapt2() -> str | None:
    """定位 aapt2：优先 Android SDK 的 build-tools，其次 PATH。"""
    for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        root = os.environ.get(key)
        if not root:
            continue
        candidates = sorted(
            glob.glob(os.path.join(root, "build-tools", "*", "aapt2*")),
            reverse=True,
        )
        for candidate in candidates:
            if os.path.isfile(candidate):
                return candidate
    return shutil.which("aapt2")


def read_apk_version_code(aapt2: str, path: pathlib.Path) -> int | None:
    """读 APK 里真实的 versionCode。

    `--split-per-abi` 会让每个架构的 APK 带上不同的 versionCode 偏移
    （armeabi-v7a 1009 / arm64-v8a 2009 / x86_64 4009），与 pubspec 的
    基准值 9 并不相同；清单必须记录真实值，否则 App 里两个数字对不上。
    """
    try:
        result = subprocess.run(
            [aapt2, "dump", "badging", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    match = re.search(r"versionCode='(\d+)'", result.stdout)
    return int(match.group(1)) if match else None


def read_version(pubspec: pathlib.Path) -> tuple[str, int]:
    text = pubspec.read_text(encoding="utf-8")
    match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+(\d+)\s*$", text, re.MULTILINE
    )
    if match is None:
        sys.exit("pubspec.yaml 里找不到 version: x.y.z+n")
    return match.group(1), int(match.group(2))


def read_published_at(changelog: pathlib.Path, version_name: str) -> str:
    text = changelog.read_text(encoding="utf-8")
    pattern = rf"^## \[{re.escape(version_name)}\] - (\d{{4}}-\d{{2}}-\d{{2}})$"
    match = re.search(pattern, text, re.MULTILINE)
    if match is None:
        sys.exit(f"CHANGELOG.md 缺少 ## [{version_name}] - YYYY-MM-DD 版本块")
    return match.group(1)


def read_release_notes(changelog: pathlib.Path, version_name: str) -> str:
    """取出该版本的正文（去掉 meta 注释），用于 Release 说明。"""
    lines = changelog.read_text(encoding="utf-8").splitlines()
    pattern = re.compile(
        rf"^## \[{re.escape(version_name)}\] - \d{{4}}-\d{{2}}-\d{{2}}$"
    )
    start = next((i for i, line in enumerate(lines) if pattern.match(line)), None)
    if start is None:
        return ""
    body: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        if line.strip().startswith("<!-- meta:") and line.strip().endswith("-->"):
            continue
        body.append(line)
    return "\n".join(body).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk-dir", default="build/app/outputs/flutter-apk")
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--output", default="update.json")
    parser.add_argument(
        "--notes-output",
        default="",
        help="可选：把该版本的 CHANGELOG 正文写成 Release 说明文件",
    )
    parser.add_argument(
        "--asset-base-url",
        action="append",
        default=[],
        help="可选：Release 资产基地址，可重复；按顺序写入 urls（CNB 在前，GitHub 在后）",
    )
    parser.add_argument("--pubspec", default="pubspec.yaml")
    parser.add_argument("--changelog", default="CHANGELOG.md")
    args = parser.parse_args()

    version_name, version_code = read_version(pathlib.Path(args.pubspec))
    published_at = read_published_at(pathlib.Path(args.changelog), version_name)

    apk_dir = pathlib.Path(args.apk_dir)
    aapt2 = find_aapt2()
    if aapt2 is None:
        print("警告：找不到 aapt2，update.json 将不记录各 ABI 的 versionCode")
    apks: dict[str, dict[str, object]] = {}
    for abi, asset_name in APKS.items():
        path = apk_dir / asset_name
        if not path.exists():
            sys.exit(f"缺少构建产物：{path}")
        urls = [
            f"{base.rstrip('/')}/{asset_name}"
            for base in args.asset_base_url
            if base.strip()
        ]
        apk_version_code = read_apk_version_code(aapt2, path) if aapt2 else None
        apks[abi] = {
            "asset": asset_name,
            "size": path.stat().st_size,
            "sha256": sha256_of(path),
            **({"versionCode": apk_version_code} if apk_version_code else {}),
            **({"urls": urls} if urls else {}),
        }

    manifest = {
        "versionName": version_name,
        "versionCode": version_code,
        "publishedAt": published_at,
        "release": args.release_tag,
        "apks": apks,
    }
    output = pathlib.Path(args.output)
    output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    if args.notes_output:
        notes = read_release_notes(pathlib.Path(args.changelog), version_name)
        if not notes:
            sys.exit(f"CHANGELOG.md 里 {version_name} 的版本块为空")
        pathlib.Path(args.notes_output).write_text(
            notes + "\n", encoding="utf-8"
        )
        print(f"生成 {args.notes_output}: {len(notes)} 字符")

    total = sum(int(item["size"]) for item in apks.values())
    codes = "/".join(str(item.get("versionCode", "-")) for item in apks.values())
    print(
        f"生成 {output}: {version_name} ({version_code}) / {args.release_tag} / "
        f"{len(apks)} 个 ABI / versionCode {codes} / "
        f"共 {total / 1024 / 1024:.1f} MB"
    )


if __name__ == "__main__":
    main()

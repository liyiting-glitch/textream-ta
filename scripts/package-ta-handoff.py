#!/usr/bin/env python3
"""Package only committed source and a verified macOS app; never local user data."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--binary-commit", required=True)
    parser.add_argument("--ci-url", required=True)
    parser.add_argument("--name", default="Textream-Codex-Handoff-2026-10-28")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist"))
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    app = args.app.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if pathlib.Path(args.name).name != args.name or args.name in (".", ".."):
        parser.error("--name must be a filename without directory separators")
    for command in (("git", "diff", "--quiet"), ("git", "diff", "--cached", "--quiet")):
        subprocess.run(command, cwd=repo, check=True)
    source_commit = run("git", "rev-parse", "HEAD", cwd=repo)
    binary_commit = run("git", "rev-parse", args.binary_commit + "^{commit}", cwd=repo)
    subprocess.run(["git", "diff", "--exit-code", "--quiet", binary_commit, source_commit,
                    "--", "Textream", "TARegressionTests.swift"], cwd=repo, check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.liyitingglitch.textream.ta":
        parser.error("Expected the full Textream app, not the integration harness")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architectures = run("lipo", "-archs", str(executable)).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        parser.error("This handoff requires the universal macOS app")
    output.mkdir(parents=True, exist_ok=True)
    app_zip = output / "Textream-TA-macOS-universal.zip"
    source_zip = output / "Textream-TA-source.zip"
    bundle_zip = output / (args.name + ".zip")
    for path in (app_zip, source_zip, bundle_zip):
        if path.exists():
            parser.error(f"Output already exists; choose a fresh output folder: {path}")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_zip)], check=True)
    subprocess.run(["git", "archive", "--format=zip", "--prefix=source/", "-o", str(source_zip), source_commit], cwd=repo, check=True)
    manifest = {
        "handoff_source_commit": source_commit,
        "tested_binary_source_commit": binary_commit,
        "app_source_matches_tested_commit": True,
        "ci_url": args.ci_url,
        "bundle_identifier": info["CFBundleIdentifier"],
        "app_version": info["CFBundleShortVersionString"],
        "minimum_macos": info["LSMinimumSystemVersion"],
        "architectures": architectures,
        "distribution": "local ad-hoc signature; not Developer ID signed or notarized",
        "executable_sha256": sha256(executable),
        "archives_sha256": {app_zip.name: sha256(app_zip), source_zip.name: sha256(source_zip)},
        "recommended_settings": json.loads((repo / "handoff/recommended-settings.json").read_text()),
    }
    manifest_path = output / "BUILD_MANIFEST.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="textream-handoff-") as tmp:
        bundle = pathlib.Path(tmp) / args.name
        bundle.mkdir()
        with zipfile.ZipFile(source_zip) as archive:
            archive.extractall(bundle)
        shutil.copy2(app_zip, bundle / app_zip.name)
        shutil.copy2(manifest_path, bundle / manifest_path.name)
        shutil.copy2(repo / "CODEX_HANDOFF.md", bundle / "CODEX_HANDOFF.md")
        (bundle / "START_HERE.md").write_text(
            "# Textream TA Codex 交接包\n\n"
            "先读 `CODEX_HANDOFF.md`，然后进入 `source/` 修改源码。"
            "源码内含 `AGENTS.md` 和构建工作流。\n\n"
            "`Textream-TA-macOS-universal.zip` 包含完整可运行应用；解压后放到稳定的 Applications 目录。"
            "要求 macOS 15+，无需 Xcode 即可运行。这是未公证的测试发行版。\n\n"
            "在新电脑通过应用填入自己的 API key，并允许系统音频与语音识别。"
            "将字幕宽度设为 750；新快捷键是 Control + Option + Command + A。\n\n"
            "包内不含 API key、会议内容或用户本机偏好。"
            "精确构建来源见 `BUILD_MANIFEST.json`。\n"
        )
        with zipfile.ZipFile(bundle_zip, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(bundle.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(bundle.parent))
    artifacts = (bundle_zip, app_zip, source_zip, manifest_path)
    (output / "SHA256SUMS.txt").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in artifacts))
    print(json.dumps({"output": str(output), "source_commit": source_commit,
                      "binary_commit": binary_commit, "artifacts": [p.name for p in artifacts]}, indent=2))


if __name__ == "__main__":
    main()

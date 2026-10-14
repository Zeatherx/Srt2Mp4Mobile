"""Generate Flutter-owned platform scaffolding, preserving app configuration.

Run `python tool/bootstrap.py` once with Flutter available on PATH.
Uses a separate folder so Flutter never overwrites this project's Dart code.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("Install Flutter and add its bin directory to PATH first.")
    if (ROOT / "android/settings.gradle.kts").exists() or (ROOT / "android/settings.gradle").exists():
        raise SystemExit("Platform scaffolding already exists. No files changed.")
    # Limit all writes and cleanup to a verified temporary folder in this repo.
    with tempfile.TemporaryDirectory(prefix=".platform_scaffold_", dir=ROOT,
                                     ignore_cleanup_errors=True) as temporary:
        scaffold = Path(temporary)
        subprocess.run([flutter, "create", "--no-pub", "--platforms=android,ios",
                        "--org", "com.example", "--project-name", "srt2mp4_mobile",
                        str(scaffold)], check=True)
        # Overlay our three configuration files before copying into the repo.
        for relative in ("android/app/src/main/AndroidManifest.xml",
                         "ios/Runner/Info.plist", "ios/Podfile"):
            shutil.copy2(ROOT / relative, scaffold / relative)
        gradle = scaffold / "android/app/build.gradle.kts"
        if not gradle.exists():
            gradle = scaffold / "android/app/build.gradle"
        content = gradle.read_text(encoding="utf-8")
        content, count = re.subn(r"minSdk\s*=\s*flutter.minSdkVersion", "minSdk = 24", content)
        if not count:
            content, count = re.subn(r"minSdkVersion\s+flutter.minSdkVersion", "minSdkVersion 24", content)
        if count != 1:
            raise RuntimeError("Flutter template changed: set Android minSdk to 24 manually.")
        gradle.write_text(content, encoding="utf-8")
        project = scaffold / "ios/Runner.xcodeproj/project.pbxproj"
        text = project.read_text(encoding="utf-8")
        text = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;",
                      "IPHONEOS_DEPLOYMENT_TARGET = 15.5;", text)
        project.write_text(text, encoding="utf-8")
        for platform in ("android", "ios"):
            shutil.copytree(scaffold / platform, ROOT / platform, dirs_exist_ok=True)
        if (scaffold / ".metadata").exists():
            shutil.copy2(scaffold / ".metadata", ROOT / ".metadata")
    print("Android (API 24+) and iOS (15.5+) scaffolding created. Run flutter pub get.")


if __name__ == "__main__":
    main()

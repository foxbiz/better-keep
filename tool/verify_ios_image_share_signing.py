#!/usr/bin/env python3
"""Fail a local/Xcode Cloud archive if either image-share target is misprovisioned."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile

GROUP = "group.io.foxbiz.betterKeep.imageShare"
APP_ID = "io.foxbiz.better-keep"


def validate_entitlements(signed, provisioned, bundle_id):
    for source in (signed, provisioned):
        if GROUP not in source.get("com.apple.security.application-groups", []):
            raise ValueError(f"{bundle_id}: missing image-share App Group")
    identifier = signed.get("application-identifier", "")
    if not identifier.endswith("." + bundle_id):
        raise ValueError(f"{bundle_id}: signed application identifier does not match")
    if identifier != provisioned.get("application-identifier"):
        raise ValueError(f"{bundle_id}: provisioning profile does not match signature")


def verify_archive(archive):
    archive = pathlib.Path(archive)
    if archive.suffix == ".xcarchive":
        return verify_app(archive / "Products/Applications/Runner.app")
    if archive.suffix == ".app":
        return verify_app(archive)
    exports = [archive] if archive.suffix == ".ipa" else list(archive.glob("*.ipa"))
    if len(exports) != 1:
        raise ValueError("Expected exactly one signed IPA export")
    with tempfile.TemporaryDirectory(prefix="image-share-signing-") as temporary:
        subprocess.run(["ditto", "-x", "-k", str(exports[0]), temporary], check=True, capture_output=True)
        verify_app(pathlib.Path(temporary) / "Payload/Runner.app")


def verify_app(app):
    for target, bundle_id in ((app, APP_ID), (app / "PlugIns/ShareExtension.appex", APP_ID + ".ShareExtension")):
        with (target / "Info.plist").open("rb") as stream:
            if plistlib.load(stream)["CFBundleIdentifier"] != bundle_id:
                raise ValueError(f"{bundle_id}: incorrect embedded bundle")
        subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True, capture_output=True)
        signed = plistlib.loads(subprocess.check_output(
            ["codesign", "-d", "--entitlements", ":-", str(target)], stderr=subprocess.DEVNULL))
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(target / "embedded.mobileprovision")], stderr=subprocess.DEVNULL))
        validate_entitlements(signed, profile["Entitlements"], bundle_id)
    print("Verified signed App Group entitlements and profiles for Runner and ShareExtension.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 tool/verify_ios_image_share_signing.py <Runner.xcarchive | signed.ipa | export-directory>")
    try:
        verify_archive(sys.argv[1])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Image-share signing verification failed: {error}")

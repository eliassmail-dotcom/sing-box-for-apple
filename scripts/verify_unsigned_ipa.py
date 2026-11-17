#!/usr/bin/env python3
"""Fail-closed structural preflight for the universal IPA handed to GBox/Feather.

This checks bundle metadata and cross-target App Group declarations at BUILD
time. The signer must still assign compatible application-identifier entitlements
and provisioning profiles individually for every bundle. A green preflight is
not a validation of a subsequently signed IPA.
"""
import argparse
import json
import plistlib
import sys
import zipfile
from pathlib import Path
from typing import Optional


def analyze(ipa: Path, expected_build: Optional[str]) -> dict:
    with zipfile.ZipFile(ipa) as z:
        names = set(z.namelist())
        apps = [n for n in names if n.startswith("Payload/") and
                n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(apps) != 1:
            raise ValueError(f"Expected exactly one Payload/*.app/Info.plist, got {len(apps)}")
        main_path = apps[0]
        main_dir = main_path[:-len("Info.plist")]
        plist_names = sorted([n for n in names if n.endswith(".appex/Info.plist")
                              and n.startswith(main_dir)])
        if len(plist_names) < 2:
            raise ValueError("Expected at least Packet Tunnel and File Provider extensions")
        bundles = []
        for name in [main_path, *plist_names]:
            p = plistlib.loads(z.read(name))
            bundle = p.get("CFBundleIdentifier", "")
            exe = p.get("CFBundleExecutable", "")
            ver = str(p.get("CFBundleVersion", ""))
            marketing = str(p.get("CFBundleShortVersionString", ""))
            group = p.get("AppGroupIdentifier", "")
            if not bundle or not exe or not ver or not marketing:
                raise ValueError(f"Incomplete bundle identity in {name}")
            if "$(" in bundle or "$(" in group:
                raise ValueError(f"Unexpanded build setting in {name}")
            directory = name[:-len("Info.plist")]
            if directory + exe not in names:
                raise ValueError(f"Missing CFBundleExecutable {exe} for {name}")
            if expected_build is not None and ver != expected_build:
                raise ValueError(f"Version mismatch {name}: {ver} != {expected_build}")
            bundles.append({
                "info": name, "bundle": bundle, "build": ver,
                "marketing": marketing, "group": group,
                "extension_point": p.get("NSExtension", {}).get("NSExtensionPointIdentifier"),
                "document_group": p.get("NSExtension", {}).get("NSExtensionFileProviderDocumentGroup")
            })

        host = bundles[0]
        if not host["group"]:
            raise ValueError("Missing host AppGroupIdentifier")
        group = host["group"]
        seen = set()
        for item in bundles:
            if item["bundle"] in seen:
                raise ValueError(f"Duplicate Bundle ID {item['bundle']}")
            seen.add(item["bundle"])
            if item["build"] != host["build"] or item["marketing"] != host["marketing"]:
                raise ValueError(f"Version mismatch in {item['info']}")
            if item["group"] != group:
                raise ValueError(f"App Group mismatch in {item['info']}")
            if item is not host and not item["bundle"].startswith(host["bundle"] + "."):
                raise ValueError(f"Extension Bundle ID not nested under host: {item['bundle']}")
            if item["document_group"] is not None and item["document_group"] != group:
                raise ValueError(f"Document Group mismatch in {item['info']}")
        vpn = [x for x in bundles[1:] if x["extension_point"] == "com.apple.networkextension.packet-tunnel"]
        fp = [x for x in bundles[1:] if x["extension_point"] == "com.apple.fileprovider-nonui"]
        if len(vpn) != 1 or len(fp) != 1:
            raise ValueError(f"Expected one Packet Tunnel and one File Provider, got {len(vpn)} and {len(fp)}")
        if fp[0]["document_group"] != group:
            raise ValueError("File Provider NSExtensionFileProviderDocumentGroup must equal App Group")
        # A truly unsigned IPA must not embed an old provisioning identity.
        if any(n.endswith("/embedded.mobileprovision") and n.startswith(main_dir) for n in names):
            raise ValueError("Unsigned IPA contains embedded provisioning profiles; signer must supply its own")

        return {
            "status": "BUILD_STRUCTURAL_PREFLIGHT_PASS",
            "unverified": "Actual signing, application-identifier and iOS extension registration",
            "main_bundle": host["bundle"], "app_group_at_build": group,
            "build": host["build"], "bundle_count": len(bundles),
            "bundles": bundles
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--build", default=None)
    args = parser.parse_args()
    try:
        result = analyze(args.ipa, args.build)
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as e:
        print(f"IPA PREFLIGHT FAILED: {e}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

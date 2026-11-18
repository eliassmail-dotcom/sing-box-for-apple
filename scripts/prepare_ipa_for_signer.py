#!/usr/bin/env python3
"""Prepare an *unsigned* universal SFI IPA for a known signing App Group.

Run this BEFORE GBox/Feather signs the app, not on the already signed IPA.
Apple requires the File Provider's static NSExtensionFileProviderDocumentGroup
to match an App Group actually authorized for the File Provider extension.
Changing only main app entitlements cannot repair a mismatched document group.

This script changes unsigned Info.plist metadata, NOT entitlements. The signer
must sign the host and all embedded extensions with matching entitlements.
"""
import argparse
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def prepare(source: Path, destination: Path, group: str) -> None:
    if not re.fullmatch(r"group\.[A-Za-z0-9][A-Za-z0-9._-]*", group):
        raise ValueError("Invalid App Group; expected group.<registered-id>")
    if source.resolve() == destination.resolve():
        raise ValueError("Source and destination IPA must differ")
    with zipfile.ZipFile(source, "r") as src:
        metadata = [n for n in src.namelist() if n.endswith("/Info.plist")
                    and (n.count("/") == 2 or n.endswith(".appex/Info.plist"))]
        has_host = any(n.startswith("Payload/") and n.count("/") == 2
                       and n.endswith(".app/Info.plist") for n in metadata)
        if not has_host:
            raise ValueError("No main app Info.plist in IPA")
        changed = 0
        fp_found = False
        with zipfile.ZipFile(destination, "w") as dest:
            for info in src.infolist():
                data = src.read(info)
                if info.filename in metadata:
                    item = plistlib.loads(data)
                    item["AppGroupIdentifier"] = group
                    ext = item.get("NSExtension")
                    if isinstance(ext, dict) and ext.get("NSExtensionPointIdentifier") == "com.apple.fileprovider-nonui":
                        ext["NSExtensionFileProviderDocumentGroup"] = group
                        fp_found = True
                    data = plistlib.dumps(item, fmt=plistlib.FMT_BINARY)
                    changed += 1
                dest.writestr(info, data)
    if not fp_found or changed < 3:
        destination.unlink(missing_ok=True)
        raise ValueError("Missing File Provider or unexpectedly few bundles")
    print(f"Prepared {changed} bundle Info.plists; File Provider document group: {group}")
    print("UNSIGNED ONLY. Now sign the host and every extension with a profile")
    print("authorizing this exact App Group, then inspect the signed entitlements.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_ipa", type=Path)
    parser.add_argument("output_ipa", type=Path)
    parser.add_argument("--app-group", required=True)
    args = parser.parse_args()
    try:
        prepare(args.input_ipa, args.output_ipa, args.app_group)
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"Signer preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

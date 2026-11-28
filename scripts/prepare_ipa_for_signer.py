#!/usr/bin/env python3
"""Bind an unsigned SFI IPA to a designated App Group, or inspect a signed IPA on macOS."""
import argparse
import fnmatch
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from verify_unsigned_ipa import analyze

GROUPS = "com.apple.security.application-groups"


def signed_matrix(path):
    bundles = analyze(path, None, signed=True)["bundles"]
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as tmp:
        for member in bundles:
            info = plistlib.loads(archive.read(member["info"]))
            exe = info["CFBundleExecutable"]
            if Path(exe).name != exe:
                raise ValueError("Invalid executable path")
            parent = member["info"].removesuffix("Info.plist")
            binary = Path(tmp, "executable")
            profile = Path(tmp, "profile")
            for dst, name in [(binary, parent + exe), (profile, parent + "embedded.mobileprovision")]:
                with archive.open(name) as source, dst.open("wb") as dest:
                    shutil.copyfileobj(source, dest)
            ent = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", binary], stderr=subprocess.DEVNULL))
            provision = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", profile]))["Entitlements"]
            app_id = ent.get("application-identifier", "")
            team = ent.get("com.apple.developer.team-identifier")
            if not team or team != provision.get("com.apple.developer.team-identifier") or not app_id or not app_id.endswith("." + member["bundle"]) or not fnmatch.fnmatchcase(app_id, provision.get("application-identifier", "")):
                raise ValueError("Signing identity mismatch in " + member["bundle"])
            signed_groups, allowed = ent.get(GROUPS, []), provision.get(GROUPS, [])
            if not isinstance(signed_groups, list) or not isinstance(allowed, list):
                raise ValueError("Invalid group entitlement in " + member["bundle"])
            member["rights"] = {g for g in signed_groups if isinstance(g, str) and valid_group(g) and g in allowed}
            member["team"] = team
            if member["extension_point"] in {None, "com.apple.networkextension.packet-tunnel", "com.apple.widgetkit-extension"}:
                key = "com.apple.developer.networking.networkextension"
                if any("packet-tunnel-provider" not in p.get(key, []) for p in (ent, provision)):
                    raise ValueError("Missing packet-tunnel-provider in " + member["bundle"])
    if len({m["team"] for m in bundles}) != 1:
        raise ValueError("Bundles signed by different teams")
    return bundles


def valid_group(group):
    return re.fullmatch(r"group\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*", group) is not None


def select(members, requested=None):
    common = set.intersection(*(m["rights"] for m in members))
    if requested:
        if requested not in common:
            raise ValueError("Designated group is not authorized in every signed target")
        return requested
    if len(common) == 1:
        return next(iter(common))
    declarations = {g for m in members for g in (m["group"], m["document_group"]) if g in common}
    if len(declarations) == 1:
        return declarations.pop()
    raise ValueError("Missing unique signing intent. Common groups: " + ", ".join(sorted(common)))


def prepare(source: Path, destination: Path, group: str) -> None:
    if not valid_group(group) or source.resolve() == destination.resolve():
        raise ValueError("Specify a registered group and a separate output IPA")
    metadata = {x["info"] for x in analyze(source, None)["bundles"]}
    fd, tmp = tempfile.mkstemp(dir=destination.parent, suffix=".ipa")
    os.close(fd)
    try:
        with zipfile.ZipFile(source) as src, zipfile.ZipFile(tmp, "w") as dest:
            for entry in src.infolist():
                if entry.filename not in metadata:
                    with src.open(entry) as input_file, dest.open(entry, "w") as output:
                        shutil.copyfileobj(input_file, output)
                    continue
                item = plistlib.loads(src.read(entry))
                item["AppGroupIdentifier"] = group
                ext = item.get("NSExtension", {})
                if ext.get("NSExtensionPointIdentifier") == "com.apple.fileprovider-nonui":
                    ext["NSExtensionFileProviderDocumentGroup"] = group
                dest.writestr(entry, plistlib.dumps(item, fmt=plistlib.FMT_BINARY))
        analyze(Path(tmp), None)
        os.replace(tmp, destination)
    finally:
        Path(tmp).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_ipa", nargs="?", type=Path)
    parser.add_argument("output_ipa", nargs="?", type=Path)
    parser.add_argument("--app-group", help="Full group designated for this app by the signing owner")
    parser.add_argument("--signed-reference", type=Path, help="Resolve/check group using a previous signed installation")
    parser.add_argument("--verify-signed", type=Path, help="Audit the final signed device IPA on macOS")
    args = parser.parse_args()
    if args.verify_signed:
        if args.input_ipa or args.output_ipa or args.signed_reference:
            parser.error("Verify one signed IPA at a time")
        members = signed_matrix(args.verify_signed)
        for m in members:
            print(m["bundle"], "signed+provisioned:", ",".join(sorted(m["rights"])), "declared:", m["group"])
        group = select(members)
        if args.app_group and group != args.app_group:
            raise ValueError("Runtime selection differs from the designated group")
        if next(m for m in members if m["extension_point"] == "com.apple.fileprovider-nonui")["document_group"] != group:
            raise ValueError("Final File Provider document group differs from selected group")
        print("All seven targets agree:", group)
        return
    if not args.input_ipa or not args.output_ipa or not (args.app_group or args.signed_reference):
        parser.error("Provide input and output IPA plus --signed-reference or --app-group")
    group = select(signed_matrix(args.signed_reference), args.app_group) if args.signed_reference else args.app_group
    prepare(args.input_ipa, args.output_ipa, group)
    print("Unsigned IPA prepared. Sign the host and all extensions for", group)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        sys.exit("Signing preflight failed: " + str(error))

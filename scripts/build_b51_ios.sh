#!/usr/bin/env bash
# Called by the companion CI with the verified b50 device and simulator framework.
set -euo pipefail
mkdir -p build/SourcePackages
python3 -m unittest discover -s scripts -p 'test_b51*.py' -v
packages=(-clonedSourcePackagesDirPath "$PWD/build/SourcePackages")
xcodebuild -resolvePackageDependencies -scheme SFI "${packages[@]}"
sim=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(x["udid"] for runtime, group in json.load(sys.stdin)["devices"].items() if ".iOS-" in runtime for x in group if x["isAvailable"] and x["name"].startswith("iPhone")))')
xcodebuild test -quiet -skipPackagePluginValidation "${packages[@]}" \
  -scheme SFI -configuration Debug -only-testing:SFUnitTests -parallel-testing-enabled NO \
  -resultBundlePath "$PWD/build/B51.xcresult" -destination "platform=iOS Simulator,id=$sim" ARCHS=arm64 CODE_SIGN_IDENTITY=-
xcrun xcresulttool get test-results summary --path build/B51.xcresult --format json > build/XCTestSummary.json
xcrun xcresulttool get test-results tests --path build/B51.xcresult --format json > build/test-list.json
python3 - <<'PY'
import json
from pathlib import Path
p = Path('build')
s = json.loads((p / 'XCTestSummary.json').read_bytes())
assert s['totalTestCount'] >= 1 and s['failedTests'] == 0 and s['result'] in ('Passed', 'Success'), s
tests = (p / 'test-list.json').read_text()
for suite in ['B51SigningTests', 'B51StorageTests', 'SigningCompatibilityTests', 'VPNStartupWaitPolicyTests']:
    assert suite in tests, suite
print(s)
PY
xcodebuild archive -quiet -skipPackagePluginValidation "${packages[@]}" -scheme SFI -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$PWD/build/SFI.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
cd build
mkdir -p Payload
cp -R SFI.xcarchive/Products/Applications/sing-box.app Payload/
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path('Payload/sing-box.app')
assert any(i.stat().st_size > 0 for i in (p / 'PlugIns/WidgetExtension.appex/Metadata.appintents').rglob('*') if i.is_file())
(p / 'LXBuildManifest.json').write_text(json.dumps(dict(build=51, appVersion="1.14.9", appleCommit=os.environ["APPLE_SHA"],
    preparedCoreTree=os.environ["CORE_TREE"], workflowCommit=os.environ["GITHUB_SHA"], b50Run=46012373148,
    coreVersion="LX.37", deliveryStatus="Physical iPhone acceptance pending"), indent=2))
PY
zip -qry SFI-b51-LX37-portable.ipa Payload
# Preserve the full original declaration for in-place upgrades of the working b50
# signing installation. Other signers can bind their own exact group before signing.
base="$RUNNER_TEMP/SFI-b50.ipa"
curl --fail --location --retry 3 -o "$base" https://github.com/eliassmail-dotcom/sing-box/releases/download/candidate-ios-b50-run-46012373148/SFI-lxpp-v1.14.9-b50-lx37-unsigned.ipa
echo "4be7adce07a3ac98180c94b8e6d220fbcde8ed9534a661403c4dfdda8fcd276f  $base" | shasum -a 256 -c -
group=$(python3 -c 'import sys,plistlib,zipfile; print(plistlib.loads(zipfile.ZipFile(sys.argv[1]).read("Payload/sing-box.app/Info.plist"))["AppGroupIdentifier"])' "$base")
python3 ../scripts/prepare_ipa_for_signer.py SFI-b51-LX37-portable.ipa SFI-b51-LX37-unsigned.ipa --app-group "$group"
unzip -tq SFI-b51-LX37-unsigned.ipa
python3 ../scripts/verify_unsigned_ipa.py SFI-b51-LX37-unsigned.ipa --build 51 | tee signing-preflight.json
shasum -a 256 SFI-b51-LX37-unsigned.ipa > SHA256SUMS

import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from prepare_ipa_for_signer import prepare, select
from verify_unsigned_ipa import POINTS, analyze


class SigningPackageTests(unittest.TestCase):
    def fixture(self, path, points=POINTS):
        with zipfile.ZipFile(path, "w") as archive:
            for idx, point in enumerate([None, *sorted(points)]):
                info = dict(CFBundleIdentifier="example.app" if not idx else "example.app.ext" + str(idx),
                            CFBundleExecutable="test", CFBundleVersion="51", CFBundleShortVersionString="1.14.9",
                            AppGroupIdentifier="group.baseline")
                directory = "Payload/Test.app/"
                if point:
                    if "appintents" in point:
                        directory += f"Extensions/{idx}.appex/"
                        info["EXAppExtensionAttributes"] = {"EXExtensionPointIdentifier": point}
                    else:
                        directory += f"PlugIns/{idx}.appex/"
                        info["NSExtension"] = {"NSExtensionPointIdentifier": point}
                    if "fileprovider" in point:
                        info["NSExtension"]["NSExtensionFileProviderDocumentGroup"] = "group.baseline"
                else:
                    info.update(UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True)
                archive.writestr(directory + "Info.plist", plistlib.dumps(info))
                archive.writestr(directory + "test", b"fixture")

    def test_generated_metadata_covers_extensionkit_and_plugins(self):
        with tempfile.TemporaryDirectory() as tmp:
            original, prepared = (Path(tmp) / n for n in ("in.ipa", "out.ipa"))
            self.fixture(original)
            prepare(original, prepared, "group.team.assigned")
            result = analyze(prepared, "51")
            self.assertEqual(result["bundle_count"], 7)
            self.assertTrue(all(b["group"] == "group.team.assigned" for b in result["bundles"]))
            self.assertEqual(next(b["document_group"] for b in result["bundles"] if b["document_group"]), "group.team.assigned")
            self.assertEqual(analyze(original, "51")["app_group_at_build"], "group.baseline")

    def test_missing_widget_fails_without_replacing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            original, prepared = (Path(tmp) / n for n in ("in.ipa", "out.ipa"))
            self.fixture(original, POINTS - {"com.apple.widgetkit-extension"})
            prepared.write_bytes(b"existing")
            with self.assertRaises(ValueError):
                prepare(original, prepared, "group.test")
            self.assertEqual(prepared.read_bytes(), b"existing")

    def test_signer_requires_full_designation_when_ambiguous(self):
        members = [{"rights": {"group.new.1", "group.new.2"}, "group": "group.old.2", "document_group": None} for _ in range(7)]
        with self.assertRaises(ValueError):
            select(members)
        self.assertEqual(select(members, "group.new.1"), "group.new.1")
        members[-1]["rights"] = {"group.new.2"}
        self.assertEqual(select(members), "group.new.2")
        with self.assertRaises(ValueError):
            select(members, "group.new.1")

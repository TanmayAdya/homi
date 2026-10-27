"""Regression checks for the packaged native scanner's manifest boundary."""

import unittest

from check_android_apk import native_capture_manifest_errors


MANIFEST = '''E: manifest (line=1)
  E: application (line=2)
    E: meta-data (line=3)
      A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.google.ar.core" (Raw: "com.google.ar.core")
      A: http://schemas.android.com/apk/res/android:value(0x01010024)="optional" (Raw: "optional")
    E: activity (line=6)
      A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.example.safe_at_home.BathroomScanActivity"
      A: http://schemas.android.com/apk/res/android:exported(0x01010010)=false
      A: http://schemas.android.com/apk/res/android:excludeFromRecents(0x01010017)=true
    E: activity (line=10)
      A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.google.ar.core.InstallActivity"
      A: http://schemas.android.com/apk/res/android:exported(0x01010010)=false
'''


class NativeCaptureManifestTest(unittest.TestCase):
    def test_private_optional_scanner_passes(self):
        self.assertEqual(native_capture_manifest_errors(MANIFEST), [])

    def test_exported_scanner_is_not_hidden_by_private_arcore_activity(self):
        changed = MANIFEST.replace("=false", "=true", 1)
        self.assertIn("Packaged bathroom scanner must explicitly be unexported",
                      native_capture_manifest_errors(changed))

    def test_missing_export_flag_is_not_inferred(self):
        changed = MANIFEST.replace(
            "      A: http://schemas.android.com/apk/res/android:exported(0x01010010)=false\n",
            "", 1,
        )
        self.assertIn("Packaged bathroom scanner must explicitly be unexported",
                      native_capture_manifest_errors(changed))

    def test_required_arcore_is_rejected(self):
        changed = MANIFEST.replace('="optional"', '="required"')
        self.assertIn("Packaged application must declare Google ARCore optional",
                      native_capture_manifest_errors(changed))

    def test_activity_metadata_cannot_replace_application_optional_declaration(self):
        changed = MANIFEST.replace("    E: meta-data", "    E: activity\n      E: meta-data")
        self.assertIn("Packaged application must declare Google ARCore optional",
                      native_capture_manifest_errors(changed))

    def test_missing_scan_activity_is_not_an_accepted_fallback(self):
        changed = MANIFEST.replace(".BathroomScanActivity", ".UnexpectedActivity")
        self.assertIn("Expected exactly one packaged bathroom scan activity",
                      native_capture_manifest_errors(changed))

    def test_scanner_cannot_appear_in_recents(self):
        changed = MANIFEST.replace(":excludeFromRecents(0x01010017)=true",
                                   ":excludeFromRecents(0x01010017)=false")
        self.assertIn("Packaged bathroom scanner must be excluded from recents",
                      native_capture_manifest_errors(changed))


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import hashlib
import os
import plistlib
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_SCRIPT = REPOSITORY_ROOT / "Scripts" / "package-app.sh"
IDENTITY = "Developer ID Application: Umbra Test (ABCDE12345)"
CERTIFICATE = b"gate6-test-leaf-certificate"
CERTIFICATE_SHA256 = hashlib.sha256(CERTIFICATE).hexdigest()
EMPTY_ENTITLEMENTS_SHA256 = hashlib.sha256(
    plistlib.dumps({}, fmt=plistlib.FMT_BINARY, sort_keys=True)
).hexdigest()


def write_executable(path: Path, contents: str) -> None:
    path.write_text(textwrap.dedent(contents).lstrip(), encoding="utf-8")
    path.chmod(0o755)


class PackageAppQualifyingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.app = self.root / "Umbra.app"
        self._create_app()
        self._create_tools()
        self.environment = os.environ | {
            "PATH": f"{self.tools}:{os.environ['PATH']}",
            "UMBRA_QUALIFYING_BUILD": "1",
            "CODE_SIGN_IDENTITY": IDENTITY,
            "UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256": CERTIFICATE_SHA256,
            "UMBRA_APPROVED_ENTITLEMENTS_SHA256": EMPTY_ENTITLEMENTS_SHA256,
            "STUB_CERTIFICATE_HEX": CERTIFICATE.hex(),
            "STUB_CERTIFICATE_SHA256": CERTIFICATE_SHA256,
            "STUB_CODE_SIGN_IDENTITY": IDENTITY,
            "STUB_LIPO_ARCHS": "arm64",
            "STUB_OTOOL_OUTPUT": "/usr/lib/libSystem.B.dylib",
            "STUB_RUNTIME_FLAGS": "flags=0x10000(runtime)",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _create_app(self) -> None:
        resources = self.app / "Contents" / "Resources"
        executable = self.app / "Contents" / "MacOS" / "Umbra"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"Mach-O fixture")
        executable.chmod(0o755)
        (self.app / "Contents" / "Info.plist").write_text("fixture", encoding="utf-8")
        for base in (resources, resources / "Umbra_UmbraApp.bundle"):
            localization = base / "en.lproj"
            localization.mkdir(parents=True)
            (localization / "Localizable.strings").write_text(
                "fixture", encoding="utf-8"
            )
            (localization / "InfoPlist.strings").write_text("fixture", encoding="utf-8")

    def _create_tools(self) -> None:
        write_executable(
            self.tools / "plutil",
            r"""
            #!/usr/bin/env python3
            import sys
            if "-lint" in sys.argv:
                raise SystemExit(0)
            key = sys.argv[sys.argv.index("-extract") + 1]
            values = {
                "CFBundleIdentifier": "app.umbra.Umbra",
                "NSBonjourServices.0": "_nvstream._tcp",
                "CFBundleDisplayName": "Umbra",
                "NSLocalNetworkUsageDescription": "network",
                "NSInputMonitoringUsageDescription": "input",
                "NSMicrophoneUsageDescription": "microphone",
            }
            print(values[key])
            """,
        )
        write_executable(
            self.tools / "otool",
            r"""
            #!/usr/bin/env python3
            import os
            print(os.environ["STUB_OTOOL_OUTPUT"])
            """,
        )
        write_executable(
            self.tools / "nm",
            r"""
            #!/usr/bin/env python3
            import os
            print(os.environ.get("STUB_NM_OUTPUT", ""), end="")
            """,
        )
        write_executable(
            self.tools / "lipo",
            r"""
            #!/usr/bin/env python3
            import os
            print(os.environ["STUB_LIPO_ARCHS"])
            """,
        )
        write_executable(
            self.tools / "security",
            r"""
            #!/usr/bin/env python3
            import os
            print("SHA-256 hash:", os.environ["STUB_CERTIFICATE_SHA256"].upper())
            print("SHA-1 hash:", "a" * 40)
            """,
        )
        write_executable(
            self.tools / "codesign",
            r"""
            #!/usr/bin/env python3
            import os
            import sys
            from pathlib import Path

            arguments = sys.argv[1:]
            if "--extract-certificates" in arguments:
                prefix = arguments[arguments.index("--extract-certificates") + 1]
                Path(prefix + "0").write_bytes(bytes.fromhex(os.environ["STUB_CERTIFICATE_HEX"]))
            elif "--entitlements" in arguments and ":-" in arguments:
                sys.stdout.buffer.write(bytes.fromhex(os.environ.get("STUB_ENTITLEMENTS_HEX", "")))
            elif "--verbose=4" in arguments:
                identity = os.environ["STUB_CODE_SIGN_IDENTITY"]
                flags = os.environ["STUB_RUNTIME_FLAGS"]
                print(f"Authority={identity}", file=sys.stderr)
                print("TeamIdentifier=ABCDE12345", file=sys.stderr)
                print(flags, file=sys.stderr)
            """,
        )

    def run_validation(self, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PACKAGE_SCRIPT), "--validate-only", str(self.app)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.environment | environment,
        )

    def test_valid_qualifying_package_emits_identity_and_entitlements_evidence(
        self,
    ) -> None:
        completed = self.run_validation()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            f"QUALIFYING_SIGNATURE_IDENTITY_SHA256={CERTIFICATE_SHA256}",
            completed.stdout,
        )
        self.assertIn(
            f"QUALIFYING_ENTITLEMENTS_SHA256={EMPTY_ENTITLEMENTS_SHA256}",
            completed.stdout,
        )

    def test_missing_or_ad_hoc_identity_is_rejected(self) -> None:
        for identity in ("", "-"):
            with self.subTest(identity=identity):
                completed = self.run_validation(CODE_SIGN_IDENTITY=identity)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("explicit non-ad-hoc", completed.stderr)

    def test_certificate_and_entitlements_mismatch_are_rejected(self) -> None:
        completed = self.run_validation(
            UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256="f" * 64
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("certificate frozen", completed.stderr)

        completed = self.run_validation(UMBRA_APPROVED_ENTITLEMENTS_SHA256="e" * 64)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("entitlements differ", completed.stderr)

    def test_missing_hardened_runtime_and_wrong_architecture_are_rejected(self) -> None:
        completed = self.run_validation(STUB_RUNTIME_FLAGS="flags=0x0(none)")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("hardened-runtime", completed.stderr)

        completed = self.run_validation(STUB_LIPO_ARCHS="x86_64")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("arm64-only", completed.stderr)

    def test_symlink_and_non_system_dependency_are_rejected(self) -> None:
        (self.app / "Contents" / "Resources" / "escape").symlink_to("/tmp")
        completed = self.run_validation()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("may not contain symlinks", completed.stderr)
        (self.app / "Contents" / "Resources" / "escape").unlink()

        completed = self.run_validation(
            STUB_OTOOL_OUTPUT="/opt/homebrew/lib/libssl.dylib"
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("non-system dynamic dependencies", completed.stderr)


if __name__ == "__main__":
    unittest.main()

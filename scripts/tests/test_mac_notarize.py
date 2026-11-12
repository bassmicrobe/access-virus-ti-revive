"""Mock the Apple tools: no certificates, keychain access, signing or network requests are made."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "mac-notarize-release.sh"
AUTH_VARS = ("DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_INSTALLER", "NOTARY_KEYCHAIN_PROFILE", "NOTARY_KEYCHAIN",
             "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH", "TIREVIVE_SOURCE_SHA")
MOCK = r'''#!/usr/bin/env python3
import json, os, plistlib, shutil, sys, zipfile
from pathlib import Path
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as f:
    f.write(json.dumps([tool, *args]) + "\n")
def info():
    return ('<?xml version="1.0"?><pkg-info identifier="example.tirevive" version="1.2.3" '
            'install-location="/" relocatable="false" auth="root" postinstall-action="none">'
            '<payload numberOfFiles="2" installKBytes="3"/><relocate/>'
            '<bundle-version/><upgrade-bundle/><scripts><postinstall file="postinstall"/></scripts></pkg-info>')
def raw_package(p, rebuilt=False):
    p.mkdir(parents=True)
    (p/"PackageInfo").write_text(info().replace('numberOfFiles="2"', 'numberOfFiles="70"') if rebuilt else info())
    (p/"Payload").write_bytes(b"rebuilt payload" if rebuilt else b"original payload")
    (p/"Bom").write_bytes(b"bom")
    (p/"Scripts").write_bytes(b"ORIGINAL-SCRIPTS")
def bundle(payload, relative, name, identifier):
    p = payload/relative
    (p/"Contents/MacOS").mkdir(parents=True)
    (p/"Contents/MacOS"/name).write_bytes(bytes.fromhex("cffaedfe") + b"mock Mach-O")
    (p/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable":name,"CFBundleIdentifier":identifier}))
    return p
def full_package(p):
    p.mkdir(parents=True)
    (p/"Distribution").write_text('ORIGINAL-DISTRIBUTION')
    c = p/"tirevive-component.pkg"
    c.mkdir()
    (c/"PackageInfo").write_text(info())
    payload = c/"Payload"
    payload.mkdir()
    bundle(payload, "Applications/TI Revive Control Center.app", "TI Revive Control Center", "example.cc")
    bundle(payload, "Library/Audio/Plug-Ins/VST3/TI Revive Virus Control.vst3", "TI Revive Virus Control", "example.vst")
    for suffix in ("", " (Snow)"):
        p = bundle(payload, "Library/Audio/Plug-Ins/Components/TI Revive Virus Control"+suffix+".component",
                   "TI Revive Virus Control"+suffix, "example.au"+suffix)
        bundle(payload, str(p.relative_to(payload)/"Contents/Resources/plugin.vst3"), "TI Revive Virus Control", "example.inner"+suffix)
        (p/"Contents/._metadata").write_bytes(b"extraction metadata")
    support = payload/"Library/Application Support/TI Revive"
    support.mkdir(parents=True)
    for n in ("vtibroker", "tirevive-cc"):
        (support/n).write_bytes(bytes.fromhex("cffaedfe") + b"mock Mach-O")
if tool == "ditto":
    if args[:2] == ["-x", "-k"]:
        with zipfile.ZipFile(args[2]) as z: z.extractall(args[3])
    else:
        root, out = map(Path, args[-2:])
        with zipfile.ZipFile(out, "w") as z:
            for p in root.rglob("*"):
                if p.is_file(): z.write(p, str(Path(root.name)/p.relative_to(root)))
elif tool == "pkgutil":
    if args[0] == "--expand-full": full_package(Path(args[2]))
    elif args[0] == "--expand":
        dest = Path(args[2])
        if Path(args[1]).read_bytes() == b"REBUILT": raw_package(dest, True)
        else:
            dest.mkdir(); (dest/"Distribution").write_text("ORIGINAL-DISTRIBUTION")
            raw_package(dest/"tirevive-component.pkg")
    elif args[0] == "--flatten":
        p = Path(args[1]); c = p/"tirevive-component.pkg"
        Path(args[2]).write_text(json.dumps({"distribution":(p/"Distribution").read_text(),
            "scripts":(c/"Scripts").read_text(),"package_info":(c/"PackageInfo").read_text(),
            "payload":(c/"Payload").read_text()}))
    elif args[0] == "--check-signature": print("Developer ID Installer: PRIVATE TEST IDENTITY")
elif tool == "pkgbuild": Path(args[-1]).write_bytes(b"REBUILT")
elif tool == "lipo": print("arm64 x86_64")
elif tool == "file":
    p = args[-1]
    executable = ".app/Contents/MacOS/" in p or p.endswith(("/vtibroker","/tirevive-cc"))
    print("Mach-O 64-bit " + ("executable" if executable else "bundle"))
elif tool == "codesign":
    if "--display" in args:
        print("Authority=Developer ID Application: PRIVATE TEST IDENTITY", file=sys.stderr)
        print("flags=0x10000(runtime)", file=sys.stderr)
elif tool == "productsign":
    shutil.copyfile(args[-2], args[-1]); print("PRIVATE TEST IDENTITY", file=sys.stderr)
elif tool == "lsbom": print("./file\t100644\t"+os.environ.get("MOCK_OWNER","0/0")+"\t42\t123")
elif tool == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        print(json.dumps({"id":"11111111-1111-1111-1111-111111111111","status":os.environ.get("MOCK_NOTARY_STATUS","Accepted")}))
    elif args[:2] == ["notarytool", "log"]:
        Path(args[-1]).write_text(json.dumps({"issues":json.loads(os.environ.get("MOCK_NOTARY_ISSUES","[]"))}))
elif tool == "spctl" and os.environ.get("MOCK_SPCTL_FAIL"): sys.exit(3)
'''


class MacNotarizeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tirevive-notary-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock.py"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ("ditto", "pkgutil", "pkgbuild", "codesign", "productsign", "xcrun", "spctl", "lipo", "file", "lsbom"):
            (self.bin / name).symlink_to(mock)
        self.source = self.root / "input.zip"
        with zipfile.ZipFile(self.source, "w") as z:
            z.writestr("TI-Revive-1.2.3-mac/TI Revive.pkg", "PKG_FIXTURE")
            z.writestr("TI-Revive-1.2.3-mac/README-mac.txt", "README retained")
        self.output = self.root / "signed.zip"
        self.calls_file = self.root / "calls.jsonl"
        self.env = {k:v for k,v in os.environ.items() if k not in AUTH_VARS}
        self.env.update(PATH=str(self.bin)+os.pathsep+os.environ.get("PATH", ""), TMPDIR=str(self.root),
                        DEVELOPER_ID_APPLICATION="Developer ID Application: PRIVATE TEST IDENTITY",
                        DEVELOPER_ID_INSTALLER="Developer ID Installer: PRIVATE TEST IDENTITY",
                        NOTARY_KEYCHAIN_PROFILE="PRIVATE_TEST_PROFILE", MOCK_CALLS=str(self.calls_file))

    def execute(self):
        return subprocess.run(["bash", str(SCRIPT), str(self.source), str(self.output)], env=self.env,
                              capture_output=True, text=True)

    def calls(self):
        return [json.loads(x) for x in self.calls_file.read_text().splitlines()] if self.calls_file.exists() else []

    def report(self):
        return json.loads(Path(str(self.output)+".notarization.json").read_text())

    def test_signs_inside_out_preserves_metadata_and_authenticates_once(self):
        original = hashlib.sha256(self.source.read_bytes()).hexdigest()
        keychain = self.root / "private.keychain-db"
        keychain.write_text("mock")
        self.env["NOTARY_KEYCHAIN"] = str(keychain)
        self.env["TIREVIVE_SOURCE_SHA"] = "a"*40
        r = self.execute()
        self.assertEqual(r.returncode, 0, r.stderr)
        record = self.report()
        self.assertEqual(record["status"], "accepted")
        self.assertTrue(record["clean"])
        self.assertEqual(record["code_signing"]["mach_o_files"], 8)
        self.assertEqual(record["code_signing"]["bundles"], 6)
        self.assertEqual(record["source_sha"], "a"*40)
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), original)
        calls = self.calls()
        signing = [c for c in calls if c[0] == "codesign" and "--sign" in c]
        self.assertEqual(len(signing), 14)
        self.assertTrue(all("--deep" not in c for c in signing))
        for c in signing:
            self.assertIn("--timestamp", c)
            if "--entitlements" in c:
                self.assertTrue(c[-1].endswith((".app", "/vtibroker", "/tirevive-cc")) or ".app/Contents/MacOS/" in c[-1])
        paths = [c[-1] for c in signing]
        for path in paths:
            if path.endswith(".component"):
                self.assertLess(paths.index(path+"/Contents/Resources/plugin.vst3"), paths.index(path))
        submits = [c for c in calls if c[:3] == ["xcrun","notarytool","submit"]]
        self.assertEqual(len(submits), 1)
        self.assertIn("--keychain", submits[0])
        self.assertTrue(any(c[:3] == ["xcrun","notarytool","log"] for c in calls))
        with zipfile.ZipFile(self.output) as z:
            pkg = json.loads(z.read("TI-Revive-1.2.3-mac/TI Revive.pkg"))
            guide = z.read("TI-Revive-1.2.3-mac/README-mac.txt").decode()
            self.assertIn("Developer ID signed and Apple notarized (Accepted)", guide)
            self.assertIn("/Library/Application Support/TI Revive/Set up", guide)
            self.assertNotIn("not signed", guide)
            self.assertNotIn("Open Anyway", guide)
        self.assertTrue(record["signed_distribution_guide"])
        self.assertEqual(pkg["distribution"], "ORIGINAL-DISTRIBUTION")
        self.assertEqual(pkg["scripts"], "ORIGINAL-SCRIPTS")
        self.assertIn('relocatable="false"', pkg["package_info"])
        self.assertIn('numberOfFiles="70"', pkg["package_info"])
        self.assertEqual(pkg["payload"], "rebuilt payload")
        public = json.dumps(record)+r.stdout+r.stderr
        for private in ("PRIVATE TEST IDENTITY", "PRIVATE_TEST_PROFILE", str(keychain), str(self.root)):
            self.assertNotIn(private, public)
        self.assertFalse(list(self.root.glob("tirevive-notary.*")))

    def test_asc_authentication_without_keychain(self):
        del self.env["NOTARY_KEYCHAIN_PROFILE"]
        key = self.root / "private.p8"
        key.write_text("synthetic fixture, not a private key")
        self.env.update(ASC_KEY_ID="ABCDEF1234", ASC_ISSUER_ID="22222222-2222-2222-2222-222222222222", ASC_PRIVATE_KEY_PATH=str(key))
        r = self.execute()
        self.assertEqual(r.returncode, 0, r.stderr)
        submit = next(c for c in self.calls() if c[:3] == ["xcrun","notarytool","submit"])
        self.assertIn("--issuer", submit)
        self.assertNotIn("--keychain-profile", submit)
        self.assertNotIn(str(key), json.dumps(self.report()))

    def test_missing_installer_identity_fails_before_tools(self):
        del self.env["DEVELOPER_ID_INSTALLER"]
        r = self.execute()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.output.exists())

    def test_incomplete_or_mixed_authentication_fails_before_tools(self):
        self.env["ASC_KEY_ID"] = "ABCDEF1234"
        r = self.execute()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_rejection_keeps_issue_record_without_publishing(self):
        self.env["MOCK_NOTARY_STATUS"] = "Invalid"
        self.env["MOCK_NOTARY_ISSUES"] = json.dumps([{"severity":"error","code":123,"path":"Payload/example","message":"bad code"}])
        r = self.execute()
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.report()["notary"]["issue_counts"], {"error":1})
        self.assertFalse(any(c[:2] == ["xcrun","stapler"] for c in self.calls()))

    def test_accepted_warnings_are_saved_and_redacted(self):
        self.env["MOCK_NOTARY_ISSUES"] = json.dumps([{"severity":"warning","code":456,"path":"/Users/SecretGuy/work/code", "message":"PRIVATE_TEST_PROFILE: Developer ID Application: PRIVATE TEST IDENTITY"}])
        r = self.execute()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.report()["status"], "accepted_with_warnings")
        self.assertFalse(self.report()["clean"])
        issues = Path(str(self.output)+".notary-issues.json").read_text()
        self.assertNotIn("SecretGuy", issues)
        self.assertNotIn("PRIVATE_TEST_PROFILE", issues)
        self.assertNotIn("PRIVATE TEST IDENTITY", issues)

    def test_gatekeeper_failure_does_not_publish(self):
        self.env["MOCK_SPCTL_FAIL"] = "1"
        r = self.execute()
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.report()["phase"], "Gatekeeper assessment")

    def test_payload_ownership_must_remain_root(self):
        self.env["MOCK_OWNER"] = "501/20"
        r = self.execute()
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(c[:3] == ["xcrun","notarytool","submit"] for c in self.calls()))

    def test_existing_output_is_never_overwritten(self):
        self.output.write_bytes(b"keep")
        r = self.execute()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"keep")
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()

#!/bin/bash
# Sign and notarize an existing TI Revive macOS release ZIP; never modifies the input or installs anything.
# Required: DEVELOPER_ID_APPLICATION, DEVELOPER_ID_INSTALLER, and exactly one authentication method:
#   NOTARY_KEYCHAIN_PROFILE [NOTARY_KEYCHAIN], or ASC_KEY_ID + ASC_ISSUER_ID + ASC_PRIVATE_KEY_PATH.
# Usage: mac-notarize-release.sh INPUT.zip OUTPUT.zip
# Optional provenance: TIREVIVE_SOURCE_SHA (40 hex digits). Records contain no signing/authentication identities.
set +x
set -euo pipefail
umask 077
if [ "$#" -ne 2 ]; then
    echo "usage: mac-notarize-release.sh INPUT.zip OUTPUT.zip" >&2
    exit 2
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tirevive-notary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$1" "$2" "$WORK" <<'PY'
import collections
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
import zipfile


class Failure(Exception):
    pass


work = Path(sys.argv[3])
record = {"schema_version": 1, "status": "failed", "clean": False}
phase = "configuration"
report = issue_report = None
issues = []
raw_log = 0
tools = {}


def fail(message):
    raise Failure(message)


def run(command, *args, check=True):
    global raw_log
    # Raw Apple output can include certificate names, account data and temporary/private paths. Keep it private.
    r = subprocess.run([tools.get(command, command), *map(str, args)], capture_output=True, text=True, errors="replace")
    raw_log += 1
    (work / ("tool-%03d.log" % raw_log)).write_text(r.stdout + r.stderr)
    if check and r.returncode:
        fail(phase + " failed (tool exit %d)" % r.returncode)
    return r


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def publish(source, dest):
    # Exclusive creation also protects against a concurrent run writing the same release.
    created = False
    try:
        with dest.open("xb") as out, source.open("rb") as src:
            created = True
            shutil.copyfileobj(src, out)
            out.flush()
            os.fsync(out.fileno())
        dest.chmod(0o644)
    except BaseException:
        if created:
            dest.unlink(missing_ok=True)
        raise


def safe_issue(value):
    if not isinstance(value, str):
        return ""
    for secret in private_values:
        if secret:
            value = value.replace(secret, "[redacted]")
    value = re.sub(r"/(?:Users|private|tmp|Volumes)/[^\s\"<>]+", "[private-path]", value)
    return re.sub(r"Developer ID (?:Application|Installer):[^\n\"]+", "[signing identity]", value)


def main():
    global phase, report, issue_report, issues, private_values
    source, output = (Path(x).expanduser().resolve() for x in sys.argv[1:3])
    if not source.is_file() or source.suffix.lower() != ".zip":
        fail("input must be an existing release ZIP")
    if output == source or output.exists() or output.suffix.lower() != ".zip":
        fail("output must be a different, nonexistent ZIP")
    report = Path(str(output) + ".notarization.json")
    issue_report = Path(str(output) + ".notary-issues.json")
    if report.exists() or issue_report.exists():
        fail("notarization records already exist; choose a fresh output")
    app_id = os.environ.get("DEVELOPER_ID_APPLICATION", "").strip()
    installer_id = os.environ.get("DEVELOPER_ID_INSTALLER", "").strip()
    if not app_id or app_id == "-":
        fail("a Developer ID Application identity is required")
    if not installer_id or installer_id == "-":
        fail("a Developer ID Installer identity is required")
    profile = os.environ.get("NOTARY_KEYCHAIN_PROFILE", "").strip()
    keychain = os.environ.get("NOTARY_KEYCHAIN", "").strip()
    asc = [os.environ.get(k, "").strip() for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH")]
    if profile and any(asc):
        fail("choose keychain-profile or App Store Connect authentication, not both")
    if keychain and not profile:
        fail("NOTARY_KEYCHAIN requires NOTARY_KEYCHAIN_PROFILE")
    if profile:
        auth = ["--keychain-profile", profile]
        if keychain:
            if not Path(keychain).is_file():
                fail("the specified notary keychain is unavailable")
            auth += ["--keychain", keychain]
    elif all(asc):
        if not re.fullmatch(r"[A-Za-z0-9]{10}", asc[0]) or not Path(asc[2]).is_file():
            fail("App Store Connect key configuration is invalid or unavailable")
        try:
            uuid.UUID(asc[1])
        except ValueError:
            fail("App Store Connect issuer configuration is invalid")
        auth = ["--key", asc[2], "--key-id", asc[0], "--issuer", asc[1]]
    else:
        fail("complete notary authentication is required")
    source_sha = os.environ.get("TIREVIVE_SOURCE_SHA", "").strip()
    if source_sha and not re.fullmatch(r"[0-9a-fA-F]{40}", source_sha):
        fail("TIREVIVE_SOURCE_SHA must be a full 40-digit Git commit")
    private_values = [app_id, installer_id, profile, keychain, *asc, str(source), str(output), str(work)]
    for name in ("ditto", "pkgutil", "pkgbuild", "codesign", "productsign", "xcrun", "spctl", "lipo", "file", "lsbom"):
        tools[name] = shutil.which(name)
        if not tools[name]:
            fail("required macOS packaging tools are unavailable")
    output.parent.mkdir(parents=True, exist_ok=True)
    record.update(input_sha256=digest(source), source_sha=source_sha or None)

    phase = "release expansion"
    with zipfile.ZipFile(source) as z:
        if sum(i.file_size for i in z.infolist()) > 1024 * 1024 * 1024:
            fail("release ZIP is unexpectedly large")
        for i in z.infolist():
            p = Path(i.filename)
            if p.is_absolute() or ".." in p.parts or stat.S_ISLNK(i.external_attr >> 16) or i.flag_bits & 1:
                fail("release ZIP contains an unsafe entry")
    stage = work / "release"
    run("ditto", "-x", "-k", source, stage)
    packages = [p for p in stage.rglob("*.pkg") if p.is_file()]
    if len(packages) != 1:
        fail("release must contain exactly one flat installer package")
    package = packages[0]
    raw, expanded = work / "raw", work / "expanded"
    run("pkgutil", "--expand", package, raw)
    run("pkgutil", "--expand-full", package, expanded)
    components = [p.parent for p in expanded.rglob("PackageInfo") if (p.parent / "Payload").is_dir()]
    if not components:
        fail("installer contains no component payload")
    code = []
    bundles = []
    magic = {bytes.fromhex(x) for x in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    for component in components:
        payload = component / "Payload"
        for p in payload.rglob("._*"):
            if p.is_file():
                p.unlink() # archive extraction metadata must be removed before sealing bundle resources
        for p in payload.rglob("*"):
            if p.is_symlink():
                if not p.resolve().is_relative_to(payload.resolve()):
                    fail("payload contains an external symbolic link")
                continue
            if p.name in {"Access Music", "Virus Control.bundle", "Virus Control.dll", "firmware.bin", "remotedevice.xml", "remotedevicePR.xml"}:
                fail("installer unexpectedly contains Access resources")
            if p.is_file():
                with p.open("rb") as f:
                    if f.read(4) not in magic:
                        continue
                archs = run("lipo", "-archs", p).stdout.strip().split()
                executable = "executable" in run("file", "-b", p).stdout.lower()
                code.append((p, archs, executable))
            elif p.is_dir() and p.suffix in {".app", ".vst3", ".component", ".framework", ".xpc", ".bundle"}:
                info = next((x for x in (p / "Contents/Info.plist", p / "Resources/Info.plist") if x.is_file()), None)
                if info:
                    meta = plistlib.loads(info.read_bytes())
                    if meta.get("CFBundleExecutable"):
                        bundles.append((p, info, info.read_bytes(), p.suffix in {".app", ".xpc"}))
    if not code or not bundles:
        fail("installer contains no identifiable TI Revive code")

    phase = "code signing"
    empty = work / "entitlements.plist"
    empty.write_bytes(plistlib.dumps({}))
    def sign(path, executable):
        args = ["--force", "--sign", app_id, "--timestamp", "--preserve-metadata=identifier"]
        if executable:
            args += ["--options", "runtime", "--entitlements", empty]
        run("codesign", *args, path)
        shown = run("codesign", "--display", "--verbose=4", path)
        description = shown.stdout + shown.stderr
        if "Authority=Developer ID Application:" not in description:
            fail("code was not signed with Developer ID Application")
        if executable and not any("flags=" in line and "(runtime)" in line for line in description.splitlines()):
            fail("main executable does not have hardened runtime")
    for p, _, executable in sorted(code, key=lambda x: len(x[0].parts), reverse=True):
        sign(p, executable)
    for p, _, _, executable in sorted(bundles, key=lambda x: len(x[0].parts), reverse=True):
        sign(p, executable)
    for p, archs, _ in code:
        if run("lipo", "-archs", p).stdout.strip().split() != archs:
            fail("code architectures changed while signing")
        run("codesign", "--verify", "--strict", p)
    for p, info, original, _ in bundles:
        if info.read_bytes() != original:
            fail("bundle metadata changed while signing")
        run("codesign", "--verify", "--deep", "--strict", p)
    record["code_signing"] = {"mach_o_files": len(code), "bundles": len(bundles),
                              "architectures": sorted({a for _, aa, _ in code for a in aa}),
                              "developer_id_application": True, "main_hardened_runtime": True,
                              "timestamp": True, "bundle_metadata_preserved": True}

    phase = "installer reconstruction"
    # --flatten-full changes ownership to the unpacking user and can add AppleDouble files. Rebuild only each
    # Payload/Bom with pkgbuild, while preserving the original raw PackageInfo attributes, scripts and Distribution.
    for n, component in enumerate(components):
        relative = component.relative_to(expanded)
        original = raw / relative
        original_info = ET.parse(original / "PackageInfo")
        root = original_info.getroot()
        if not root.get("identifier") or not root.get("version"):
            fail("component package metadata is incomplete")
        built, rebuilt = work / ("component-%d.pkg" % n), work / ("component-%d" % n)
        run("pkgbuild", "--root", component / "Payload", "--identifier", root.get("identifier"),
            "--version", root.get("version"), "--install-location", root.get("install-location", "/"),
            "--ownership", "recommended", built)
        run("pkgutil", "--expand", built, rebuilt)
        owners = run("lsbom", "-l", "-f", rebuilt / "Bom").stdout.splitlines()
        if not owners or any(len(row.split("\t")) < 3 or row.split("\t")[2] != "0/0" for row in owners):
            fail("rebuilt payload ownership is not root/wheel")
        for name in ("Payload", "Bom"):
            shutil.copyfile(rebuilt / name, original / name)
        old_stats, new_stats = root.find("payload"), ET.parse(rebuilt / "PackageInfo").getroot().find("payload")
        if old_stats is None or new_stats is None:
            fail("component payload statistics are missing")
        old_stats.attrib.clear()
        old_stats.attrib.update(new_stats.attrib)
        original_info.write(original / "PackageInfo", encoding="utf-8", xml_declaration=True)
    unsigned, signed = work / "unsigned.pkg", work / "signed.pkg"
    run("pkgutil", "--flatten", raw, unsigned)
    run("productsign", "--sign", installer_id, "--timestamp", unsigned, signed)
    checked = run("pkgutil", "--check-signature", signed)
    if "Developer ID Installer:" not in checked.stdout + checked.stderr:
        fail("installer was not signed with Developer ID Installer")
    record["installer_signing"] = {"developer_id_installer": True, "root_ownership": True,
                                   "scripts_and_distribution_preserved": True}

    phase = "notary submission"
    submission = run("xcrun", "notarytool", "submit", signed, *auth, "--wait", "--output-format", "json", check=False)
    try:
        submitted = json.loads(submission.stdout)
        submission_id = str(uuid.UUID(submitted["id"]))
        status = submitted["status"]
    except (ValueError, KeyError, TypeError):
        fail("notary submission did not return a valid result")
    record["notary"] = {"submission_id": submission_id, "status": status}
    phase = "notary log retrieval"
    log_path = work / "notary-log.json"
    run("xcrun", "notarytool", "log", submission_id, *auth, log_path)
    log = json.loads(log_path.read_text())
    log_issues = log.get("issues") or []
    if not isinstance(log_issues, list):
        fail("notary log has an invalid issues field")
    for issue in log_issues:
        cleaned = {k: safe_issue(issue.get(k)) for k in ("severity", "path", "message", "docUrl", "architecture")}
        cleaned["code"] = issue.get("code") if isinstance(issue.get("code"), int) else safe_issue(issue.get("code"))
        issues.append(cleaned)
    counts = collections.Counter(i["severity"].lower() for i in issues)
    record["notary"]["issue_counts"] = dict(counts)
    if submission.returncode or status != "Accepted" or counts.get("error", 0):
        fail("Apple did not accept a cleanly signed installer; inspect the issue record")
    phase = "ticket stapling"
    run("xcrun", "stapler", "staple", signed)
    run("xcrun", "stapler", "validate", signed)
    phase = "Gatekeeper assessment"
    run("spctl", "--assess", "--type", "install", "--verbose=4", signed)
    phase = "release creation"
    shutil.copyfile(signed, package)
    roots = list(stage.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        fail("release ZIP must have one top-level directory")
    # The unsigned upstream archive says "not signed" and suggests Gatekeeper overrides. Replace that guide
    # only in the notarized output; the input, installer payload/scripts, license and notices stay untouched.
    (roots[0] / "README-mac.txt").write_text(
        "TI Revive - bassmicrobe fork for macOS\n"
        "=====================================\n\n"
        "This package is Developer ID signed and Apple notarized (Accepted).\n"
        "The final TI Revive.pkg has its notarization ticket stapled.\n"
        "Loose .command files are not individually notarized or stapled.\n"
        "Source commit: " + (source_sha or "see build provenance") + "\n\n"
        "Install\n"
        "1. Install TI Revive.pkg (macOS 14.4+, including macOS 27; arm64 and Intel).\n"
        "2. Run /Library/Application Support/TI Revive/Set up Access Virus TI files.command.\n"
        "   When asked, drag your own Access Virus TI Software Suite .pkg into Terminal.\n"
        "   To keep the original Access plug-ins, answer N to their removal prompt.\n"
        "3. Connect the Virus TI by USB and use TI Revive Virus Control in your AU/VST3 host.\n"
        "   Allow the host's microphone permission for USB audio. Save pending edits first.\n"
        "   Avoid an all-plug-in scan when other products request authorization.\n\n"
        "Verification (no installation):\n"
        "  pkgutil --check-signature 'TI Revive.pkg'\n"
        "  xcrun stapler validate 'TI Revive.pkg'\n"
        "  spctl --assess --type install --verbose=4 'TI Revive.pkg'\n\n"
        "Setup, rollback, issue status and notarization records:\n"
        "  https://github.com/bassmicrobe/access-virus-ti-revive\n"
        "Original TI Revive project:\n"
        "  https://github.com/derpsn/access-virus-ti-revive\n\n"
        "Read LICENSE and THIRD-PARTY-NOTICES.txt. No Access resources or firmware are included.\n"
        "Not affiliated with Access Music or Kemper. Firmware/flash updates are unsupported.\n",
        encoding="utf-8")
    record["signed_distribution_guide"] = True
    final_zip = work / "notarized.zip"
    run("ditto", "-c", "-k", "--keepParent", roots[0], final_zip)
    publish(final_zip, output)
    record.update(status="accepted_with_warnings" if issues else "accepted", clean=not issues,
                  output_sha256=digest(output), ticket_stapled=True, gatekeeper_install_assessment=True)
    phase = "complete"


exit_code = 0
try:
    main()
except KeyboardInterrupt:
    exit_code = 130
    record["failure"] = "interrupted"
    print("notarization interrupted", file=sys.stderr)
except Exception as e:
    exit_code = 1
    message = str(e) if isinstance(e, Failure) else phase + " failed"
    record["failure"] = message
    print(message, file=sys.stderr)
finally:
    record["phase"] = phase
    if report and issue_report and report.parent.is_dir() and not report.exists() and not issue_report.exists():
        issue_report.write_text(json.dumps({"issues": issues}, indent=2) + "\n")
        report.write_text(json.dumps(record, indent=2) + "\n")
if not exit_code:
    print("notarization accepted; ticket and Gatekeeper assessment verified" +
          ("; warnings are recorded" if issues else ""))
sys.exit(exit_code)
PY

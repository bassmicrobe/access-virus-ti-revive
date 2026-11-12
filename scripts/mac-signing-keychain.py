#!/usr/bin/env python3
"""CI-only ephemeral signing keychain; passwords never enter subprocess argv.

Usage: mac-signing-keychain.py init|cleanup PRIVATE_DIRECTORY
init reads the P12/password and ASC private key from environment secrets. It appends
only public certificate fingerprints and the private-key *path* to GITHUB_ENV.
cleanup is idempotent, restores the previous search list and removes private files.
Do not use this against an existing keychain or a shared directory.
"""
import base64
import ctypes as C
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys


class SigningError(Exception):
    pass


class ImportParameters(C.Structure):
    _fields_ = [("version", C.c_uint32), ("flags", C.c_uint32),
                ("passphrase", C.c_void_p), ("alertTitle", C.c_void_p),
                ("alertPrompt", C.c_void_p), ("accessRef", C.c_void_p),
                ("keyUsage", C.c_void_p), ("keyAttributes", C.c_void_p)]


def public_tool(arguments, operation):
    # Only public arguments reach native tools. Keep credential environments out,
    # capture potentially identifying diagnostics and report a fixed error instead.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MACOS_SIGNING_", "ASC_"))}
    result = subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=30)
    if result.returncode:
        raise SigningError(f"Could not {operation}")
    return result.stdout


class Security:
    def __init__(self):
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.sec = C.CDLL("/System/Library/Frameworks/Security.framework/Security")
        p, pp, u32 = C.c_void_p, C.POINTER(C.c_void_p), C.c_uint32
        for name, result, arguments in [
            ("CFStringCreateWithBytes", p, [p, p, C.c_long, u32, C.c_ubyte]),
            ("CFDataCreate", p, [p, p, C.c_long]),
            ("CFArrayCreate", p, [p, C.POINTER(p), C.c_long, p]),
            ("CFArrayGetCount", C.c_long, [p]),
            ("CFArrayGetValueAtIndex", p, [p, C.c_long]),
            ("CFRelease", None, [p]),
        ]:
            fn = getattr(self.cf, name)
            fn.restype, fn.argtypes = result, arguments
        for name, arguments in [
            ("SecKeychainSetUserInteractionAllowed", [C.c_ubyte]),
            ("SecKeychainCopySearchList", [pp]),
            ("SecKeychainGetPath", [p, C.POINTER(u32), p]),
            ("SecKeychainOpen", [C.c_char_p, pp]),
            ("SecKeychainSetSearchList", [p]),
            ("SecKeychainCreate", [C.c_char_p, u32, p, C.c_ubyte, p, pp]),
            ("SecKeychainUnlock", [p, u32, p, C.c_ubyte]),
            ("SecKeychainDelete", [p]),
            ("SecTrustedApplicationCreateFromPath", [C.c_char_p, pp]),
            ("SecAccessCreate", [p, p, pp]),
            ("SecItemImport", [p, p, C.POINTER(u32), C.POINTER(u32), u32,
                               C.POINTER(ImportParameters), p, pp]),
            ("SecKeychainSearchCreateFromAttributes", [p, u32, p, pp]),
            ("SecKeychainSearchCopyNext", [p, pp]),
            ("SecKeychainItemCopyAccess", [p, pp]),
            ("SecACLCopyContents", [p, pp, pp, C.POINTER(u32)]),
            ("SecACLSetContents", [p, p, p, u32]),
            ("SecKeychainItemSetAccessWithPassword", [p, p, u32, p]),
        ]:
            try:
                fn = getattr(self.sec, name)
            except AttributeError:
                raise SigningError("Required Security API is unavailable; no insecure CLI fallback") from None
            fn.restype, fn.argtypes = C.c_int32, arguments
        self.sec.SecAccessCopyMatchingACLList.restype = p
        self.sec.SecAccessCopyMatchingACLList.argtypes = [p, p]
        self.owned = []
        self.check(self.sec.SecKeychainSetUserInteractionAllowed(False), "disable prompts")

    @staticmethod
    def check(status, operation):
        if status:
            # OSStatus is safe; system error text can include item names or paths.
            raise SigningError(f"Security API could not {operation} (OSStatus {status})")

    def own(self, value):
        if not value:
            raise SigningError("Security API returned an empty reference")
        self.owned.append(value)
        return value

    def out(self, function, operation, *args):
        result = C.c_void_p()
        self.check(function(*args, C.byref(result)), operation)
        return self.own(result.value)

    def string(self, value):
        raw = value.encode("utf-8")
        return self.own(self.cf.CFStringCreateWithBytes(None, raw, len(raw), 0x08000100, False))

    def array(self, refs):
        # NULL callbacks are enough: self.owned keeps the referenced objects alive.
        values = (C.c_void_p * len(refs))(*refs)
        return self.own(self.cf.CFArrayCreate(None, values, len(refs), None))

    def search_paths(self):
        refs = self.out(self.sec.SecKeychainCopySearchList, "read search list")
        paths = []
        for i in range(self.cf.CFArrayGetCount(refs)):
            ref = self.cf.CFArrayGetValueAtIndex(refs, i)
            length, path = C.c_uint32(16384), C.create_string_buffer(16384)
            self.check(self.sec.SecKeychainGetPath(ref, C.byref(length), path), "read keychain path")
            paths.append(os.fsdecode(path.value))
        return paths

    def set_search_paths(self, paths):
        refs = [self.out(self.sec.SecKeychainOpen, "open search-list keychain", os.fsencode(path))
                for path in paths]
        self.check(self.sec.SecKeychainSetSearchList(self.array(refs)), "restore search list")

    def create_and_import(self, path, p12, password):
        keychain_password = secrets.token_urlsafe(48).encode("ascii")
        keychain = self.out(self.sec.SecKeychainCreate, "create temporary keychain",
                            os.fsencode(path), len(keychain_password), keychain_password, False, None)
        self.check(self.sec.SecKeychainUnlock(keychain, len(keychain_password), keychain_password, True),
                   "unlock temporary keychain")
        # The Security API setting can require a GUI authorization from Python.
        # Apple's signed tool sets only a public timeout; no password is in argv.
        public_tool(["/usr/bin/security", "set-keychain-settings", "-ut", "7200", str(path)],
                    "set temporary keychain lifetime")
        apps = [self.out(self.sec.SecTrustedApplicationCreateFromPath, "authorize signing tool", tool)
                for tool in (b"/usr/bin/codesign", b"/usr/bin/productsign", b"/usr/bin/productbuild")]
        access = self.out(self.sec.SecAccessCreate, "create signing ACL",
                          self.string("TI Revive CI signing"), self.array(apps))
        parameters = ImportParameters(0, 0, self.string(password), None, None, access, None, None)
        data = self.own(self.cf.CFDataCreate(None, p12, len(p12)))
        fmt, kind = C.c_uint32(12), C.c_uint32(5)  # kSecFormatPKCS12 / kSecItemTypeAggregate
        self.out(self.sec.SecItemImport, "import signing identities", data, None,
                 C.byref(fmt), C.byref(kind), 0, C.byref(parameters), keychain)
        self.allow_apple_signing_tools(keychain, keychain_password)

    def allow_apple_signing_tools(self, keychain, password):
        # Modern macOS also checks partition ACLs. This follows Apple's SecurityTool
        # set-key-partition-list implementation, but supplies the password in memory.
        # The three trusted executables above still constrain the signing ACL.
        search = self.out(self.sec.SecKeychainSearchCreateFromAttributes, "find imported private keys",
                          keychain, 0x10, None)  # kSecPrivateKeyItemClass
        authorization = C.c_void_p.in_dll(self.sec, "kSecACLAuthorizationPartitionID").value
        description = self.string(plistlib.dumps({"Partitions": ["apple-tool:", "apple:"]}).hex())
        count = 0
        while True:
            item = C.c_void_p()
            status = self.sec.SecKeychainSearchCopyNext(search, C.byref(item))
            if status == -25300:  # errSecItemNotFound: end of search
                break
            self.check(status, "enumerate imported private keys")
            item = self.own(item.value)
            access = self.out(self.sec.SecKeychainItemCopyAccess, "read private-key ACL", item)
            acls = self.sec.SecAccessCopyMatchingACLList(access, authorization)
            # Explicit SecAccessCreate imports can have no additional partition ACL;
            # in that case the trusted-app ACL above is sufficient. Preserve it.
            acl_count = 0
            if acls:
                acls = self.own(acls)
                acl_count = self.cf.CFArrayGetCount(acls)
            for i in range(acl_count):
                acl = self.cf.CFArrayGetValueAtIndex(acls, i)
                apps, old_description, prompt = C.c_void_p(), C.c_void_p(), C.c_uint32()
                self.check(self.sec.SecACLCopyContents(acl, C.byref(apps),
                           C.byref(old_description), C.byref(prompt)), "read partition ACL")
                if apps.value:
                    self.own(apps.value)
                if old_description.value:
                    self.own(old_description.value)
                self.check(self.sec.SecACLSetContents(acl, apps, description, prompt), "set signing partitions")
            if acl_count:
                self.check(self.sec.SecKeychainItemSetAccessWithPassword(item, access, len(password), password),
                           "authorize signing partitions")
            count += 1
        if count < 2:
            raise SigningError("P12 must contain both Application and Installer private keys")

    def delete(self, path):
        keychain = self.out(self.sec.SecKeychainOpen, "open temporary keychain", os.fsencode(path))
        self.check(self.sec.SecKeychainDelete(keychain), "delete temporary keychain")

    def close(self):
        for value in reversed(self.owned):
            self.cf.CFRelease(value)
        self.owned.clear()


def private_write(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        stream.write(data)


def identities(keychain):
    # Certificate names are captured, never printed or used as command arguments.
    output = public_tool(["/usr/bin/security", "find-identity", "-v", "-p", "basic", str(keychain)],
                         "enumerate imported signing identities")
    found = {}
    for label, variable in [("Application", "DEVELOPER_ID_APPLICATION"),
                            ("Installer", "DEVELOPER_ID_INSTALLER")]:
        matches = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "Developer ID ' + label + r': [^"\n]+"',
                             output, re.MULTILINE)
        if len(matches) != 1:
            raise SigningError(f"P12 must contain exactly one valid Developer ID {label} identity")
        found[variable] = matches[0].upper()
    return found


def cleanup(directory, security):
    if not directory.exists():
        return
    if directory.is_symlink():
        raise SigningError("Refusing a symlink as signing state directory")
    state_path = directory / "state.json"
    if not state_path.exists():
        directory.rmdir()  # init can fail between mkdir and the first private write.
        return
    state = json.loads(state_path.read_text())
    if state.get("version") != 1 or not isinstance(state.get("search_list"), list):
        raise SigningError("Invalid signing cleanup state")
    # Restore even after a partial import; deletion must still run if restoration fails.
    keychain = directory / "signing.keychain-db"
    try:
        restored = list(state["search_list"])
        # A concurrent local session may add a keychain after init. Preserve it.
        for path in security.search_paths():
            if Path(path).resolve() != keychain.resolve() and path not in restored:
                restored.append(path)
        security.set_search_paths(restored)
    finally:
        try:
            if keychain.exists():
                security.delete(keychain)
        finally:
            (directory / "AuthKey.p8").unlink(missing_ok=True)
    shutil.rmtree(directory)


def initialize(directory, security):
    required = ("MACOS_SIGNING_CERT_P12_BASE64", "MACOS_SIGNING_CERT_PASSWORD", "ASC_PRIVATE_KEY_P8")
    if any(not os.environ.get(key) for key in required):
        raise SigningError("Signing certificate, password and ASC private-key secrets are required")
    try:
        p12 = base64.b64decode(os.environ[required[0]], validate=True)
    except (ValueError, base64.binascii.Error):
        raise SigningError("Signing certificate secret is not valid base64") from None
    p8 = os.environ["ASC_PRIVATE_KEY_P8"]
    if "-----BEGIN PRIVATE KEY-----" not in p8 or "-----END PRIVATE KEY-----" not in p8:
        raise SigningError("ASC private-key secret is not a PKCS8 PEM key")
    if not os.environ.get("GITHUB_ENV"):
        raise SigningError("GITHUB_ENV is required; this helper is only for an ephemeral CI runner")
    directory.mkdir(mode=0o700)  # Never reuse or overwrite an existing directory.
    try:
        state = {"version": 1, "search_list": security.search_paths()}
        private_write(directory / "state.json", json.dumps(state))
        keychain = directory / "signing.keychain-db"
        private_write(directory / "AuthKey.p8", p8.rstrip() + "\n")
        security.create_and_import(keychain, p12, os.environ["MACOS_SIGNING_CERT_PASSWORD"])
        security.set_search_paths([str(keychain)] + state["search_list"])
        env = identities(keychain)
        env["ASC_PRIVATE_KEY_PATH"] = str(directory / "AuthKey.p8")
        with open(os.environ["GITHUB_ENV"], "a") as stream:
            for key, value in env.items():
                if "\n" in value or "\r" in value:
                    raise SigningError("Invalid signing environment value")
                stream.write(f"{key}={value}\n")
        print("Temporary signing keychain initialized; both public identity fingerprints verified")
    except BaseException:
        cleanup(directory, security)
        raise


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("init", "cleanup"):
        raise SigningError("Usage: mac-signing-keychain.py init|cleanup PRIVATE_DIRECTORY")
    if sys.platform != "darwin":
        raise SigningError("Signing keychain setup requires macOS")
    directory = Path(sys.argv[2]).absolute()
    if "\n" in str(directory) or "\r" in str(directory):
        raise SigningError("Invalid signing state directory")
    security = Security()
    try:
        if sys.argv[1] == "init":
            initialize(directory, security)
        else:
            cleanup(directory, security)
    finally:
        security.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Unexpected exceptions (including subprocess data) must not reveal secrets.
        print(str(error) if isinstance(error, SigningError) else "Signing keychain operation failed", file=sys.stderr)
        sys.exit(1)

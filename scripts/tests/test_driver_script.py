"""src/installer/tirevive-driver.ps1 (issue #31): a later -match replaces $Matches, so the Access package's name was empty
and pnputil ran without one: the Access driver stayed and Windows put the Virus back on it."""
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "src", "installer", "tirevive-driver.ps1")
GUARD = os.path.join(HERE, "..", "..", "src", "installer", "tirevive-deviceguard.ps1")
MSI = os.path.join(HERE, "..", "..", "src", "installer", "TIRevive.wxs")


class DriverScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SCRIPT, encoding="utf-8") as f:
            cls.text = f.read()

    def test_a_package_to_delete_never_comes_straight_from_matches(self):
        for line in self.text.splitlines():
            if "/delete-driver" in line and not line.lstrip().startswith("#"):
                self.assertNotIn("$Matches", line, line)

    def test_no_condition_reads_matches_after_two_matches(self):
        # the shape of the bug: two -match in one condition, $Matches used in its body
        lines = self.text.splitlines()
        for i, line in enumerate(lines):
            if len(re.findall(r"-match", line)) >= 2 and line.lstrip().startswith("if "):
                body = "\n".join(lines[i + 1 : i + 4])
                self.assertNotIn("$Matches", body, line)

    def test_the_log_says_what_the_virus_ended_up_on(self):
        self.assertIn('"now: $($_.InstanceId) -> $svc"', self.text)
        self.assertIn("still on the Access USB driver", self.text)

    def test_connected_access_guard_precedes_driver_or_certificate_changes(self):
        install = self.text[self.text.index("if ($Action -eq 'install') {"):]
        guard = install.index("Assert-TIReviveAccessDriversOffline")
        for operation in ("Remove-TIReviveAccessDriverPackage", "New-SelfSignedCertificate"):
            self.assertLess(guard, install.index(operation))

    def test_the_installer_never_forces_removal_of_an_access_device(self):
        active = "\n".join(line for line in self.text.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("/remove-device", active)
        with open(GUARD, encoding="utf-8") as f:
            guard = f.read()
        deletes = [line for line in guard.splitlines() if "/delete-driver" in line and not line.lstrip().startswith("#")]
        self.assertTrue(deletes)
        for line in deletes:
            self.assertNotIn("/uninstall", line)
            self.assertNotIn("/force", line)

    def test_the_guard_is_in_the_msi_payload(self):
        with open(MSI, encoding="utf-8") as f:
            self.assertIn("tirevive-deviceguard.ps1", f.read())


if __name__ == "__main__":
    unittest.main()

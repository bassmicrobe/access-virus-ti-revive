# tirevive-driver.ps1 install|uninstall - driver part of the TI Revive MSI (deferred custom action, SYSTEM).
# install:   bind Windows' own WinUSB driver to the Virus TI MIDI interfaces (vti_winusb.inf, no kernel code of ours):
#            self-signed code-signing cert -> catalog for the INF -> signature -> cert's PUBLIC part trusted in
#            LocalMachine Root + TrustedPublisher -> the private key is deleted (cannot sign anything else) ->
#            pnputil /add-driver /install. Removes Access driver packages (blocked on Win11 anyway).
# uninstall: pnputil /delete-driver for our package, remove the trusted cert.
# State: HKLM\SOFTWARE\TI Revive (DriverPackage, CertThumbprint). Log: %ProgramData%\TI Revive\driver.log
param([ValidateSet('install', 'uninstall')][string]$Action = 'install')
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $env:ProgramData 'TI Revive'
New-Item -ItemType Directory -Force $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir 'driver.log') -Append | Out-Null
$reg = 'HKLM:\SOFTWARE\TI Revive'

function Trust-Store([string]$name, $cert, [switch]$Remove) {
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
    $s.Open('ReadWrite')
    if ($Remove) { $s.Certificates | Where-Object Thumbprint -eq $cert | ForEach-Object { $s.Remove($_) } }
    else { $s.Add($cert) }
    $s.Close()
}

if ($Action -eq 'install') {
    try {
        . (Join-Path $here 'tirevive-deviceguard.ps1')
        Assert-TIReviveAccessDriversOffline
    } catch {
        Write-Error $_ -ErrorAction Continue
        Stop-Transcript | Out-Null
        exit 1 # the MSI's deferred action has Return="check"; do not report a successful driver setup
    }
    # NOT New-Item -Force on every run: it wiped DriverPackage / CertThumbprint before uninstall could read them
    # (E063). Do not create the key until the old-driver preflight has passed either.
    if (-not (Test-Path $reg)) { New-Item -Path $reg | Out-Null }
    # Access driver packages would be preferred for the device and are blocked by Code Integrity on Win11.
    $blocks = (pnputil /enum-drivers | Out-String) -split "(\r?\n){2,}"
    foreach ($b in $blocks) {
        # the package name first: a later -match replaces $Matches, and the Access pattern has no group, so $Matches[1]
        # was empty and pnputil ran without a package: the Access driver stayed (issue #31, fix by vmunoz82)
        if ($b -match '(oem\d+\.inf)') {
            $pkg = $Matches[1]
            if ($b -match '(?i)virususb\.inf|vtimidi\.inf|vtiaudio\.inf') {
                "removing Access driver package $pkg"
                try {
                    Remove-TIReviveAccessDriverPackage $pkg
                } catch {
                    Write-Error $_ -ErrorAction Continue
                    Stop-Transcript | Out-Null
                    exit 1
                }
            }
        }
    }
    $stage = Join-Path $env:TEMP ('tirevive-' + [guid]::NewGuid())
    New-Item -ItemType Directory $stage | Out-Null
    Copy-Item (Join-Path $here 'vti_winusb.inf') $stage
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=TI Revive local driver package' `
        -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(20) -KeyExportPolicy NonExportable
    # trust the public part first, so the signature status below is "Valid" (not "UnknownError")
    $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $cert.Export('Cert'))
    Trust-Store 'Root' $pub
    Trust-Store 'TrustedPublisher' $pub
    New-FileCatalog -Path $stage -CatalogFilePath (Join-Path $stage 'vti_winusb.cat') -CatalogVersion 2.0 | Out-Null
    $sig = Set-AuthenticodeSignature -FilePath (Join-Path $stage 'vti_winusb.cat') -Certificate $cert -HashAlgorithm SHA256
    "catalog signature: $($sig.Status)"
    Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -DeleteKey # private key gone: signs nothing else
    Set-ItemProperty $reg CertThumbprint $cert.Thumbprint
    try {
        Assert-TIReviveAccessDriversOffline
    } catch {
        Write-Error $_ -ErrorAction Continue
        Remove-Item $stage -Recurse -Force
        Stop-Transcript | Out-Null
        exit 1
    }
    $out = pnputil /add-driver (Join-Path $stage 'vti_winusb.inf') /install | Out-String
    $out
    if ($out -match '(oem\d+\.inf)') { Set-ItemProperty $reg DriverPackage $Matches[1] }
    # Do not remove a newly connected VIRUSUSB device to force re-detection (issue #31). Its legacy MIDI driver
    # can crash Windows on unload; fail and ask for an offline retry instead.
    try {
        Assert-TIReviveAccessDriversOffline
    } catch {
        Write-Error $_ -ErrorAction Continue
        Remove-Item $stage -Recurse -Force
        Stop-Transcript | Out-Null
        exit 1
    }
    pnputil /scan-devices | Out-Null
    Start-Sleep -Seconds 3
    # what the Virus ended up on, so that driver.log shows whether the switch worked
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_133E' -and $_.Present } | ForEach-Object {
        $svc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
        "now: $($_.InstanceId) -> $svc"
        if ($svc -eq 'VIRUSUSB') { "WARNING: the Virus is still on the Access USB driver" }
    }
    Remove-Item $stage -Recurse -Force
    & (Join-Path $here 'tirevive-shortcuts.ps1') uninstall # 0.8.0: no Control Center launcher - shortcuts of 0.7.x back to Access'
} else {
    & (Join-Path $here 'tirevive-shortcuts.ps1') uninstall
    $p = Get-ItemProperty $reg -ErrorAction SilentlyContinue
    Get-Process vtibroker -ErrorAction SilentlyContinue | Stop-Process -Force
    # driver package(s): the recorded one plus any vti_winusb.inf package found in the driver store
    $pkgs = @($p.DriverPackage) + @(((pnputil /enum-drivers | Out-String) -split "(\r?\n){2,}") |
        Where-Object { $_ -match '(?i)vti_winusb\.inf' -and $_ -match '(oem\d+\.inf)' } | ForEach-Object { $Matches[1] })
    foreach ($pkg in ($pkgs | Where-Object { $_ } | Select-Object -Unique)) {
        "removing driver package $pkg"
        pnputil /delete-driver $pkg /uninstall /force | Out-String
    }
    # certificates: the recorded thumbprint plus any "TI Revive local driver package" cert
    foreach ($store in 'Root', 'TrustedPublisher') {
        $thumbs = @($p.CertThumbprint) + @(Get-ChildItem "Cert:\LocalMachine\$store" |
            Where-Object Subject -eq 'CN=TI Revive local driver package' | ForEach-Object Thumbprint)
        foreach ($t in ($thumbs | Where-Object { $_ } | Select-Object -Unique)) {
            "removing certificate $t from $store"
            Trust-Store $store $t -Remove
        }
    }
    pnputil /scan-devices | Out-Null
    Remove-Item $reg -Recurse -Force -ErrorAction SilentlyContinue
}
Stop-Transcript | Out-Null
exit 0

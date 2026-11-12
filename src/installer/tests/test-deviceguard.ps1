# Self-contained regression tests for issue #31. Run with Windows PowerShell 5.1 or PowerShell 7:
# powershell -NoProfile -File src/installer/tests/test-deviceguard.ps1
# No Pester, elevation, real PnP queries or driver changes are needed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guard = Join-Path $root 'tirevive-deviceguard.ps1'
$driver = Join-Path $root 'tirevive-driver.ps1'
foreach ($path in @($guard, $driver, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed: $path : $errors" }
}
. $guard

$script:tests = 0
function Assert-True([bool]$value, [string]$label) {
    if (-not $value) { throw "FAIL: $label" }
    $script:tests++
}
function Assert-Throws([scriptblock]$action, [string]$pattern, [string]$label) {
    try { & $action } catch {
        Assert-True ($_.Exception.Message -match $pattern) $label
        return
    }
    throw "FAIL: $label (did not stop)"
}
function Reset-Fakes {
    $script:devices = @()
    $script:services = @{}
    $script:enumerationFails = $false
    $script:propertyFails = $false
    $script:nativeExit = 0
    $script:nativeCalls = @()
    $global:LASTEXITCODE = 0
}
function Get-PnpDevice {
    [CmdletBinding()]
    param([switch]$PresentOnly)
    if (-not $PresentOnly) { throw 'The guard must exclude phantom devices.' }
    if ($script:enumerationFails) { throw 'simulated enumeration failure' }
    $script:devices
}
function Get-PnpDeviceProperty {
    [CmdletBinding()]
    param([string]$InstanceId, [string]$KeyName)
    if ($script:propertyFails) { throw 'simulated property failure' }
    if ($KeyName -ne 'DEVPKEY_Device_Service') { throw 'Unexpected property query.' }
    [pscustomobject]@{ Data = $script:services[$InstanceId] }
}
function pnputil {
    $script:nativeCalls += ,@($args)
    $global:LASTEXITCODE = $script:nativeExit
    'simulated pnputil output'
}

$usb = 'USB\VID_133E&PID_0815\TEST'
$midi = 'VTIMIDEV01\TEST'
Reset-Fakes
Assert-TIReviveAccessDriversOffline
Assert-True ($script:nativeCalls.Count -eq 0) 'no device does not mutate anything'

foreach ($service in @('VIRUSUSB', 'VTIMIDEV01', 'VTIMIDI', 'VTIAUDIO', 'virususb')) {
    Reset-Fakes
    $script:devices = @([pscustomobject]@{ InstanceId = $usb; Status = 'translated status'; FriendlyName = 'translated name' })
    $script:services[$usb] = $service
    Assert-Throws { Remove-TIReviveAccessDriverPackage 'oem123.inf' } 'Shut down Windows' "blocks connected $service"
    Assert-True ($script:nativeCalls.Count -eq 0) "no native call for $service"
}

Reset-Fakes
$script:devices = @([pscustomobject]@{ InstanceId = $midi })
$script:services[$midi] = 'VTIMIDEV01'
Assert-Throws { Assert-TIReviveAccessDriversOffline } 'Shut down Windows' 'detects the legacy MIDI child'

foreach ($service in @('WINUSB', 'usbccgp')) {
    Reset-Fakes
    $script:devices = @([pscustomobject]@{ InstanceId = $usb })
    $script:services[$usb] = $service
    Assert-TIReviveAccessDriversOffline
    Assert-True ($script:nativeCalls.Count -eq 0) "allows $service without a mutation"
}

Reset-Fakes
$script:devices = @([pscustomobject]@{ InstanceId = 'USB\VID_0000&PID_0000\TEST' })
$script:services['USB\VID_0000&PID_0000\TEST'] = 'VIRUSUSB'
Assert-TIReviveAccessDriversOffline
Assert-True ($script:nativeCalls.Count -eq 0) 'does not use translated names to match unrelated devices'

Reset-Fakes
$script:enumerationFails = $true
Assert-Throws { Remove-TIReviveAccessDriverPackage 'oem123.inf' } 'Cannot verify' 'PnP enumeration failure stops removal'
Assert-True ($script:nativeCalls.Count -eq 0) 'enumeration failure never calls pnputil'

Reset-Fakes
$script:devices = @([pscustomobject]@{ InstanceId = $usb })
$script:propertyFails = $true
Assert-Throws { Remove-TIReviveAccessDriverPackage 'oem123.inf' } 'Cannot verify' 'PnP property failure stops removal'
Assert-True ($script:nativeCalls.Count -eq 0) 'property failure never calls pnputil'

Reset-Fakes
$script:devices = @([pscustomobject]@{ InstanceId = $usb })
Assert-Throws { Assert-TIReviveAccessDriversOffline } 'Cannot verify' 'empty service is not assumed safe'

Reset-Fakes
Assert-TIReviveAccessDriversOffline
$script:devices = @([pscustomobject]@{ InstanceId = $usb })
$script:services[$usb] = 'VIRUSUSB'
Assert-Throws { Remove-TIReviveAccessDriverPackage 'oem123.inf' } 'Shut down Windows' 'rechecks a device connected after the first check'
Assert-True ($script:nativeCalls.Count -eq 0) 'late connection does not force an unload'

Reset-Fakes
Remove-TIReviveAccessDriverPackage 'oem123.inf' | Out-Null
Assert-True ($script:nativeCalls.Count -eq 1) 'removes an offline package once'
Assert-True (($script:nativeCalls[0] -join ' ') -eq '/delete-driver oem123.inf') 'package removal does not request uninstall or force'

Reset-Fakes
$script:nativeExit = 5
Assert-Throws { Remove-TIReviveAccessDriverPackage 'oem123.inf' | Out-Null } 'pnputil failed' 'an in-use or failed package is not treated as removed'
Assert-Throws { Remove-TIReviveAccessDriverPackage 'not-a-package' } 'Invalid driver package' 'rejects invalid package arguments'

"PASS: $script:tests Windows device-guard assertions (all PnP/native calls mocked)."
exit 0 # the deliberately failed native mock leaves LASTEXITCODE set; assertions above decide the test result

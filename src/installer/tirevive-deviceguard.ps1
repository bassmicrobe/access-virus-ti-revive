# Issue #31: Access's legacy driver has crashed when unloaded while a Virus was present. Keep this helper free
# of side effects until called, so the guard can be tested with PnP/native commands replaced by fakes.
function Get-TIReviveAccessBindings {
    [CmdletBinding()]
    param()
    try {
        $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    } catch {
        throw 'Cannot verify connected Virus devices. Access driver changes are stopped. Shut down Windows, switch the Virus off and disconnect it while the PC is off, then start Windows and retry.'
    }
    foreach ($device in $devices) {
        # Device instance IDs and the service property are not translated. The old MIDI child is not always a
        # USB instance, so include its legacy enumerator too; stale/phantom instances were excluded above.
        $id = [string]$device.InstanceId
        if ($id -notmatch '(?i)^(USB\\VID_133E&PID_0815(?:&|\\)|VTIMIDEV01(?:\\|$))') { continue }
        try {
            $property = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop
            $service = [string]$property.Data
            if ([string]::IsNullOrWhiteSpace($service)) { throw 'No service value.' }
        } catch {
            throw 'Cannot verify the driver of a connected Virus. Access driver changes are stopped. Shut down Windows, switch the Virus off and disconnect it while the PC is off, then start Windows and retry.'
        }
        if (@('VIRUSUSB', 'VTIMIDEV01', 'VTIMIDI', 'VTIAUDIO') -contains $service.Trim()) {
            [pscustomobject]@{ InstanceId = $id; Service = $service }
        }
    }
}

function Assert-TIReviveAccessDriversOffline {
    [CmdletBinding()]
    param()
    $bindings = @(Get-TIReviveAccessBindings)
    if ($bindings.Count) {
        # A live unplug also triggered the reported old-driver bug, so do not tell the user to hot-unplug it.
        throw 'A connected Virus is using an old Access driver. TI Revive will not unload it. Shut down Windows, switch the Virus off and disconnect it while the PC is off, then start Windows and retry. Power-cycle the Virus before its first use with TI Revive.'
    }
}

function Remove-TIReviveAccessDriverPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Package)
    if ($Package -notmatch '^oem\d+\.inf$') { throw 'Invalid driver package name.' }
    Assert-TIReviveAccessDriversOffline # check again if it was connected after the initial preflight
    # Do not request /uninstall or /force: a device can appear between the check and this native call. Let
    # Windows refuse an in-use package instead of forcing a legacy driver's live unload in that race.
    $output = & pnputil /delete-driver $Package 2>&1 | Out-String
    $code = $LASTEXITCODE
    $output
    if ($null -eq $code -or $code -ne 0) {
        throw "pnputil failed to remove Access driver package $Package (exit $code). No forced unload was attempted. Shut down Windows, switch the Virus off and disconnect it while the PC is off, then start Windows and retry."
    }
}


param(
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

# Log path
try {
    $tsEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
    $logPath = $tsEnv.Value('_SMSTSLogPath')
}
catch {
    $logPath = $null
}

if (-not $logPath) {
    $logPath = Join-Path $env:WINDIR 'CCM\Logs'
}

New-Item -Path $logPath -ItemType Directory -Force | Out-Null
$logFile = Join-Path $logPath 'CCMInventory.log'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet(1, 2, 3)]
        [int]$Type = 1
    )

    $now = [DateTimeOffset]::Now
    $offset = '{0:+000;-000;+000}' -f [int]$now.Offset.TotalMinutes

    $line = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="CCMInventory" context="" type="{4}" thread="{5}" file="">' -f `
        ($Message -replace '[\r\n]+', ' '),
        $now.ToString('HH:mm:ss.fff'),
        $offset,
        $now.ToString('MM-dd-yyyy'),
        $Type,
        $PID

    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Output $Message
}

function Invoke-CCMMethod {
    param($Method, $Arguments)

    $result = Invoke-CimMethod -Namespace 'root\ccm' `
        -ClassName SMS_Client -MethodName $Method `
        -Arguments $Arguments

    if ($result.ReturnValue -ne 0) {
        throw "$Method failed: $($result.ReturnValue)"
    }
}

# Inventory actions
$actions = @(
    @{
        Name     = 'Hardware Inventory'
        Schedule = '{00000000-0000-0000-0000-000000000101}'
        Status   = '{00000000-0000-0000-0000-000000000001}'
    },
    @{
        Name     = 'Discovery Data'
        Schedule = '{00000000-0000-0000-0000-000000000103}'
        Status   = '{00000000-0000-0000-0000-000000000003}'
    }
)

$wasProvisioning = $false

try {
    Write-Log 'Starting ConfigMgr Inventory'

    # Check current provisioning mode
    $wasProvisioning = (Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec').ProvisioningMode -eq 'true'

    if ($wasProvisioning) {
        Invoke-CCMMethod 'SetClientProvisioningMode' @{ bEnable = $false }
        Write-Log 'Provisioning Mode disabled'
    }
    else {
        Write-Log 'Provisioning Mode already disabled'
    }

    # Trigger inventory cycles
    $started = Get-Date

    foreach ($action in $actions) {
        Invoke-CCMMethod 'TriggerSchedule' @{
            sScheduleID = $action.Schedule
        }
        Write-Log "Started: $($action.Name)"
    }

    # Wait for inventory reporting
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pending = @($actions)

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        foreach ($action in @($pending)) {
            $status = Get-CimInstance -Namespace 'root\ccm\invagt' `
                -ClassName InventoryActionStatus `
                -Filter "InventoryActionID='$($action.Status)'"

            if ($status -and
                $status.LastCycleStartedDate -ge $started -and
                $status.LastReportDate -ge $status.LastCycleStartedDate) {

                Write-Log "Completed: $($action.Name)"
                $pending = @($pending | Where-Object { $_.Name -ne $action.Name })
            }
        }

        if ($pending.Count -gt 0) {
            Start-Sleep -Seconds 10
        }
    }

    if ($pending.Count -gt 0) {
        throw "Inventory timeout: $(($pending.Name) -join ', ')"
    }

    Write-Log 'All inventory cycles completed'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Type 3
    throw
}
finally {
    if ($wasProvisioning) {
        try {
            Invoke-CCMMethod 'SetClientProvisioningMode' @{ bEnable = $true }
            Write-Log 'Provisioning Mode restored'
        }
        catch {
            Write-Log "ERROR restoring Provisioning Mode: $($_.Exception.Message)" -Type 3
            throw
        }
    }
}


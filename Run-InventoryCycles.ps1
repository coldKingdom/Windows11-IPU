
param(
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

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

function Invoke-CCMMethod {
    param($Method, $Arguments)

    $result = Invoke-CimMethod -Namespace 'root\ccm' `
        -ClassName SMS_Client -MethodName $Method `
        -Arguments $Arguments

    if ($result.ReturnValue -ne 0) {
        throw "$Method failed: $($result.ReturnValue)"
    }
}

$wasProvisioning = (Get-ItemProperty `
    'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec').ProvisioningMode -eq 'true'

try {
    if ($wasProvisioning) {
        Invoke-CCMMethod 'SetClientProvisioningMode' @{ bEnable = $false }
    }

    $started = Get-Date

    foreach ($action in $actions) {
        Invoke-CCMMethod 'TriggerSchedule' @{
            sScheduleID = $action.Schedule
        }
        Write-Output "Started: $($action.Name)"
    }

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

                Write-Output "Completed: $($action.Name)"
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
}
finally {
    if ($wasProvisioning) {
        Invoke-CCMMethod 'SetClientProvisioningMode' @{ bEnable = $true }
        Write-Output 'Provisioning Mode restored'
    }
}

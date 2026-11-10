
param(
    [string[]]$Cycles = @('HardwareInventory', 'DiscoveryData'),

    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

# CMTrace logging
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
        [System.Threading.Thread]::CurrentThread.ManagedThreadId

    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $Message
}

function Invoke-CCMMethod {
    param(
        [string]$Method,
        [hashtable]$Arguments
    )

    $result = Invoke-CimMethod -Namespace 'root\ccm' `
        -ClassName SMS_Client -MethodName $Method `
        -Arguments $Arguments

    if ($result.ReturnValue -ne 0) {
        throw "$Method failed: $($result.ReturnValue)"
    }
}

# Microsoft-documented ConfigMgr schedules
# Values are the final three digits of the schedule GUID
$cycleIds = [ordered]@{
    HardwareInventoryAction       = '001'
    SoftwareInventoryAction       = '002'
    DiscoveryDataRecord           = '003'
    FileCollectionAction          = '010'
    IDMIFCollectionAction         = '011'
    ClientMachineAuthentication   = '012'
    MachinePolicyRequest          = '021'
    MachinePolicyEvaluation       = '022'
    RefreshDefaultMP              = '023'
    LocationRefresh               = '024'
    LocationTimeoutRefresh        = '025'
    UserPolicyRequest             = '026'
    UserPolicyEvaluation          = '027'
    SoftwareMeteringReport        = '031'
    SourceUpdateMessage           = '032'
    ClearProxyCache               = '037'
    MachinePolicyCleanup          = '040'
    UserPolicyCleanup             = '041'
    MachinePolicyValidation       = '042'
    UserPolicyValidation          = '043'
    RefreshCertificates           = '051'
    PeerDPStatusReport            = '061'
    PeerDPPackageCheck            = '062'
    SoftwareUpdatesInstall        = '063'
    HardwareInventory             = '101'
    SoftwareInventory             = '102'
    DiscoveryData                 = '103'
    FileCollection                = '104'
    IDMIFCollection               = '105'
    SoftwareMetering              = '106'
    WindowsInstallerSourceUpdate  = '107'
    SoftwareUpdateEvaluation      = '108'
    BranchDPMaintenance           = '109'
    SendUnsentStateMessages       = '111'
    StateSystemPolicyCleanup      = '112'
    SoftwareUpdateScan            = '113'
    UpdateStorePolicy             = '114'
    StateSystemBulkSendHigh       = '115'
    StateSystemBulkSendLow        = '116'
    ApplicationPolicyAction       = '121'
    ApplicationUserPolicyAction   = '122'
    ApplicationEvaluation         = '123'
    PowerManagementSummarizer     = '131'
    EndpointDeploymentReevaluate  = '221'
    EndpointAMPolicyReevaluate    = '222'
    ExternalEventDetection        = '223'
}

# Cycles with InventoryActionStatus reporting
$inventoryIds = @{
    HardwareInventory = '001'
    SoftwareInventory = '002'
    DiscoveryData     = '003'
    FileCollection    = '010'
    IDMIFCollection   = '011'
}

$wasProvisioning = $false
$failed = $false

try {
    Write-Log 'Starting ConfigMgr client actions'

    # Validate and expand selected cycles
    if ($Cycles -contains 'All') {
        if ($Cycles.Count -ne 1) {
            throw "'All' cannot be combined with other cycles."
        }

        $selected = @($cycleIds.Keys)
    }
    else {
        $selected = @($Cycles | Select-Object -Unique)
    }

    foreach ($name in $selected) {
        if (-not $cycleIds.Contains($name)) {
            throw "Unknown cycle: $name"
        }
    }

    Write-Log "Selected cycles: $($selected -join ', ')"

    # Save existing inventory status for comparison
    $previous = @{}

    foreach ($name in $selected) {
        if (-not $inventoryIds.ContainsKey($name)) {
            continue
        }

        $id = '{00000000-0000-0000-0000-000000000' +
              $inventoryIds[$name] + '}'

        $state = Get-CimInstance -Namespace 'root\ccm\invagt' `
            -ClassName InventoryActionStatus `
            -Filter "InventoryActionID='$id'"

        $lastStart = [datetime]::MinValue
        $lastReport = [datetime]::MinValue

        if ($state) {
            if ($state.LastCycleStartedDate) {
                $lastStart = $state.LastCycleStartedDate
            }
            if ($state.LastReportDate) {
                $lastReport = $state.LastReportDate
            }
        }

        $previous[$name] = @{
            Started = $lastStart
            Report  = $lastReport
        }
    }

    # Temporarily disable provisioning mode
    $wasProvisioning = [string](Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec').ProvisioningMode -eq 'True'

    if ($wasProvisioning) {
        Invoke-CCMMethod 'SetClientProvisioningMode' @{
            bEnable = $false
        }
        Write-Log 'Provisioning Mode disabled'
    }
    else {
        Write-Log 'Provisioning Mode already disabled'
    }

    # Trigger selected cycles
    foreach ($name in $selected) {
        $id = '{00000000-0000-0000-0000-000000000' +
              $cycleIds[$name] + '}'

        Invoke-CCMMethod 'TriggerSchedule' @{
            sScheduleID = $id
        }

        Write-Log "Triggered: $name ($id)"

        if (-not $inventoryIds.ContainsKey($name)) {
            Write-Log "Completion cannot be verified: $name" -Type 2
        }
    }

    # Wait for inventory reports where supported
    $pending = @($selected | Where-Object {
        $inventoryIds.ContainsKey($_)
    })

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    if ($pending.Count -gt 0) {
        Write-Log "Waiting for inventory reports: $($pending -join ', ')"
    }

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        foreach ($name in @($pending)) {
            $id = '{00000000-0000-0000-0000-000000000' +
                  $inventoryIds[$name] + '}'

            $state = Get-CimInstance -Namespace 'root\ccm\invagt' `
                -ClassName InventoryActionStatus `
                -Filter "InventoryActionID='$id'"

            if ($state -and
                $state.LastCycleStartedDate -gt $previous[$name].Started -and
                $state.LastReportDate -gt $previous[$name].Report -and
                $state.LastReportDate -ge $state.LastCycleStartedDate) {

                Write-Log "Reported: $name"

                $pending = @($pending | Where-Object {
                    $_ -ne $name
                })
            }
        }

        if ($pending.Count -gt 0) {
            Start-Sleep -Seconds 10
        }
    }

    if ($pending.Count -gt 0) {
        throw "Inventory timeout: $($pending -join ', ')"
    }

    Write-Log 'Selected client actions processed'
}
catch {
    $failed = $true
    Write-Log "ERROR: $($_.Exception.Message)" -Type 3
}
finally {
    if ($wasProvisioning) {
        try {
            Invoke-CCMMethod 'SetClientProvisioningMode' @{
                bEnable = $true
            }

            Write-Log 'Provisioning Mode restored'
        }
        catch {
            $failed = $true
            Write-Log "ERROR restoring Provisioning Mode: $($_.Exception.Message)" -Type 3
        }
    }
}

if ($failed) {
    exit 1
}

exit 0

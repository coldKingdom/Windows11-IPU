# Kor i Windows PowerShell 5.1 som SYSTEM, efter domananslutning och omstart.
$ErrorActionPreference = 'Stop'

function Set-CertificateValidationCallback {
    <#
    .SYNOPSIS
        Configure the current session to ignore self-signed certificate validation errors.

    .DESCRIPTION
        Previously performed inline in Get-AdminServiceItem, which called Add-Type on every
        certificate failure. A second AdminService call hitting the same condition would then fail
        because the type already existed, so the definition is now added at most once per run.
    #>
    if ($Script:CertificateValidationCallbackEnabled -eq $true) {
        return
    }

    # Attempt to ignore self-signed certificate binding for AdminService
    # Convert encoded base64 string for ignore self-signed certificate validation functionality
    $CertificationValidationCallbackEncoded = 'dQBzAGkAbgBnACAAUwB5AHMAdABlAG0AOwAKAHUAcwBpAG4AZwAgAFMAeQBzAHQAZQBtAC4ATgBlAHQAOwAKAHUAcwBpAG4AZwAgAFMAeQBzAHQAZQBtAC4ATgBlAHQALgBTAGUAYwB1AHIAaQB0AHkAOwAKAHUAcwBpAG4AZwAgAFMAeQBzAHQAZQBtAC4AUwBlAGMAdQByAGkAdAB5AC4AQwByAHkAcAB0AG8AZwByAGEAcABoAHkALgBYADUAMAA5AEMAZQByAHQAaQBmAGkAYwBhAHQAZQBzADsACgBwAHUAYgBsAGkAYwAgAGMAbABhAHMAcwAgAFMAZQByAHYAZQByAEMAZQByAHQAaQBmAGkAYwBhAHQAZQBWAGEAbABpAGQAYQB0AGkAbwBuAEMAYQBsAGwAYgBhAGMAawAKAHsACgAgACAAIAAgAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIAB2AG8AaQBkACAASQBnAG4AbwByAGUAKAApAAoAIAAgACAAIAB7AAoAIAAgACAAIAAgACAAIAAgAGkAZgAgACgAUwBlAHIAdgBpAGMAZQBQAG8AaQBuAHQATQBhAG4AYQBnAGUAcgAuAFMAZQByAHYAZQByAEMAZQByAHQAaQBmAGkAYwBhAHQAZQBWAGEAbABpAGQAYQB0AGkAbwBuAEMAYQBsAGwAYgBhAGMAawAgAD0APQAgAG4AdQBsAGwAKQAKACAAIAAgACAAIAAgACAAIAB7AAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAUwBlAHIAdgBpAGMAZQBQAG8AaQBuAHQATQBhAG4AYQBnAGUAcgAuAFMAZQByAHYAZQByAEMAZQByAHQAaQBmAGkAYwBhAHQAZQBWAGEAbABpAGQAYQB0AGkAbwBuAEMAYQBsAGwAYgBhAGMAawAgACsAPQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAZABlAGwAZQBnAGEAdABlACgATwBiAGoAZQBjAHQAIABvAGIAagAsACAAWAA1ADAAOQBDAGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAGUAcgB0AGkAZgBpAGMAYQB0AGUALAAgAFgANQAwADkAQwBoAGEAaQBuACAAYwBoAGEAaQBuACwAIABTAHMAbABQAG8AbABpAGMAeQBFAHIAcgBvAHIAcwAgAGUAcgByAG8AcgBzACkACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAHsACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAcgBlAHQAdQByAG4AIAB0AHIAdQBlADsACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAH0AOwAKACAAIAAgACAAIAAgACAAIAB9AAoAIAAgACAAIAB9AAoAfQA='
    $CertificationValidationCallback = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($CertificationValidationCallbackEncoded))

    # Load required type definition to be able to ignore self-signed certificate to circumvent issues with AdminService running with ConfigMgr self-signed certificate binding
    if (-not ('ServerCertificateValidationCallback' -as [type])) {
        Add-Type -TypeDefinition $CertificationValidationCallback
    }
    [ServerCertificateValidationCallback]::Ignore()
    $Script:CertificateValidationCallbackEnabled = $true
}

# ANDRA dessa tva varden.
$uri = 'https://iis01.contoso.local/OUmove/MoveComputer.ashx'
$targetOu = 'OU=Workstations,DC=contoso,DC=local'

$exitCode = 1
$transcriptStarted = $false

try {
    # TS-variabler lases via COM; de ar inte automatiskt miljo-variabler.
    $tsEnvironment = $null
    try { $tsEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment }
    catch { } # Manuell korning utan aktiv Task Sequence ar ocksa tillaten.

    $logDirectory = $null
    $logSource = '_SMSTSLogPath (Task Sequence)'
    if ($null -ne $tsEnvironment) {
        $logDirectory = $tsEnvironment.Value('_SMSTSLogPath')
    }
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Join-Path ([IO.Path]::GetTempPath()) 'OUmove'
        $logSource = 'TEMP (no Task Sequence log path available)'
    }

    $logDirectory = [Environment]::ExpandEnvironmentVariables($logDirectory)
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $logFile = Join-Path $logDirectory ('MoveComputer_{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $PID)
    Start-Transcript -Path $logFile -NoClobber -ErrorAction Stop | Out-Null
    $transcriptStarted = $true

    Write-Host ('[{0}] Startar OU-flytt.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('Dator: {0}' -f $env:COMPUTERNAME)
    Write-Host ('Lokalt konto: {0}' -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    Write-Host ('Loggkatalog fran: {0}' -f $logSource)
    Write-Host ('Transcript: {0}' -f $logFile)
    Write-Host ('URL: {0}' -f $uri)
    Write-Host ('Begart mal-OU: {0}' -f $targetOu)

    if (([uri]$uri).Scheme -ne 'https') { throw 'URL must use HTTPS.' }
    Write-Host 'Aktiverar Set-CertificateValidationCallback.'
    Set-CertificateValidationCallback
    Write-Host 'Certifikatfunktionen ar anropad. En eventuell befintlig callback behalls.'

    Write-Host 'Skickar POST med Windows-standardcredentials. Vid korning som SYSTEM anvands datorns domankonto for natverksautentisering.'
    $result = Invoke-RestMethod -Uri $uri -Method Post `
        -UseDefaultCredentials `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ TargetOU = $targetOu } `
        -MaximumRedirection 0 -TimeoutSec 90 -ErrorAction Stop

    Write-Host ('Serversvar: {0}' -f $result)
    Write-Host 'Anropet lyckades. Servern bekraftar flytt eller att datorn redan ligger i mal-OU.'
    $exitCode = 0
}
catch {
    $failure = $_
    Write-Host ('FEL: OU-flytt misslyckades: {0}' -f $failure.Exception.Message)
    if ($failure.Exception -is [Net.WebException] -and $null -ne $failure.Exception.Response) {
        Write-Host ('HTTP-status: {0}' -f [int]$failure.Exception.Response.StatusCode)
    }
    if ($failure.ErrorDetails.Message) {
        Write-Host ('Felsvar fran servern: {0}' -f $failure.ErrorDetails.Message)
    }
}
finally {
    Write-Host ('[{0}] Avslutar med exitkod {1}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $exitCode)
    if ($transcriptStarted) {
        try { Stop-Transcript -ErrorAction Stop | Out-Null }
        catch {
            Write-Host ('FEL: Kunde inte avsluta transcript: {0}' -f $_.Exception.Message)
            $exitCode = 1
        }
    }
}

exit $exitCode

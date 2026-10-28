# Kör i Windows PowerShell 5.1 som SYSTEM, efter domänanslutning och omstart.
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

function Get-HttpErrorResponse {
    param([System.Management.Automation.ErrorRecord]$Failure)
    $exception = $Failure.Exception
    while ($null -ne $exception) {
        if ($exception -is [Net.WebException] -and $null -ne $exception.Response) {
            return $exception.Response
        }
        $exception = $exception.InnerException
    }
    return $null
}

function Get-RetryDelaySeconds {
    param([string]$RetryAfter, [int]$DefaultSeconds = 10)
    $header = $RetryAfter.Trim()
    [long]$seconds = 0
    if ([long]::TryParse($header, [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
        return $seconds
    }
    [DateTimeOffset]$retryDate = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParseExact($header, 'r',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$retryDate)) {
        return [Math]::Max(0, [Math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds))
    }
    return $DefaultSeconds
}

# ÄNDRA dessa två värden.
$uri = 'https://iis01.contoso.local/OUmove/MoveComputer.ashx'
$targetOu = 'OU=Workstations,DC=contoso,DC=local'

# Tre försök totalt, inklusive det första. Retry endast vid HTTP 503.
$maxAttempts = 3
$defaultRetryDelaySeconds = 10
$maxRetryDelaySeconds = 60

$exitCode = 1
$transcriptStarted = $false

try {
    # TS-variabler läses via COM; de är inte automatiskt miljö-variabler.
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
    Write-Host ('Loggkatalog från: {0}' -f $logSource)
    Write-Host ('Transcript: {0}' -f $logFile)
    Write-Host ('URL: {0}' -f $uri)
    Write-Host ('Begärt mål-OU: {0}' -f $targetOu)

    if (([uri]$uri).Scheme -ne 'https') { throw 'URL must use HTTPS.' }
    Write-Host 'Aktiverar Set-CertificateValidationCallback.'
    Set-CertificateValidationCallback
    Write-Host 'Certifikatfunktionen är anropad. En eventuell befintlig callback behålls.'

    Write-Host 'Skickar POST med Windows-standardcredentials. Vid körning som SYSTEM används datorns domänkonto för nätverksautentisering.'
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host ('[{0}] Försök {1} av {2}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $attempt, $maxAttempts)
        try {
            $result = Invoke-RestMethod -Uri $uri -Method Post `
                -UseDefaultCredentials `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body @{ TargetOU = $targetOu } `
                -MaximumRedirection 0 -TimeoutSec 90 -ErrorAction Stop
            break
        }
        catch {
            $attemptFailure = $_
            $httpResponse = Get-HttpErrorResponse -Failure $attemptFailure
            $statusCode = $null
            $retryAfter = ''
            if ($null -ne $httpResponse) {
                $statusCode = [int]$httpResponse.StatusCode
                $retryAfter = [string]$httpResponse.Headers['Retry-After']
                Write-Host ('HTTP-status: {0}; referens-ID: {1}' -f $statusCode, $httpResponse.Headers['X-OUmove-RequestId'])
                try { $httpResponse.Close() } catch { }
            }
            Write-Host ('Försök {0} misslyckades: {1}' -f $attempt, $attemptFailure.Exception.Message)
            if ($attemptFailure.ErrorDetails.Message) {
                Write-Host ('Felsvar från servern: {0}' -f $attemptFailure.ErrorDetails.Message)
            }

            if ($statusCode -ne 503) {
                Write-Host 'Inget återförsök: felet är inte HTTP 503.'
                throw
            }
            if ($attempt -ge $maxAttempts) {
                Write-Host 'Maximalt antal försök uppnått.'
                throw
            }
            $delaySeconds = Get-RetryDelaySeconds -RetryAfter $retryAfter -DefaultSeconds $defaultRetryDelaySeconds
            if ($delaySeconds -gt $maxRetryDelaySeconds) {
                # Avbryt hellre än att återförsöka tidigare än servern tillåter.
                Write-Host ('Inget återförsök: Retry-After överstiger gräns på {0} sekunder.' -f $maxRetryDelaySeconds)
                throw
            }
            Write-Host ('Väntar {0} sekunder före nästa försök med samma mål-OU.' -f $delaySeconds)
            Start-Sleep -Seconds $delaySeconds
        }
    }

    Write-Host ('Serversvar: {0}' -f $result)
    Write-Host 'Anropet lyckades. Servern bekräftar flytt eller att datorn redan ligger i mål-OU.'
    $exitCode = 0
}
catch {
    $failure = $_
    Write-Host ('FEL: OU-flytt misslyckades: {0}' -f $failure.Exception.Message)
    $failedResponse = Get-HttpErrorResponse -Failure $failure
    if ($null -ne $failedResponse) {
        Write-Host ('HTTP-status: {0}' -f [int]$failedResponse.StatusCode)
    }
    if ($failure.ErrorDetails.Message) {
        Write-Host ('Felsvar från servern: {0}' -f $failure.ErrorDetails.Message)
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

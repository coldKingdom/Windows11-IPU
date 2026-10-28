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

try {
    if (([uri]$uri).Scheme -ne 'https') { throw 'URL must use HTTPS.' }
    Set-CertificateValidationCallback

    $result = Invoke-RestMethod -Uri $uri -Method Post `
        -UseDefaultCredentials `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ TargetOU = $targetOu } `
        -MaximumRedirection 0 -TimeoutSec 90 -ErrorAction Stop

    Write-Output $result
    exit 0
}
catch {
    [Console]::Error.WriteLine(('OU-flytt misslyckades: {0}' -f $_))
    if ($_.ErrorDetails.Message) {
        [Console]::Error.WriteLine($_.ErrorDetails.Message)
    }
    exit 1
}

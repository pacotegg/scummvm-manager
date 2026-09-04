Set-StrictMode -Version Latest

# Log simple a Logs\yyyy-MM-dd.log en la raiz del proyecto.
# (Fix 2026-07-10: "Split-Path -Parent -Parent" era un ParameterBindingException
#  en PS 5.1 — el switch repetido no acumula; hay que anidar los Split-Path.)
function Write-SCMLog {

    param(
        [string]$Message
    )

    $Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

    $LogFolder = Join-Path $Root "Logs"

    if (!(Test-Path $LogFolder)) {
        New-Item $LogFolder -ItemType Directory | Out-Null
    }

    $LogFile = Join-Path $LogFolder "$(Get-Date -Format 'yyyy-MM-dd').log"

    Add-Content $LogFile "$(Get-Date -Format 'HH:mm:ss')  $Message"
}

Export-ModuleMember -Function Write-SCMLog

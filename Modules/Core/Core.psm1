Set-StrictMode -Version Latest

# Show-SCMHeader se movio a Modules\UI\Theme.psm1 (presentacion).
# Core conserva solo utilidades transversales sin dependencias de tema.

function Pause-SCM {

    Write-Host ""
    Read-Host "Press ENTER to continue" | Out-Null
}


Export-ModuleMember -Function Pause-SCM

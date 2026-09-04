# NOTA DE RECONSTRUCCION (no viene del chat original):
# Este modulo se creo en el chat (turno 465) como el arranque de un "Repair
# Engine" (solo deteccion de carpetas mal nombradas, sin acciones destructivas
# todavia). Manage-ScummVM.ps1 NO lo importa ni lo llama desde ningun sitio -
# se quedo huerfano/sin conectar al menu. Se incluye tal cual por si quieres
# retomarlo, pero no forma parte del flujo activo del script.

Set-StrictMode -Version Latest

function Invoke-SCMRepairScan {

    param(
        [Parameter(Mandatory)]
        [string]$RomFolder
    )

    Write-Host ""
    Write-Host "=== SCM Repair Engine ===" -ForegroundColor Cyan
    Write-Host "Scanning:" $RomFolder
    Write-Host ""

    $folders = Get-ChildItem -Path $RomFolder -Directory

    $report = @()

    foreach ($folder in $folders) {

        $item = [PSCustomObject]@{
            FolderName = $folder.Name
            FullPath   = $folder.FullName
            Issues     = @()
            Expected   = ""
        }

        # Placeholder checks (we expand next commit)
        if ($folder.Name -match "_") {
            $item.Issues += "Underscore naming"
        }

        if ($folder.Name -match "^[a-z]") {
            $item.Issues += "Not title-cased"
        }

        $report += $item
    }

    Write-Host "Scan complete:" $report.Count "folders"
    Write-Host ""

    return $report
}

Export-ModuleMember -Function Invoke-SCMRepairScan

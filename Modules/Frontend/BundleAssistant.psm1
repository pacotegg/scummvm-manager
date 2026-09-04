Set-StrictMode -Version Latest

# =====================================================================
#  BundleAssistant.psm1 - ayuda a separar una carpeta que contiene VARIOS
#  juegos (un "bundle") en carpetas propias. Es no destructivo: crea las
#  carpetas destino con su .scummvm y te indica que ficheros mover; NO
#  mueve datos por su cuenta (no puede saber que fichero es de que juego).
# =====================================================================

# Agrupa los juegos por carpeta de primer nivel; devuelve las que tienen >1.
function Get-SCMBundles {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder
    )

    $byFolder = @{}
    foreach ($g in $Games) {
        $seg = Get-SCMFirstSegment -RomFolder $RomFolder -FullPath $g.FullPath
        if (-not $seg) { continue }
        $key = $seg
        if (-not $byFolder.ContainsKey($key)) { $byFolder[$key] = @() }
        $byFolder[$key] += $g
    }

    $bundles = @()
    foreach ($k in $byFolder.Keys) {
        if (@($byFolder[$k]).Count -gt 1) {
            $bundles += [PSCustomObject]@{
                FolderName = $k
                FolderPath = Join-Path $RomFolder $k
                Games      = @($byFolder[$k])
            }
        }
    }
    return $bundles
}

function Invoke-SCMBundleAssistant {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder
    )

    $bundles = @(Get-SCMBundles -Games $Games -RomFolder $RomFolder)

    Write-Host ""
    Show-SCMPanel -Title "Bundle Assistant" -Lines @(
        ("Carpetas con varios juegos: {0}" -f $bundles.Count),
        "",
        "Un bundle es una carpeta que contiene mas de un juego.",
        "El asistente crea una carpeta propia (con su .scummvm) para",
        "cada juego; luego TU mueves los ficheros de datos de cada",
        "juego a su carpeta (el programa no puede adivinar cuales son)."
    )

    if ($bundles.Count -eq 0) {
        Write-Host ""
        Write-Host "  No hay bundles. Nada que separar." -ForegroundColor $global:SCMTheme.Ok
        return
    }

    $existing = @(Get-ChildItem -Path $RomFolder -Directory | ForEach-Object { $_.Name })

    foreach ($b in $bundles) {
        Write-Host ""
        Write-Host ("  Bundle: {0}  ({1} juegos)" -f $b.FolderName, @($b.Games).Count) -ForegroundColor $global:SCMTheme.Title
        $plan = @()
        foreach ($g in $b.Games) {
            $name = ConvertTo-SCMSafeFileName -Title $g.Title
            if ([string]::IsNullOrWhiteSpace($name)) { $name = ConvertTo-SCMSafeFileName -Title ([string]$g.ShortID) }
            $name = Resolve-SCMUniqueName -BaseName $name -ExistingNames @($existing + ($plan | ForEach-Object { $_.Name }))
            $plan += [PSCustomObject]@{ Name = $name; GameID = $g.GameID; Title = $g.DisplayTitle }
            Write-Host ("    - {0}  ->  carpeta '{1}'  (.scummvm: {2})" -f $g.DisplayTitle, $name, $g.GameID) -ForegroundColor $global:SCMTheme.Menu
        }

        Write-Host ""
        $ans = Read-Host ("  Crear estas {0} carpetas destino con su .scummvm? (s/N)" -f @($plan).Count)
        if ($ans -ne "s" -and $ans -ne "S") {
            Write-Host "  Saltado." -ForegroundColor $global:SCMTheme.Dim
            continue
        }

        foreach ($p in $plan) {
            $dir = Join-Path $RomFolder $p.Name
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $svm = Join-Path $dir ("$($p.Name).scummvm")
            if (-not (Test-Path $svm)) { Set-Content -Path $svm -Value $p.GameID -Encoding ASCII -NoNewline }
            $existing += $p.Name
            Write-Host ("    creada: {0}" -f $p.Name) -ForegroundColor $global:SCMTheme.Ok
        }
        Write-Host ("  AHORA mueve a mano los ficheros de cada juego desde '{0}' a su carpeta nueva." -f $b.FolderName) -ForegroundColor $global:SCMTheme.Warn
        Write-Host "  Cuando termines, haz Scan otra vez para que se detecten por separado." -ForegroundColor $global:SCMTheme.Dim
    }
}

Export-ModuleMember -Function Get-SCMBundles, Invoke-SCMBundleAssistant

Set-StrictMode -Version Latest

# =====================================================================
#  ImportStatus.psm1 - informe de "que carpetas quedaron fuera del scan".
#
#  Tras un Scan, no todas las carpetas de RomFolder acaban en games.json:
#   - Algunas ScummVM no las reconoce ("unknown game variant", nativas...).
#   - Otras SI las detecta pero el dedup por ShortID descarta la copia
#     duplicada (p.ej. dos carpetas con el mismo juego).
#
#  Lo que de verdad decide si RetroBat lanza un juego es la presencia de un
#  fichero .scummvm dentro de la carpeta. Por eso este informe clasifica
#  CADA carpeta de primer nivel en 4 estados y resalta el unico problematico:
#  "no detectada Y sin .scummvm" (esa no aparecera en el frontend).
#
#  Requiere (cargados por el script principal): Config, Theme (Show-SCMPanel),
#  Fallback (Get-SCMFirstSegment, Find-SCMKnownGame, Get-SCMKnownGames).
# =====================================================================

# Carpetas de media (canonicas + alias de MediaStatus si esta cargado): una
# carpeta "video" o "screenshots" NO es un juego "Missing".
function Get-SCMImportMediaFolders {
    try {
        if (Get-Command Get-SCMMediaFolderNames -ErrorAction SilentlyContinue) { return @(Get-SCMMediaFolderNames) }
    } catch { }
    return @("images", "videos", "manuals", "marquees", "snaps")
}
$script:SCMImportMediaFolders = Get-SCMImportMediaFolders

# Lee el ID (engine:target) del primer .scummvm de una carpeta, o $null.
function Get-SCMScummvmId {
    param([Parameter(Mandatory)][string]$FolderPath)

    $file = @(Get-ChildItem -Path $FolderPath -Filter *.scummvm -File -ErrorAction SilentlyContinue |
        Select-Object -First 1)
    if ($file.Count -eq 0) { return $null }
    try {
        $content = (Get-Content -Path $file[0].FullName -Raw -ErrorAction Stop).Trim()
        if ([string]::IsNullOrWhiteSpace($content)) { return "" }
        return $content
    }
    catch { return "" }
}

# Clasifica cada carpeta de primer nivel bajo RomFolder respecto al scan.
# Devuelve un objeto con la lista completa y recuentos por estado.
function Get-SCMImportStatus {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder
    )

    if (-not (Test-Path $RomFolder)) {
        return [PSCustomObject]@{
            Folders = @(); Ok = @(); NeedsScummvm = @()
            PlayableOnly = @(); Missing = @(); TotalFolders = 0
        }
    }

    # Carpetas cubiertas por algun juego detectado (por su primer segmento).
    $covered = @{}
    foreach ($g in $Games) {
        $seg = Get-SCMFirstSegment -RomFolder $RomFolder -FullPath $g.FullPath
        if ($seg) { $covered[$seg.ToLowerInvariant()] = $true }
    }

    $known = @(Get-SCMKnownGames)

    $folders = @()
    Get-ChildItem -Path $RomFolder -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($script:SCMImportMediaFolders -contains $name) { return }

        $inDb       = $covered.ContainsKey($name.ToLowerInvariant())
        $scummvmId  = Get-SCMScummvmId -FolderPath $_.FullName
        $hasScummvm = ($null -ne $scummvmId)

        # Pista de la tabla verificada (por si el usuario quiere anadir el ID).
        $guess = $null
        if (-not $inDb) {
            $match = Find-SCMKnownGame -FolderName $name -KnownGames $known
            if ($null -ne $match) { $guess = [string]$match.Id }
        }

        # Estado: Ok / NeedsScummvm / PlayableOnly / Missing.
        $state =
            if ($inDb -and $hasScummvm)        { "Ok" }
            elseif ($inDb -and -not $hasScummvm) { "NeedsScummvm" }
            elseif (-not $inDb -and $hasScummvm) { "PlayableOnly" }
            else                                 { "Missing" }

        $folders += [PSCustomObject]@{
            Folder     = $name
            Path       = $_.FullName
            InDb       = $inDb
            HasScummvm = $hasScummvm
            ScummvmId  = $scummvmId
            KnownGuess = $guess
            State      = $state
        }
    }

    $folders = @($folders | Sort-Object Folder)

    return [PSCustomObject]@{
        Folders      = $folders
        TotalFolders = $folders.Count
        Ok           = @($folders | Where-Object { $_.State -eq "Ok" })
        NeedsScummvm = @($folders | Where-Object { $_.State -eq "NeedsScummvm" })
        PlayableOnly = @($folders | Where-Object { $_.State -eq "PlayableOnly" })
        Missing      = @($folders | Where-Object { $_.State -eq "Missing" })
    }
}

# Muestra el informe con colores. Resalta las carpetas 'Missing' (ni juego
# detectado ni .scummvm): son las unicas que NO apareceran en el frontend.
function Show-SCMImportStatusReport {
    param([Parameter(Mandatory)]$Status)

    Write-Host ""
    Show-SCMPanel -Title "Import Status - carpetas vs scan" -Lines @(
        ("Carpetas de juego en disco     : {0}" -f $Status.TotalFolders),
        "",
        ("Detectadas + .scummvm    (OK) : {0}" -f @($Status.Ok).Count),
        ("Detectadas, sin .scummvm      : {0}  (haz Sync Frontend)" -f @($Status.NeedsScummvm).Count),
        ("Sin detectar, con .scummvm    : {0}  (RetroBat las lanza)" -f @($Status.PlayableOnly).Count),
        ("Sin detectar y sin .scummvm   : {0}  (no apareceran)" -f @($Status.Missing).Count)
    )

    if (@($Status.NeedsScummvm).Count -gt 0) {
        Write-Host ""
        Write-Host "  Detectadas pero les falta el .scummvm (Sync Frontend -> Detect NEW):" -ForegroundColor $global:SCMTheme.Warn
        foreach ($f in $Status.NeedsScummvm) {
            Write-Host ("   - {0}" -f $f.Folder) -ForegroundColor $global:SCMTheme.Dim
        }
    }

    if (@($Status.PlayableOnly).Count -gt 0) {
        Write-Host ""
        Write-Host "  Fuera del scan pero YA tienen .scummvm (RetroBat las lanza):" -ForegroundColor $global:SCMTheme.Ok
        foreach ($f in $Status.PlayableOnly) {
            Write-Host ("   - {0}  ({1})" -f $f.Folder, $f.ScummvmId) -ForegroundColor $global:SCMTheme.Dim
        }
    }

    if (@($Status.Missing).Count -gt 0) {
        Write-Host ""
        Write-Host ("  NO importadas y SIN .scummvm ({0}) - revisar a mano:" -f @($Status.Missing).Count) -ForegroundColor $global:SCMTheme.Error
        foreach ($f in $Status.Missing) {
            if ($null -ne $f.KnownGuess) {
                # Ya esta en KnownGames.json: el fallback puede crear el .scummvm.
                Write-Host ("   - {0}" -f $f.Folder) -ForegroundColor $global:SCMTheme.Menu
                Write-Host ("       ID conocido: {0}  ->  Sync Frontend > Detect NEW crea su .scummvm" -f $f.KnownGuess) -ForegroundColor $global:SCMTheme.Dim
            }
            else {
                Write-Host ("   - {0}   (sin ID conocido)" -f $f.Folder) -ForegroundColor $global:SCMTheme.Dim
            }
        }
        Write-Host ""
        Write-Host "  Con 'ID conocido' -> haz Sync Frontend > Detect NEW y se crea el .scummvm." -ForegroundColor $global:SCMTheme.Dim
        Write-Host "  Sin ID conocido   -> variante desconocida, o juego no-ScummVM (nativo/Unity)." -ForegroundColor $global:SCMTheme.Dim
    }

    if (@($Status.Missing).Count -eq 0 -and @($Status.NeedsScummvm).Count -eq 0) {
        Write-Host ""
        Write-Host "  Todas las carpetas estan cubiertas o son lanzables. Nada pendiente." -ForegroundColor $global:SCMTheme.Ok
    }
}

Export-ModuleMember -Function Get-SCMScummvmId, Get-SCMImportStatus, Show-SCMImportStatusReport

Set-StrictMode -Version Latest

# =====================================================================
#  Doctor.psm1 - chequeo de salud de la coleccion y del entorno:
#   - Entorno: scummvm.exe y RomFolder presentes.
#   - Por juego: carpeta existe, tiene .scummvm, tiene entrada en gamelist.
#   - Duplicados: mismo ShortID en varias carpetas.
#   - Huerfanos: media sin carpeta / entradas de gamelist sin carpeta /
#     carpetas de juego sin .scummvm.
#   - Media faltante: juegos sin image/video/manual (lista para scrapear).
# =====================================================================

# Carpetas de media (canonicas + alias de MediaStatus si esta cargado): una
# carpeta "video" o "screenshots" NO debe contarse como carpeta de juego.
function Get-SCMDoctorMediaRoots {
    try {
        if (Get-Command Get-SCMMediaFolderNames -ErrorAction SilentlyContinue) { return @(Get-SCMMediaFolderNames) }
    } catch { }
    return @("images", "videos", "manuals", "marquees", "snaps")
}
$script:SCMDoctorMediaRoots = Get-SCMDoctorMediaRoots

function Get-SCMDoctorReport {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder
    )

    $config = Get-SCMConfig
    $mediaIndex = Get-SCMMediaIndex -RomFolder $RomFolder

    # --- Entorno ---
    $scummvmOk = Test-Path $config.Paths.ScummVM
    $romOk     = Test-Path $RomFolder

    # Carpetas de juego reales en disco (excluyendo media).
    $diskFolders = @()
    if ($romOk) {
        $diskFolders = @(
            Get-ChildItem -Path $RomFolder -Directory |
            Where-Object { $script:SCMDoctorMediaRoots -notcontains $_.Name } |
            ForEach-Object { $_.Name }
        )
    }

    # gamelist.xml
    $gamelistPath = Join-Path $RomFolder "gamelist.xml"
    $glFolders = @()   # nombres de carpeta referenciados por <path> en gamelist
    if (Test-Path $gamelistPath) {
        try {
            [xml]$doc = Get-Content $gamelistPath -Raw -Encoding UTF8
            foreach ($node in $doc.SelectNodes("/gameList/game/path")) {
                $p = ConvertTo-SCMComparablePath $node.InnerText   # carpeta/fichero
                $segs = @($p -split "/" | Where-Object { $_ -ne "" })
                if ($segs.Count -eq 0) { continue }
                # Path en raiz ("./Foo.scummvm"): la "carpeta" es el nombre sin
                # extension (misma clave que usa el borrado de huerfanos).
                $seg = if ($segs.Count -ge 2) { $segs[0] } else { [System.IO.Path]::GetFileNameWithoutExtension($segs[0]) }
                if ($seg) { $glFolders += $seg }
            }
        }
        catch { }
    }
    $glFoldersLower = @($glFolders | ForEach-Object { $_.ToLowerInvariant() })

    # --- Por juego (de la base de datos) ---
    $perGame = @()
    foreach ($g in $Games) {
        $folder = Split-Path $g.FullPath -Leaf
        $folderExists = Test-Path $g.FullPath
        $hasScummvm = $false
        if ($folderExists) {
            $hasScummvm = @(Get-ChildItem -Path $g.FullPath -Filter *.scummvm -File -ErrorAction SilentlyContinue).Count -gt 0
        }
        $hasEntry = $glFoldersLower -contains $folder.ToLowerInvariant()
        $media = Get-SCMMediaStatus -Index $mediaIndex -FolderName $folder

        $perGame += [PSCustomObject]@{
            Title = $g.DisplayTitle; Folder = $folder; ShortID = $g.ShortID
            FolderExists = $folderExists; HasScummvm = $hasScummvm; HasEntry = $hasEntry
            Media = $media
        }
    }

    # --- Duplicados (mismo ShortID en varias carpetas) ---
    $dups = @()
    foreach ($grp in ($Games | Group-Object ShortID)) {
        if ($grp.Count -gt 1) {
            $folders = @($grp.Group | ForEach-Object { Split-Path $_.FullPath -Leaf })
            $dups += [PSCustomObject]@{ ShortID = $grp.Name; Folders = $folders }
        }
    }

    # --- Carpetas de juego SIN .scummvm ---
    $noScummvm = @()
    foreach ($f in $diskFolders) {
        $p = Join-Path $RomFolder $f
        $has = @(Get-ChildItem -Path $p -Filter *.scummvm -File -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $has) { $noScummvm += $f }
    }

    # --- Entradas de gamelist sin carpeta en disco ---
    $diskLower = @($diskFolders | ForEach-Object { $_.ToLowerInvariant() })
    $orphanEntries = @($glFolders | Where-Object { $diskLower -notcontains $_.ToLowerInvariant() } | Select-Object -Unique)

    # --- Media huerfana (ficheros que no casan con ninguna carpeta) ---
    $orphanMedia = @()
    foreach ($mf in $script:SCMDoctorMediaRoots) {
        $dir = Join-Path $RomFolder $mf
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $fn = $_.Name
            $matched = $false
            foreach ($folder in $diskFolders) {
                if ($fn.StartsWith("$folder-", [System.StringComparison]::OrdinalIgnoreCase)) { $matched = $true; break }
            }
            if (-not $matched) { $orphanMedia += (Join-Path $mf $fn) }
        }
    }

    # --- Media faltante (juegos sin image/video/manual) ---
    $missingMedia = @($perGame | Where-Object { $_.Media.Missing.Count -gt 0 })

    return [PSCustomObject]@{
        ScummvmOk     = $scummvmOk
        RomOk         = $romOk
        ScummvmPath   = $config.Paths.ScummVM
        RomFolder     = $RomFolder
        GameCount     = @($Games).Count
        PerGame       = $perGame
        Duplicates    = $dups
        NoScummvm     = $noScummvm
        OrphanEntries = $orphanEntries
        OrphanMedia   = $orphanMedia
        MissingMedia  = $missingMedia
    }
}

function Show-SCMDoctorReport {
    param([Parameter(Mandatory)]$Report)

    Write-Host ""
    Show-SCMPanel -Title "Doctor - Health Check" -Lines @(
        ("ScummVM.exe : {0}" -f $(if ($Report.ScummvmOk) { "OK" } else { "MISSING" })),
        ("ROM folder  : {0}" -f $(if ($Report.RomOk) { "OK" } else { "MISSING" })),
        ("Games en DB : {0}" -f $Report.GameCount),
        "",
        ("Duplicados (ShortID)      : {0}" -f @($Report.Duplicates).Count),
        ("Carpetas sin .scummvm     : {0}" -f @($Report.NoScummvm).Count),
        ("Entradas gamelist sin dir : {0}" -f @($Report.OrphanEntries).Count),
        ("Media huerfana            : {0}" -f @($Report.OrphanMedia).Count),
        ("Juegos con media faltante : {0}" -f @($Report.MissingMedia).Count)
    )

    if (@($Report.Duplicates).Count -gt 0) {
        Write-Host ""
        Write-Host "  Duplicados (mismo ShortID en varias carpetas):" -ForegroundColor $global:SCMTheme.Warn
        foreach ($d in $Report.Duplicates) {
            Write-Host ("   - {0}: {1}" -f $d.ShortID, ($d.Folders -join " | ")) -ForegroundColor $global:SCMTheme.Dim
        }
    }
    if (@($Report.NoScummvm).Count -gt 0) {
        Write-Host ""
        Write-Host "  Carpetas SIN fichero .scummvm:" -ForegroundColor $global:SCMTheme.Warn
        foreach ($f in $Report.NoScummvm) { Write-Host ("   - {0}" -f $f) -ForegroundColor $global:SCMTheme.Dim }
    }
    if (@($Report.OrphanEntries).Count -gt 0) {
        Write-Host ""
        Write-Host "  Entradas de gamelist.xml sin carpeta en disco:" -ForegroundColor $global:SCMTheme.Warn
        foreach ($e in $Report.OrphanEntries) { Write-Host ("   - {0}" -f $e) -ForegroundColor $global:SCMTheme.Dim }
    }
    if (@($Report.OrphanMedia).Count -gt 0) {
        Write-Host ""
        Write-Host ("  Media huerfana ({0}) - no casa con ninguna carpeta:" -f @($Report.OrphanMedia).Count) -ForegroundColor $global:SCMTheme.Warn
        foreach ($m in @($Report.OrphanMedia | Select-Object -First 20)) { Write-Host ("   - {0}" -f $m) -ForegroundColor $global:SCMTheme.Dim }
        if (@($Report.OrphanMedia).Count -gt 20) { Write-Host "   ... (mas)" -ForegroundColor $global:SCMTheme.Dim }
    }
    if (@($Report.MissingMedia).Count -gt 0) {
        Write-Host ""
        Write-Host "  Juegos con media faltante (para scrapear):" -ForegroundColor $global:SCMTheme.Warn
        foreach ($g in @($Report.MissingMedia | Select-Object -First 30)) {
            Write-Host ("   - {0}  (falta: {1})" -f $g.Title, ($g.Media.Missing -join ", ")) -ForegroundColor $global:SCMTheme.Dim
        }
        if (@($Report.MissingMedia).Count -gt 30) { Write-Host "   ... (mas)" -ForegroundColor $global:SCMTheme.Dim }
    }

    if (@($Report.Duplicates).Count -eq 0 -and @($Report.NoScummvm).Count -eq 0 -and
        @($Report.OrphanEntries).Count -eq 0 -and @($Report.OrphanMedia).Count -eq 0 -and
        @($Report.MissingMedia).Count -eq 0 -and $Report.ScummvmOk -and $Report.RomOk) {
        Write-Host ""
        Write-Host "  Todo en orden. Coleccion sana." -ForegroundColor $global:SCMTheme.Ok
    }
}

# Exporta la lista de juegos con media faltante a un .txt (para scrapear fuera).
function Export-SCMMissingMediaList {
    param([Parameter(Mandatory)]$Report, [Parameter(Mandatory)][string]$Path)
    $lines = foreach ($g in $Report.MissingMedia) {
        "{0}`t{1}`tfalta: {2}" -f $g.Folder, $g.Title, ($g.Media.Missing -join ",")
    }
    Set-Content -Path $Path -Value $lines -Encoding UTF8
    return @($Report.MissingMedia).Count
}

# Limpia huerfanos: media que no casa con ninguna carpeta + entradas de
# gamelist sin carpeta en disco. Dry-run por defecto; con -Apply borra/quita.
function Invoke-SCMCleanOrphans {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder,
        [switch]$Apply
    )

    $rep = Get-SCMDoctorReport -Games $Games -RomFolder $RomFolder
    $media   = @($rep.OrphanMedia)
    $entries = @($rep.OrphanEntries)

    Write-Host ""
    Show-SCMPanel -Title "Limpiar huerfanos" -Lines @(
        ("Media huerfana         : {0}" -f $media.Count),
        ("Entradas gamelist sin dir: {0}" -f $entries.Count)
    )
    foreach ($m in @($media | Select-Object -First 40)) { Write-Host ("   media  - {0}" -f $m) -ForegroundColor $global:SCMTheme.Dim }
    foreach ($e in $entries) { Write-Host ("   entry  - {0}" -f $e) -ForegroundColor $global:SCMTheme.Dim }

    if ($media.Count -eq 0 -and $entries.Count -eq 0) {
        Write-Host ""
        Write-Host "  Nada que limpiar." -ForegroundColor $global:SCMTheme.Ok
        return
    }
    if (-not $Apply) {
        Write-Host ""
        Write-Host "  (dry-run: no se ha borrado nada)" -ForegroundColor $global:SCMTheme.Warn
        return
    }

    $gamelistPath = Join-Path $RomFolder "gamelist.xml"
    Backup-SCMGamelist -Path $gamelistPath | Out-Null

    $delMedia = 0
    foreach ($m in $media) {
        $p = Join-Path $RomFolder $m
        if (Test-Path $p) { try { Remove-Item $p -Force -ErrorAction Stop; $delMedia++ } catch { } }
    }

    $delEntries = 0
    if ((Test-Path $gamelistPath) -and $entries.Count -gt 0) {
        $doc = Get-SCMGamelistDocument -Path $gamelistPath
        # Borrar comparando el PRIMER SEGMENTO del <path> real (los huerfanos se
        # detectaron asi). El match exacto "carpeta/carpeta.scummvm" se saltaba
        # paths en raiz o con fichero de otro nombre: se contaban pero no se
        # borraban nunca.
        $entriesLower = @($entries | ForEach-Object { $_.ToLowerInvariant() })
        foreach ($game in @($doc.SelectNodes("/gameList/game"))) {
            $pathNode = $game.SelectSingleNode("path")
            if ($null -eq $pathNode) { continue }
            $p = ConvertTo-SCMComparablePath $pathNode.InnerText
            $segs = @($p -split "/" | Where-Object { $_ -ne "" })
            if ($segs.Count -eq 0) { continue }
            $key = if ($segs.Count -ge 2) { $segs[0] } else { [System.IO.Path]::GetFileNameWithoutExtension($segs[0]) }
            if ($entriesLower -contains $key.ToLowerInvariant()) {
                [void]$game.ParentNode.RemoveChild($game); $delEntries++
            }
        }
        Save-SCMGamelistDocument -Doc $doc -Path $gamelistPath
    }

    Write-Host ""
    Write-Host ("  Borrados: {0} ficheros de media, {1} entradas de gamelist." -f $delMedia, $delEntries) -ForegroundColor $global:SCMTheme.Ok
}

Export-ModuleMember -Function Get-SCMDoctorReport, Show-SCMDoctorReport, Export-SCMMissingMediaList, Invoke-SCMCleanOrphans

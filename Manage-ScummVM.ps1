Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path $PSCommandPath

# -DisableNameChecking silencia el aviso de "verbos no aprobados" (Pause-SCM).
Import-Module "$Root\Modules\UI\Theme.psm1"            -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\Core.psm1"           -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\Config.psm1"         -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\Logger.psm1"         -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\LibraryCleaner.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\NameSanitizer.psm1"  -Force -DisableNameChecking

Import-Module "$Root\Modules\Library\Scanner.psm1"         -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Parser.psm1"          -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Metadata.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\CollectionStats.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Fallback.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\EditionAdvisor.psm1"  -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\MediaStatus.psm1"     -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\ImportStatus.psm1"    -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\MediaFinder.psm1"     -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Exporter.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Repair\Doctor.psm1"           -Force -DisableNameChecking

Import-Module "$Root\Modules\Database\Database.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Definitions\Definitions.psm1"  -Force -DisableNameChecking

Import-Module "$Root\Modules\UI\Selector.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\UI\Browser.psm1"  -Force -DisableNameChecking

Import-Module "$Root\Modules\Repair\Validator.psm1" -Force -DisableNameChecking

Import-Module "$Root\Modules\Frontend\GamelistXml.psm1"     -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\FrontendSync.psm1"    -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\BundleAssistant.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\WindowsLinker.psm1"   -Force -DisableNameChecking

$config = Get-Content "$Root\config.json" -Raw | ConvertFrom-Json

# Encoding + charset (UTF-8 o fallback ASCII) + acento de color.
$useUnicode = $true
$accent = "Cyan"
if ($config.Preferences.PSObject.Properties.Name -contains "UI") {
    if ($config.Preferences.UI.PSObject.Properties.Name -contains "Unicode") {
        $useUnicode = [bool]$config.Preferences.UI.Unicode
    }
    if ($config.Preferences.UI.PSObject.Properties.Name -contains "Accent") {
        $accent = [string]$config.Preferences.UI.Accent
    }
}
Initialize-SCMConsole -Unicode $useUnicode -Accent $accent

function Get-SCMStatusHeader {
    $scummvmStatus = if (Test-Path $config.Paths.ScummVM) { "Found" } else { "MISSING" }
    return @(
        ("ScummVM  : {0}" -f $scummvmStatus),
        ("ROM Path : {0}" -f $config.Paths.RomFolder)
    )
}

# --- opcion: Sync Frontend -------------------------------------------

function Invoke-SCMSyncFrontendMenu {

    while ($true) {

        $choice = Show-SCMMenu -Title "Sync Frontend" -Header (Get-SCMStatusHeader) -Options @(
            "Detect NEW games (create .scummvm + gamelist entry)",
            "Fix EXISTING naming (rename + update gamelist)",
            "Dry-run report only (no changes)",
            "Undo last Sync (revertir el ultimo)"
        )

        switch ($choice) {
            0 { Invoke-SCMSyncRun -Mode "New" }
            1 { Invoke-SCMSyncRun -Mode "Existing" }
            2 { Invoke-SCMSyncRun -Mode "All" -DryRunOnly }
            3 { Invoke-SCMUndoRun }
            default { return }
        }
    }
}

function Invoke-SCMSyncRun {
    param(
        [ValidateSet("New", "Existing", "All")]
        [string]$Mode,
        [switch]$DryRunOnly
    )

    Show-SCMHeader $config.Application.Version

    $Games = @(Get-SCMDatabase)
    if ($Games.Count -eq 0) {
        Write-Host "  Database is empty. Run 'Scan Collection' first." -ForegroundColor $global:SCMTheme.Warn
        Pause-SCM
        return
    }

    # Deteccion de respaldo por nombre: incorpora carpetas que --detect no
    # reconocio pero que SI estan en KnownGames.json (solo para alta/dry-run).
    if ($Mode -ne "Existing") {
        $fb = Expand-SCMGamesWithFallback -Games $Games -RomFolder $config.Paths.RomFolder
        $Games = @($fb.Games)
        if (@($fb.Unidentified).Count -gt 0) {
            Write-Host ""
            Write-Host ("  Carpetas NO identificadas ({0}) - anade su ID en Definitions\KnownGames.json:" -f @($fb.Unidentified).Count) -ForegroundColor $global:SCMTheme.Warn
            foreach ($u in $fb.Unidentified) {
                Write-Host ("    - {0}" -f $u) -ForegroundColor $global:SCMTheme.Dim
            }
        }
    }

    $plan = @(Get-SCMFrontendPlan -Games $Games -RomFolder $config.Paths.RomFolder -Mode $Mode)
    Show-SCMFrontendPlanReport -Plan $plan

    if ($DryRunOnly) {
        Pause-SCM
        return
    }

    $actionable = @($plan | Where-Object { $_.Action -in @("Create", "Rename") })
    if ($actionable.Count -eq 0) {
        Pause-SCM
        return
    }

    # Alta: revisar el nombre propuesto de cada juego nuevo, con teclas rapidas.
    if ($Mode -eq "New") {
        $kept = @()
        foreach ($item in $actionable) {
            Write-Host ""
            Write-Host ("  New game: {0}" -f $item.Game.DisplayTitle) -ForegroundColor $global:SCMTheme.Title
            Write-Host ("  Current folder : {0}" -f $item.OldFolderName) -ForegroundColor $global:SCMTheme.Dim
            Write-Host ("  Proposed       : {0}" -f $item.NewFolderName) -ForegroundColor $global:SCMTheme.Menu
            Write-Host "  [Enter]=usar propuesto   [k]=mantener actual   [s]=saltar   o escribe un nombre" -ForegroundColor $global:SCMTheme.Dim
            $edit = Read-Host "  >"

            $t = $edit.Trim()
            if ($t -eq "s" -or $t -eq "S") {
                # Saltar: no se incluye en la lista final.
                continue
            }
            elseif ($t -eq "k" -or $t -eq "K") {
                # Mantener el nombre actual (sin renombrar).
                $item.NewFolderName = $item.OldFolderName
                $item.NewFolderPath = $item.OldFolderPath
            }
            elseif (-not [string]::IsNullOrWhiteSpace($t)) {
                $clean = ConvertTo-SCMSafeFileName -Title $t
                if (-not [string]::IsNullOrWhiteSpace($clean)) {
                    # Anti-colision: contra carpetas existentes en disco Y contra
                    # nombres ya asignados en esta misma pasada (dos juegos con el
                    # mismo nombre tecleado romperian el segundo Rename-Item).
                    $taken = @()
                    try { $taken += @(Get-ChildItem -Path $config.Paths.RomFolder -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch { }
                    $taken += @($kept | ForEach-Object { $_.NewFolderName })
                    $taken = @($taken | Where-Object { $_ -and $_ -ne $item.OldFolderName })
                    $clean = Resolve-SCMUniqueName -BaseName $clean -ExistingNames $taken
                    $item.NewFolderName = $clean
                    $item.NewFolderPath = Join-Path $config.Paths.RomFolder $clean
                }
            }
            # Enter (vacio) = aceptar el propuesto tal cual.
            $kept += $item
        }
        $actionable = @($kept)
    }

    if ($actionable.Count -eq 0) {
        Write-Host ""
        Write-Host "  Nada que aplicar (todo saltado)." -ForegroundColor $global:SCMTheme.Dim
        Pause-SCM
        return
    }

    Write-Host ""
    Write-Host ("  This will modify {0} folder(s) and rewrite gamelist.xml." -f $actionable.Count) -ForegroundColor $global:SCMTheme.Warn
    $confirm = Read-Host "  Type YES to apply these changes"
    if ($confirm -ne "YES") {
        Write-Host "  Cancelled." -ForegroundColor $global:SCMTheme.Dim
        Pause-SCM
        return
    }

    $gamelistPath = Join-Path $config.Paths.RomFolder "gamelist.xml"
    Invoke-SCMFrontendSync -Plan $actionable -RomFolder $config.Paths.RomFolder -GamelistPath $gamelistPath -Confirm:$false
    Pause-SCM
}

function Invoke-SCMUndoRun {
    Show-SCMHeader $config.Application.Version
    $log = Get-SCMLastSyncLog
    if ([string]::IsNullOrEmpty($log)) {
        Write-Host "  No hay ningun Sync que deshacer." -ForegroundColor $global:SCMTheme.Warn
        Pause-SCM
        return
    }
    Write-Host ("  Ultimo Sync: {0}" -f (Split-Path $log -Leaf)) -ForegroundColor $global:SCMTheme.Dim
    Write-Host "  Esto revertira renombrados y quitara entradas anadidas al gamelist." -ForegroundColor $global:SCMTheme.Warn
    $confirm = Read-Host "  Type YES to undo"
    if ($confirm -ne "YES") {
        Write-Host "  Cancelled." -ForegroundColor $global:SCMTheme.Dim
        Pause-SCM
        return
    }
    $gamelistPath = Join-Path $config.Paths.RomFolder "gamelist.xml"
    Invoke-SCMUndoLastSync -RomFolder $config.Paths.RomFolder -GamelistPath $gamelistPath -LogPath $log -Confirm:$false
    Pause-SCM
}

# --- opcion: Tools & Maintenance -------------------------------------

function Invoke-SCMToolsMenu {

    while ($true) {
        $choice = Show-SCMMenu -Title "Tools & Maintenance" -Header (Get-SCMStatusHeader) -Options @(
            "Doctor (health check: duplicados, huerfanos, media)",
            "Export collection to CSV",
            "Export collection to HTML",
            "Export missing-media list (para scrapear)",
            "Clean orphans (borrar media/entradas huerfanas)",
            "Restore gamelist backup",
            "Bundle Assistant (separar carpetas con varios juegos)",
            "Media Finder (buscar portada/snap/video por juego)",
            "Auto-descargar portadas (SteamGridDB)",
            "Auto-descargar marquees/logos (SteamGridDB)",
            "Generar miniaturas faltantes (desde portada)",
            "Import Status (carpetas no importadas / sin .scummvm)",
            "Windows Linker (juegos no-ScummVM -> roms\windows)"
        )

        switch ($choice) {
            0 {
                Show-SCMHeader $config.Application.Version
                $games = @(Get-SCMDatabase)
                if ($games.Count -eq 0) { Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn }
                else {
                    $rep = Get-SCMDoctorReport -Games $games -RomFolder $config.Paths.RomFolder
                    Show-SCMDoctorReport -Report $rep
                }
                Pause-SCM
            }
            1 { Invoke-SCMExportRun -Format "CSV" }
            2 { Invoke-SCMExportRun -Format "HTML" }
            3 {
                Show-SCMHeader $config.Application.Version
                $games = @(Get-SCMDatabase)
                if ($games.Count -eq 0) { Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn }
                else {
                    $rep = Get-SCMDoctorReport -Games $games -RomFolder $config.Paths.RomFolder
                    $out = Join-Path $config.Paths.Logs ("MissingMedia_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
                    $n = Export-SCMMissingMediaList -Report $rep -Path $out
                    Write-Host ("  {0} juegos con media faltante -> {1}" -f $n, $out) -ForegroundColor $global:SCMTheme.Ok
                }
                Pause-SCM
            }
            4 { Invoke-SCMCleanOrphansRun }
            5 { Invoke-SCMRestoreBackupRun }
            6 {
                Show-SCMHeader $config.Application.Version
                $games = @(Get-SCMDatabase)
                if ($games.Count -eq 0) { Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn }
                else { Invoke-SCMBundleAssistant -Games $games -RomFolder $config.Paths.RomFolder }
                Pause-SCM
            }
            7 { Invoke-SCMMediaFinderRun }
            8 { Invoke-SCMSteamGridRun -Kind "cover" }
            9 { Invoke-SCMSteamGridRun -Kind "marquee" }
            10 {
                Show-SCMHeader $config.Application.Version
                $games = @(Get-SCMDatabase)
                if ($games.Count -eq 0) { Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn }
                else { Invoke-SCMGenerateThumbnails -Games $games -RomFolder $config.Paths.RomFolder }
                Pause-SCM
            }
            11 {
                Show-SCMHeader $config.Application.Version
                $games = @(Get-SCMDatabase)
                if ($games.Count -eq 0) { Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn }
                else {
                    $importStatus = Get-SCMImportStatus -Games $games -RomFolder $config.Paths.RomFolder
                    Show-SCMImportStatusReport -Status $importStatus
                }
                Pause-SCM
            }
            12 {
                Show-SCMHeader $config.Application.Version
                $games = @(Get-SCMDatabase)
                Invoke-SCMWindowsLinker -Games $games -RomFolder $config.Paths.RomFolder
                Pause-SCM
            }
            default { return }
        }
    }
}

function Invoke-SCMCleanOrphansRun {
    Show-SCMHeader $config.Application.Version
    $games = @(Get-SCMDatabase)
    # dry-run primero
    Invoke-SCMCleanOrphans -Games $games -RomFolder $config.Paths.RomFolder
    $rep = Get-SCMDoctorReport -Games $games -RomFolder $config.Paths.RomFolder
    if (@($rep.OrphanMedia).Count -eq 0 -and @($rep.OrphanEntries).Count -eq 0) { Pause-SCM; return }
    Write-Host ""
    $confirm = Read-Host "  Type YES to delete orphans"
    if ($confirm -eq "YES") {
        Invoke-SCMCleanOrphans -Games $games -RomFolder $config.Paths.RomFolder -Apply
    }
    else { Write-Host "  Cancelled." -ForegroundColor $global:SCMTheme.Dim }
    Pause-SCM
}

function Invoke-SCMRestoreBackupRun {
    Show-SCMHeader $config.Application.Version
    $backups = @(Get-SCMGamelistBackups -RomFolder $config.Paths.RomFolder)
    if ($backups.Count -eq 0) {
        Write-Host "  No hay backups de gamelist (.bak) todavia." -ForegroundColor $global:SCMTheme.Warn
        Pause-SCM
        return
    }
    $labels = @($backups | ForEach-Object { "{0}  ({1})" -f $_.Name, $_.LastWriteTime })
    $sel = Show-SCMSelector -Title "Restaurar backup de gamelist" -Items $labels
    if ($sel -lt 0) { return }
    Write-Host ""
    Write-Host "  Se guardara una copia del gamelist actual antes de restaurar." -ForegroundColor $global:SCMTheme.Dim
    $confirm = Read-Host ("  Type YES para restaurar '{0}'" -f $backups[$sel].Name)
    if ($confirm -eq "YES") {
        Restore-SCMGamelistBackup -BackupPath $backups[$sel].FullName -GamelistPath (Join-Path $config.Paths.RomFolder "gamelist.xml")
    }
    else { Write-Host "  Cancelled." -ForegroundColor $global:SCMTheme.Dim }
    Pause-SCM
}

# Asistente de busqueda de media: elige juego -> enlaces + rutas destino.
function Invoke-SCMMediaFinderRun {
    $games = @(Get-SCMDatabase)
    if ($games.Count -eq 0) {
        Show-SCMHeader $config.Application.Version
        Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn
        Pause-SCM
        return
    }

    $mi = Get-SCMMediaIndex -RomFolder $config.Paths.RomFolder
    # Priorizar los que les falta media, pero permitir todos.
    $sorted = @($games | Sort-Object DisplayTitle)

    while ($true) {
        $items = Get-SCMBrowseItems -Games $sorted -MediaIndex $mi
        $sel = Show-SCMSelector -Title "Media Finder - elige juego (verde=completa)" -Items $items.Texts -ItemColors $items.Colors
        if ($sel -lt 0) { return }

        $g = $sorted[$sel]
        $folder = Split-Path $g.FullPath -Leaf
        $links = Get-SCMMediaSearchLinks -Title $g.Title
        $targets = Get-SCMMediaTargets -FolderName $folder

        while ($true) {
            Show-SCMHeader $config.Application.Version
            $lines = @("Busquedas:")
            foreach ($k in $links.Keys) { $lines += ("  {0,-16}: {1}" -f $k, $links[$k]) }
            $lines += ""
            $lines += "Guarda el fichero (en la raiz de ROMs) como:"
            foreach ($k in $targets.Keys) { $lines += ("  {0,-15}: {1}" -f $k, $targets[$k]) }
            Show-SCMPanel -Title $g.DisplayTitle -Lines $lines

            $opt = Show-SCMMenu -Title "Abrir busqueda en el navegador" -Options @(
                "Abrir Google Imagenes",
                "Abrir YouTube (longplay)",
                "Abrir SteamGridDB",
                "Abrir MobyGames",
                "Abrir TODAS"
            )
            switch ($opt) {
                0 { Start-Process $links["Google Imagenes"] }
                1 { Start-Process $links["YouTube longplay"] }
                2 { Start-Process $links["SteamGridDB"] }
                3 { Start-Process $links["MobyGames"] }
                4 { foreach ($u in $links.Values) { Start-Process $u } }
                default { break }
            }
            if ($opt -lt 0) { break }
        }
    }
}

# Descarga automatica de arte via SteamGridDB (requiere API key).
# $Kind: "cover" (portada -> images) o "marquee" (logo -> marquees).
function Invoke-SCMSteamGridRun {
    param([ValidateSet("cover", "marquee")][string]$Kind = "cover")

    Show-SCMHeader $config.Application.Version
    $key = Get-SCMSteamGridKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        Show-SCMPanel -Title "SteamGridDB - falta API key" -Lines @(
            "Para descargar arte automaticamente necesitas una",
            "API key GRATUITA de SteamGridDB:",
            "",
            "1. Registrate en https://www.steamgriddb.com",
            "2. Perfil -> Preferences -> API -> genera una key.",
            "3. Pegala en config.json en Preferences.ApiKeys.SteamGridDB",
            "   (o desde Settings, si lo prefieres a mano)."
        )
        Pause-SCM
        return
    }

    $games = @(Get-SCMDatabase)
    if ($games.Count -eq 0) {
        Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn
        Pause-SCM
        return
    }

    $what = if ($Kind -eq "marquee") { "marquees/logos" } else { "portadas" }
    Write-Host ("  Buscando coincidencias en SteamGridDB para {0}..." -f $what) -ForegroundColor $global:SCMTheme.Dim
    $matches = @(Get-SCMSteamGridMatches -Games $games -RomFolder $config.Paths.RomFolder -Key $key -Kind $Kind)

    if ($matches.Count -eq 0) {
        Write-Host ("  No hay juegos sin {0}." -f $what) -ForegroundColor $global:SCMTheme.Ok
        Pause-SCM
        return
    }

    # Preview de coincidencias.
    Write-Host ""
    Write-Host ("  Coincidencias ({0}):" -f $matches.Count) -ForegroundColor $global:SCMTheme.Title
    foreach ($m in @($matches | Select-Object -First 40)) {
        $col = if ($null -eq $m.MatchId) { $global:SCMTheme.Warn } else { $global:SCMTheme.Dim }
        Write-Host ("   {0,-30} -> {1}" -f $m.Folder, $m.MatchName) -ForegroundColor $col
    }
    if ($matches.Count -gt 40) { Write-Host "   ... (mas)" -ForegroundColor $global:SCMTheme.Dim }

    $withMatch = @($matches | Where-Object { $null -ne $_.MatchId })
    Write-Host ""
    Write-Host ("  Se descargara arte para {0} de {1}. Revisa que las coincidencias sean correctas." -f $withMatch.Count, $matches.Count) -ForegroundColor $global:SCMTheme.Warn
    $confirm = Read-Host "  Type YES to download"
    if ($confirm -ne "YES") {
        Write-Host "  Cancelled." -ForegroundColor $global:SCMTheme.Dim
        Pause-SCM
        return
    }
    Invoke-SCMSteamGridDownloadFromMatches -Matches $withMatch -RomFolder $config.Paths.RomFolder -Key $key -Kind $Kind | Out-Null
    Pause-SCM
}

function Invoke-SCMExportRun {
    param([ValidateSet("CSV", "HTML")][string]$Format)
    Show-SCMHeader $config.Application.Version
    $games = @(Get-SCMDatabase)
    if ($games.Count -eq 0) {
        Write-Host "  Database vacia. Haz Scan primero." -ForegroundColor $global:SCMTheme.Warn
        Pause-SCM
        return
    }
    $mi = Get-SCMMediaIndex -RomFolder $config.Paths.RomFolder
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    if ($Format -eq "CSV") {
        $out = Join-Path $config.Paths.Logs ("Collection_{0}.csv" -f $stamp)
        $n = Export-SCMCollectionCsv -Games $games -Path $out -MediaIndex $mi
    }
    else {
        $out = Join-Path $config.Paths.Logs ("Collection_{0}.html" -f $stamp)
        $n = Export-SCMCollectionHtml -Games $games -Path $out -MediaIndex $mi
    }
    Write-Host ("  Exportados {0} juegos -> {1}" -f $n, $out) -ForegroundColor $global:SCMTheme.Ok
    Pause-SCM
}

# --- opcion: Settings -------------------------------------------------

function Get-SCMOnOff {
    param([bool]$Value)
    if ($Value) { "On" } else { "Off" }
}

function Get-SCMUnicodePref {
    $p = $config.Preferences
    if (($p.PSObject.Properties.Name -contains "UI") -and
        ($p.UI.PSObject.Properties.Name -contains "Unicode")) {
        return [bool]$p.UI.Unicode
    }
    return $true
}

function Update-SCMBoolPref {
    param([Parameter(Mandatory)][string]$Name)
    $config.Preferences.$Name = -not [bool]$config.Preferences.$Name
    Set-SCMConfig -Config $config
    $script:config = Get-SCMConfig
}

function Get-SCMAccentPref {
    $p = $config.Preferences
    if (($p.PSObject.Properties.Name -contains "UI") -and
        ($p.UI.PSObject.Properties.Name -contains "Accent")) {
        return [string]$p.UI.Accent
    }
    return "Cyan"
}

function Set-SCMNextAccent {
    $order = @("Cyan", "Green", "Magenta", "Yellow", "Blue")
    $cur = Get-SCMAccentPref
    $i = [array]::IndexOf($order, $cur)
    if ($i -lt 0) { $i = 0 }
    $next = $order[($i + 1) % $order.Count]
    if ($config.Preferences.UI.PSObject.Properties.Name -notcontains "Accent") {
        $config.Preferences.UI | Add-Member -NotePropertyName Accent -NotePropertyValue $next -Force
    }
    else {
        $config.Preferences.UI.Accent = $next
    }
    Set-SCMConfig -Config $config
    $script:config = Get-SCMConfig
    Set-SCMAccent -Name $next
}

function Invoke-SCMEditPaths {
    Show-SCMHeader $config.Application.Version
    Show-SCMPanel -Title "Editar rutas" -Lines @(
        ("ScummVM   : {0}" -f $config.Paths.ScummVM),
        ("ROM folder: {0}" -f $config.Paths.RomFolder),
        "",
        "Enter = mantener la actual. Puedes usar ruta absoluta.",
        "(ScummVM relativa 'Bin\ScummVM\scummvm.exe' = dentro del proyecto)"
    )
    Write-Host ""
    $sv = Read-Host "  Ruta a scummvm.exe"
    if (-not [string]::IsNullOrWhiteSpace($sv)) {
        Update-SCMConfigPath -Name "ScummVM" -Value $sv.Trim('"')
    }
    $rf = Read-Host "  Carpeta de ROMs"
    if (-not [string]::IsNullOrWhiteSpace($rf)) {
        Update-SCMConfigPath -Name "RomFolder" -Value $rf.Trim('"')
    }
    $script:config = Get-SCMConfig

    # Crear carpetas internas si faltan.
    foreach ($p in @($config.Paths.Logs, $config.Paths.Database, $config.Paths.Definitions)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }

    Write-Host ""
    Write-Host ("  ScummVM   : {0}  [{1}]" -f $config.Paths.ScummVM, $(if (Test-Path $config.Paths.ScummVM) { "OK" } else { "no existe" })) -ForegroundColor $global:SCMTheme.Dim
    Write-Host ("  ROM folder: {0}  [{1}]" -f $config.Paths.RomFolder, $(if (Test-Path $config.Paths.RomFolder) { "OK" } else { "no existe" })) -ForegroundColor $global:SCMTheme.Dim
    Pause-SCM
}

function Invoke-SCMFirstRunWizard {
    Invoke-SCMEditPaths
}

function Show-SCMConfigPanel {
    Show-SCMHeader $config.Application.Version
    $p = $config.Preferences
    Show-SCMPanel -Title "Configuration" -Lines @(
        "PATHS",
        ("  ScummVM     : {0}" -f $config.Paths.ScummVM),
        ("  ROM folder  : {0}" -f $config.Paths.RomFolder),
        ("  Database    : {0}" -f $config.Paths.Database),
        ("  Definitions : {0}" -f $config.Paths.Definitions),
        ("  Logs        : {0}" -f $config.Paths.Logs),
        "",
        "PREFERENCES",
        ("  Languages   : {0}" -f ($p.Languages -join ", ")),
        ("  Platforms   : {0}" -f ($p.Platforms -join ", ")),
        ("  Max name len: {0}" -f $p.MaxFolderNameLength)
    )
    Write-Host ""
    Write-Host "  (Rutas editables en Settings -> Edit paths)" -ForegroundColor $global:SCMTheme.Dim
    Pause-SCM
}

function Invoke-SCMSettingsMenu {

    while ($true) {

        $p = $config.Preferences

        $choice = Show-SCMMenu -Title "Settings" -Header (Get-SCMStatusHeader) -Options @(
            ("Unicode boxes/arrows    [{0}]" -f (Get-SCMOnOff (Get-SCMUnicodePref))),
            ("Theme accent            [{0}]" -f (Get-SCMAccentPref)),
            ("Prefer CD editions      [{0}]" -f (Get-SCMOnOff ([bool]$p.PreferCD))),
            ("Prefer Talkie editions  [{0}]" -f (Get-SCMOnOff ([bool]$p.PreferTalkie))),
            ("Prefer Restored         [{0}]" -f (Get-SCMOnOff ([bool]$p.PreferRestored))),
            ("Ignore Demos            [{0}]" -f (Get-SCMOnOff ([bool]$p.IgnoreDemo))),
            ("Ignore Unknown          [{0}]" -f (Get-SCMOnOff ([bool]$p.IgnoreUnknown))),
            "Edit paths (ROM folder / ScummVM)",
            "View full configuration"
        )

        switch ($choice) {
            0 {
                $config.Preferences.UI.Unicode = -not (Get-SCMUnicodePref)
                Set-SCMConfig -Config $config
                $script:config = Get-SCMConfig
                Initialize-SCMConsole -Unicode (Get-SCMUnicodePref) -Accent (Get-SCMAccentPref)
            }
            1 { Set-SCMNextAccent }
            2 { Update-SCMBoolPref -Name "PreferCD" }
            3 { Update-SCMBoolPref -Name "PreferTalkie" }
            4 { Update-SCMBoolPref -Name "PreferRestored" }
            5 { Update-SCMBoolPref -Name "IgnoreDemo" }
            6 { Update-SCMBoolPref -Name "IgnoreUnknown" }
            7 { Invoke-SCMEditPaths }
            8 { Show-SCMConfigPanel }
            default { return }
        }
    }
}

# --- asistente de primer arranque si faltan rutas --------------------

if ((-not (Test-Path $config.Paths.ScummVM)) -or (-not (Test-Path $config.Paths.RomFolder))) {
    Invoke-SCMFirstRunWizard
}

# --- bucle principal --------------------------------------------------

:mainLoop while ($true) {

    $choice = Show-SCMMenu -Title "Main Menu" -Header (Get-SCMStatusHeader) -Options @(
        "Scan Collection",
        "Browse Collection",
        "Validate Collection",
        "Sync Frontend (New Games / Fix Naming)",
        "Edition Advisor (check for better versions)",
        "Tools & Maintenance (Doctor / Export / Bundles)",
        "Help (como usar)",
        "Settings",
        "About"
    )

    switch ($choice) {

        0 {
            Show-SCMHeader $config.Application.Version
            $Games = Invoke-SCMScan
            if ($Games) {
                Update-SCMDefinitions -Games $Games
            }
            Pause-SCM
        }

        1 {
            $Games = @(Get-SCMDatabase)
            if ($Games.Count -eq 0) {
                Show-SCMHeader $config.Application.Version
                Write-Host "  Database is empty." -ForegroundColor $global:SCMTheme.Warn
                Pause-SCM
            }
            else {
                Show-SCMBrowseMenu -Games $Games
            }
        }

        2 {
            Show-SCMHeader $config.Application.Version
            $Games = @(Get-SCMDatabase)
            if ($Games.Count -eq 0) {
                Write-Host "  Database is empty." -ForegroundColor $global:SCMTheme.Warn
            }
            else {
                Test-SCMCollection -Games $Games
            }
            Pause-SCM
        }

        3 {
            Invoke-SCMSyncFrontendMenu
        }

        4 {
            Show-SCMHeader $config.Application.Version
            $Games = @(Get-SCMDatabase)
            Show-SCMEditionAdvisor -Games $Games
            Pause-SCM
        }

        5 {
            Invoke-SCMToolsMenu
        }

        6 {
            Show-SCMHeader $config.Application.Version
            Show-SCMPanel -Title "Ayuda - flujo recomendado" -Lines @(
                "1. Scan           - detecta juegos y crea games.json",
                "2. Sync Frontend  - Dry-run primero; luego Detect NEW /",
                "                    Fix naming. Undo revierte el ultimo.",
                "3. Tools > Doctor - salud: duplicados, huerfanos, media",
                "4. Media Finder / Auto-portadas - rellenar imagenes",
                "5. Tras renombrar, vuelve a Scan (cambian los nombres)",
                "",
                "Colores en Browse: verde=media completa, amarillo=parcial,",
                "gris=sin media. En listas: escribe para filtrar, Esc vuelve.",
                "",
                "Sync es SEGURO: dry-run + confirmacion YES + backup + Undo.",
                "Detalle completo en README.md."
            )
            Pause-SCM
        }

        7 {
            Invoke-SCMSettingsMenu
        }

        8 {
            Show-SCMHeader $config.Application.Version
            $author = "PaCo_El_FLaCo"
            if ($config.Application.PSObject.Properties.Name -contains "Author") {
                $author = $config.Application.Author
            }
            Show-SCMPanel -Title "About" -Lines @(
                "ScummVM Collection Manager",
                "",
                "Manage, browse and keep a ScummVM",
                "frontend collection in sync.",
                "",
                ("Created by " + $author),
                ("Version    " + $config.Application.Version)
            )
            Pause-SCM
        }

        default {
            # -1 = Esc en el menu principal = salir.
            break mainLoop
        }
    }
}

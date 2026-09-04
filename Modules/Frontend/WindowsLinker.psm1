Set-StrictMode -Version Latest

# =====================================================================
#  WindowsLinker.psm1 - juegos NO-ScummVM (nativos / Unity / Visionaire...)
#  para el sistema 'windows' de RetroBat.
#
#  Para las carpetas que ScummVM no detecta y que NO tienen un ID conocido
#  (es decir, no son juegos de ScummVM), crea un acceso directo .lnk dentro
#  de roms\windows apuntando al .exe del juego (los datos NO se mueven de su
#  sitio) y anade su entrada al gamelist.xml de esa carpeta. Asi RetroBat los
#  lanza como juegos de Windows sin duplicar gigas.
#
#  Requiere (cargados por el script principal): Config, Theme, ImportStatus,
#  GamelistXml (Get/Save/New/ConvertTo-SCMComparablePath), FrontendSync
#  (Backup-SCMGamelist).
# =====================================================================

# Fragmentos de nombre de .exe que NO son el juego (instaladores, runtimes,
# crash handlers...). Se comparan en minusculas con -like "*fragmento*".
$script:SCMExeNoise = @(
    'unins', 'setup', 'vcredist', 'vc_redist', 'dxsetup', 'dxwebsetup',
    'directx', 'dotnet', 'oalinst', 'unitycrashhandler', 'crashhandler',
    'crashpad', 'notification_helper', 'uninstall', 'redist'
)

# Carpeta 'windows' de RetroBat. Usa Paths.WindowsRomFolder del config si
# esta puesto; si no, la hermana 'windows' de la carpeta de ROMs de ScummVM.
function Get-SCMWindowsRomFolder {
    $cfg = Get-SCMConfig
    if ($cfg.Paths.PSObject.Properties.Name -contains "WindowsRomFolder") {
        $v = [string]$cfg.Paths.WindowsRomFolder
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            if ([System.IO.Path]::IsPathRooted($v)) { return $v }
            return (Join-Path (Get-SCMRoot) $v)
        }
    }
    $parent = Split-Path $cfg.Paths.RomFolder -Parent
    return (Join-Path $parent "windows")
}

# Normaliza un nombre para comparar exe vs carpeta: minusculas, solo a-z0-9.
function ConvertTo-SCMExeKey {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return ([regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Test-SCMExeNoise {
    param([string]$Name)
    $low = $Name.ToLowerInvariant()
    foreach ($n in $script:SCMExeNoise) {
        if ($low -like ("*" + $n + "*")) { return $true }
    }
    return $false
}

# De una lista de FileInfo .exe, elige el mas probable ejecutable del juego:
# 1) nombre == carpeta, 2) nombre empieza por la carpeta, 3) el mas grande.
function Select-SCMBestExe {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$List,
        [Parameter(Mandatory)][string]$FolderName
    )
    if (@($List).Count -eq 0) { return $null }
    $key = ConvertTo-SCMExeKey $FolderName

    $exact = @($List | Where-Object { (ConvertTo-SCMExeKey ([System.IO.Path]::GetFileNameWithoutExtension($_.Name))) -eq $key })
    if ($exact.Count -gt 0) { return $exact[0] }

    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $starts = @($List | Where-Object { (ConvertTo-SCMExeKey ([System.IO.Path]::GetFileNameWithoutExtension($_.Name))).StartsWith($key) })
        if ($starts.Count -gt 0) { return $starts[0] }
    }

    return (@($List | Sort-Object Length -Descending)[0])
}

# Busca el .exe principal de una carpeta de juego (raiz primero, luego
# recursivo), descartando instaladores/runtimes. Devuelve la ruta o $null.
function Find-SCMGameExe {
    param([Parameter(Mandatory)][string]$FolderPath)

    if (-not (Test-Path $FolderPath)) { return $null }
    $folderName = Split-Path $FolderPath -Leaf

    $rootExes = @(Get-ChildItem -Path $FolderPath -File -Filter *.exe -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-SCMExeNoise $_.Name) })
    $chosen = Select-SCMBestExe -List $rootExes -FolderName $folderName
    if ($null -ne $chosen) { return $chosen.FullName }

    $allExes = @(Get-ChildItem -Path $FolderPath -File -Filter *.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-SCMExeNoise $_.Name) })
    $chosen = Select-SCMBestExe -List $allExes -FolderName $folderName
    if ($null -ne $chosen) { return $chosen.FullName }

    return $null
}

# Crea (o sobreescribe) un acceso directo .lnk de Windows via WScript.Shell.
function New-SCMShortcut {
    param(
        [Parameter(Mandatory)][string]$LnkPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$WorkingDirectory
    )
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = Split-Path $TargetPath -Parent
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $sc = $shell.CreateShortcut($LnkPath)
        $sc.TargetPath = $TargetPath
        $sc.WorkingDirectory = $WorkingDirectory
        $sc.Save()
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# Lista TODOS los .exe de una carpeta para que el usuario elija. Orden:
# 1) raiz sin ruido, 2) raiz con ruido, 3) recursivos sin ruido, 4) recursivos
# con ruido. Sin duplicados. Asi el .exe del juego suele quedar el primero.
function Get-SCMFolderExes {
    param([Parameter(Mandatory)][string]$FolderPath)

    if (-not (Test-Path $FolderPath)) { return @() }

    $root = @(Get-ChildItem -Path $FolderPath -File -Filter *.exe -ErrorAction SilentlyContinue)
    $rec  = @(Get-ChildItem -Path $FolderPath -File -Filter *.exe -Recurse -ErrorAction SilentlyContinue)

    $buckets = @(
        @($root | Where-Object { -not (Test-SCMExeNoise $_.Name) }),
        @($root | Where-Object { Test-SCMExeNoise $_.Name }),
        @($rec  | Where-Object { -not (Test-SCMExeNoise $_.Name) }),
        @($rec  | Where-Object { Test-SCMExeNoise $_.Name })
    )

    $seen = @{}
    $ordered = @()
    foreach ($bucket in $buckets) {
        foreach ($e in $bucket) {
            $k = $e.FullName.ToLowerInvariant()
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $ordered += $e }
        }
    }
    return @($ordered)
}

# Carpetas candidatas a 'windows': no detectadas por ScummVM y SIN ID conocido
# (las que tienen ID conocido son ScummVM recuperables via Sync Frontend).
# Cada candidato lleva su .exe localizado (o $null si no se encontro).
function Get-SCMWindowsCandidates {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder
    )
    $status = Get-SCMImportStatus -Games $Games -RomFolder $RomFolder
    $cands = @()
    # TODAS las carpetas sin gestionar (ni detectadas por ScummVM ni con
    # .scummvm). Antes se excluian las que tenian un "ID adivinado", pero un
    # remaster/nativo cuyo NOMBRE se parece a un juego ScummVM (Broken Sword 2
    # remastered, Grim Fandango Remastered...) NO es ese juego y no se le puede
    # crear un .scummvm valido -> debe poder enlazarse a Windows igualmente.
    # El 'Guess' se conserva solo como pista informativa.
    foreach ($f in $status.Missing) {
        $cands += [PSCustomObject]@{
            Folder = $f.Folder
            Path   = $f.Path
            Exe    = (Find-SCMGameExe -FolderPath $f.Path)
            Guess  = $f.KnownGuess
        }
    }
    return @($cands)
}

# Asistente interactivo: muestra el plan, pide confirmacion, crea los .lnk en
# roms\windows y actualiza su gamelist.xml (con backup previo).
function Invoke-SCMWindowsLinker {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder
    )

    $winFolder = Get-SCMWindowsRomFolder
    $cands = @(Get-SCMWindowsCandidates -Games $Games -RomFolder $RomFolder)

    Write-Host ""
    Show-SCMPanel -Title "Windows Linker (juegos no-ScummVM -> roms\windows)" -Lines @(
        ("Carpetas no-ScummVM sin ID : {0}" -f $cands.Count),
        ("Destino (roms\windows)     : {0}" -f $winFolder),
        "",
        "Crea un acceso directo .lnk en la carpeta 'windows' de RetroBat",
        "apuntando al .exe del juego (los datos NO se mueven de su sitio)",
        "y anade su entrada al gamelist.xml de esa carpeta."
    )

    if ($cands.Count -eq 0) {
        Write-Host ""
        Write-Host "  No hay carpetas no-ScummVM que enlazar. Nada que hacer." -ForegroundColor $global:SCMTheme.Ok
        return
    }

    # --- Fase 1: elegir/confirmar el .exe de cada carpeta ---
    Write-Host ""
    Write-Host "  Revisa el .exe de cada juego (Enter acepta el propuesto):" -ForegroundColor $global:SCMTheme.Title
    $plan = @()
    foreach ($c in $cands) {
        $exes = @(Get-SCMFolderExes -FolderPath $c.Path)
        $default = $c.Exe
        if ([string]::IsNullOrWhiteSpace($default) -and $exes.Count -gt 0) {
            $default = $exes[0].FullName
        }

        Write-Host ""
        Write-Host ("  {0}" -f $c.Folder) -ForegroundColor $global:SCMTheme.Menu

        if ($exes.Count -eq 0 -and [string]::IsNullOrWhiteSpace($default)) {
            Write-Host "    No se encontro ningun .exe en la carpeta." -ForegroundColor $global:SCMTheme.Warn
            $m = (Read-Host "    Ruta al .exe (Enter=saltar)").Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            if (-not (Test-Path $m)) { Write-Host "    Ruta no valida, saltado." -ForegroundColor $global:SCMTheme.Dim; continue }
            $plan += [PSCustomObject]@{ Folder = $c.Folder; Exe = $m }
            continue
        }

        # Listar exes numerados, marcando el propuesto.
        for ($i = 0; $i -lt $exes.Count; $i++) {
            $mark = if ($exes[$i].FullName -eq $default) { "*" } else { " " }
            $rel = $exes[$i].FullName.Substring($c.Path.Length).TrimStart('\')
            Write-Host ("    {0} [{1}] {2}" -f $mark, ($i + 1), $rel) -ForegroundColor $global:SCMTheme.Dim
        }
        Write-Host ("    propuesto: {0}" -f (Split-Path $default -Leaf)) -ForegroundColor $global:SCMTheme.Ok
        $ans = (Read-Host "    [Enter]=usar  [1-N]=elegir  [r]=ruta manual  [s]=saltar").Trim()

        $chosen = $default
        if ($ans -eq "s" -or $ans -eq "S") { continue }
        elseif ($ans -eq "r" -or $ans -eq "R") {
            $m = (Read-Host "    Ruta al .exe").Trim().Trim('"')
            if (-not (Test-Path $m)) { Write-Host "    Ruta no valida, saltado." -ForegroundColor $global:SCMTheme.Dim; continue }
            $chosen = $m
        }
        elseif ($ans -match '^\d+$') {
            $idx = [int]$ans - 1
            if ($idx -ge 0 -and $idx -lt $exes.Count) { $chosen = $exes[$idx].FullName }
        }

        if ([string]::IsNullOrWhiteSpace($chosen)) { continue }
        $plan += [PSCustomObject]@{ Folder = $c.Folder; Exe = $chosen }
    }

    if ($plan.Count -eq 0) {
        Write-Host ""
        Write-Host "  Nada seleccionado. Nada que crear." -ForegroundColor $global:SCMTheme.Warn
        return
    }

    Write-Host ""
    Write-Host ("  Se crearan {0} acceso(s) directo(s):" -f $plan.Count) -ForegroundColor $global:SCMTheme.Title
    foreach ($p in $plan) {
        Write-Host ("   {0}.lnk  ->  {1}" -f $p.Folder, (Split-Path $p.Exe -Leaf)) -ForegroundColor $global:SCMTheme.Dim
    }

    if (-not (Test-Path $winFolder)) {
        Write-Host ""
        $mk = Read-Host ("  La carpeta '{0}' no existe. Crearla? (s/N)" -f $winFolder)
        if ($mk -ne "s" -and $mk -ne "S") {
            Write-Host "  Cancelado." -ForegroundColor $global:SCMTheme.Dim
            return
        }
        New-Item -ItemType Directory -Path $winFolder -Force | Out-Null
    }

    Write-Host ""
    $confirm = Read-Host ("  Crear {0} acceso(s) directo(s) .lnk? Type YES" -f $plan.Count)
    if ($confirm -ne "YES") {
        Write-Host "  Cancelado." -ForegroundColor $global:SCMTheme.Dim
        return
    }

    $gamelistPath = Join-Path $winFolder "gamelist.xml"
    if (Test-Path $gamelistPath) { Backup-SCMGamelist -Path $gamelistPath | Out-Null }
    $doc = Get-SCMGamelistDocument -Path $gamelistPath

    $ok = 0; $fail = 0
    foreach ($c in $plan) {
        $lnkPath = Join-Path $winFolder ("{0}.lnk" -f $c.Folder)
        $relPath = "./{0}.lnk" -f $c.Folder
        try {
            New-SCMShortcut -LnkPath $lnkPath -TargetPath $c.Exe

            # Entrada en gamelist (evitando duplicar por <path>).
            $existing = $null
            foreach ($g in $doc.SelectNodes("/gameList/game")) {
                $pn = $g.SelectSingleNode("path")
                if ($null -ne $pn -and (ConvertTo-SCMComparablePath $pn.InnerText) -eq (ConvertTo-SCMComparablePath $relPath)) {
                    $existing = $g; break
                }
            }
            if ($null -eq $existing) {
                New-SCMGamelistEntry -Doc $doc -Fields ([ordered]@{ path = $relPath; name = $c.Folder }) | Out-Null
            }

            Write-Host ("   creado: {0}.lnk  ->  {1}" -f $c.Folder, (Split-Path $c.Exe -Leaf)) -ForegroundColor $global:SCMTheme.Ok
            $ok++
        }
        catch {
            Write-Host ("   ERROR {0}: {1}" -f $c.Folder, $_.Exception.Message) -ForegroundColor $global:SCMTheme.Error
            $fail++
        }
    }

    try { Save-SCMGamelistDocument -Doc $doc -Path $gamelistPath }
    catch { Write-Host ("  ERROR guardando gamelist: {0}" -f $_.Exception.Message) -ForegroundColor $global:SCMTheme.Error }

    Write-Host ""
    Write-Host ("  Hecho: {0} enlace(s) creado(s), {1} fallo(s)." -f $ok, $fail) -ForegroundColor $global:SCMTheme.Ok
    Write-Host ("  gamelist: {0}" -f $gamelistPath) -ForegroundColor $global:SCMTheme.Dim
    Write-Host "  En RetroBat, refresca el sistema 'windows' para verlos." -ForegroundColor $global:SCMTheme.Dim
}

Export-ModuleMember -Function `
    Get-SCMWindowsRomFolder, `
    Find-SCMGameExe, `
    Get-SCMFolderExes, `
    New-SCMShortcut, `
    Get-SCMWindowsCandidates, `
    Invoke-SCMWindowsLinker

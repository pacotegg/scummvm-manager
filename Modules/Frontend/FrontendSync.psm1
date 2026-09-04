Set-StrictMode -Version Latest

# =====================================================================
#  FrontendSync.psm1 - orquestador. Mantiene "viva" la carpeta del
#  frontend (roms\scummvm): alta de juegos nuevos y correccion de la
#  convencion de nombres, sincronizando carpeta + .scummvm + media +
#  gamelist.xml, de forma segura (dry-run, backup, log).
# =====================================================================

# Carpetas de media a excluir/procesar. Si MediaStatus esta cargado se usan
# TODOS sus alias (video/wheel/screenshots...); si no, las 5 canonicas.
function Get-SCMSyncMediaFolders {
    try {
        if (Get-Command Get-SCMMediaFolderNames -ErrorAction SilentlyContinue) { return @(Get-SCMMediaFolderNames) }
    } catch { }
    return @("images", "videos", "manuals", "marquees", "snaps")
}
$script:MediaFolders = Get-SCMSyncMediaFolders

# --- helpers privados -------------------------------------------------

# Carpeta de juego de primer nivel bajo RomFolder que contiene al juego
# detectado (FullPath puede apuntar a una subcarpeta mas profunda).
function Get-SCMTopLevelFolder {
    param([string]$RomFolder, [string]$FullPath)

    $root = (Resolve-Path $RomFolder).Path.TrimEnd('\')
    $full = $FullPath.TrimEnd('\')

    # Exigir separador tras la raiz: "D:\roms\scummvm2\x" NO esta dentro de
    # "D:\roms\scummvm" aunque el prefijo de texto coincida.
    $rootL = $root.ToLowerInvariant(); $fullL = $full.ToLowerInvariant()
    if (-not ($fullL -eq $rootL -or $fullL.StartsWith($rootL + '\'))) {
        return $null
    }

    $rel = $full.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($rel)) {
        return $null   # el juego esta en la raiz misma: ambiguo
    }

    $topSegment = $rel.Split('\')[0]
    return [PSCustomObject]@{
        Name = $topSegment
        Path = Join-Path $root $topSegment
    }
}

# Ficheros de media (en las carpetas hermanas de la raiz) cuyo nombre
# empieza por "<FolderName>-". Devuelve @{ OldPath; NewPath; MediaFolder }.
function Get-SCMMediaFiles {
    param([string]$RomFolder, [string]$OldName, [string]$NewName)

    $result = @()
    $prefix = "$OldName-"

    foreach ($mf in $script:MediaFolders) {
        $dir = Join-Path $RomFolder $mf
        if (-not (Test-Path $dir)) { continue }

        Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $suffix = $_.Name.Substring($OldName.Length)   # incluye "-image.png"
                $result += [PSCustomObject]@{
                    MediaFolder = $mf
                    OldPath     = $_.FullName
                    NewPath     = Join-Path $dir ($NewName + $suffix)
                }
            }
        }
    }
    return $result
}

# --- calculo del plan (dry-run puro, sin escribir nada) ---------------

function Get-SCMFrontendPlan {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder,
        [ValidateSet("New", "Existing", "All")]
        [string]$Mode = "All"
    )

    $config = Get-SCMConfig
    $maxLen = 100
    if ($config.Preferences.PSObject.Properties.Name -contains "MaxFolderNameLength") {
        $maxLen = [int]$config.Preferences.MaxFolderNameLength
    }

    $gamelistPath = Join-Path $RomFolder "gamelist.xml"
    $doc = Get-SCMGamelistDocument -Path $gamelistPath

    # Nombres de carpeta ya existentes (excluyendo las carpetas de media),
    # para resolver colisiones de nombres nuevos.
    $existingFolders = @()
    if (Test-Path $RomFolder) {
        $existingFolders = @(
            Get-ChildItem -Path $RomFolder -Directory |
            Where-Object { $script:MediaFolders -notcontains $_.Name } |
            ForEach-Object { $_.Name }
        )
    }

    $usedNames = @()   # nombres nuevos ya asignados en esta pasada
    $plan = @()

    # Cuantos juegos apuntan a cada carpeta de primer nivel. Si una carpeta
    # tiene mas de un juego (un "bundle"), no se puede separar renombrando:
    # esos items se marcaran como Skip.
    $folderCounts = @{}
    foreach ($g in $Games) {
        $t = Get-SCMTopLevelFolder -RomFolder $RomFolder -FullPath $g.FullPath
        if ($null -ne $t) {
            $key = $t.Path.ToLowerInvariant()
            if ($folderCounts.ContainsKey($key)) { $folderCounts[$key]++ } else { $folderCounts[$key] = 1 }
        }
    }

    foreach ($game in $Games) {

        $top = Get-SCMTopLevelFolder -RomFolder $RomFolder -FullPath $game.FullPath
        if ($null -eq $top) {
            $plan += [PSCustomObject]@{
                Game = $game; OldFolderName = "(root)"; NewFolderName = $null
                OldFolderPath = $game.FullPath; NewFolderPath = $null
                Action = "Skip"; ScummVMFileContent = $game.GameID
                MediaFiles = @(); GamelistAction = "None"
                Warnings = @("Juego en la raiz o fuera de RomFolder; no se puede mapear a carpeta.")
            }
            continue
        }

        # Carpeta compartida por varios juegos (bundle): no se puede auto-separar.
        if ($folderCounts[$top.Path.ToLowerInvariant()] -gt 1) {
            $plan += [PSCustomObject]@{
                Game = $game; OldFolderName = $top.Name; NewFolderName = $top.Name
                OldFolderPath = $top.Path; NewFolderPath = $top.Path
                Action = "Skip"; ScummVMFileContent = $game.GameID
                MediaFiles = @(); GamelistAction = "None"
                Warnings = @("Varios juegos comparten la carpeta '$($top.Name)' (bundle); separalos a mano en carpetas propias.")
            }
            continue
        }

        # Carpeta inexistente (games.json desactualizado tras renombrar): saltar.
        if (-not (Test-Path $top.Path)) {
            $plan += [PSCustomObject]@{
                Game = $game; OldFolderName = $top.Name; NewFolderName = $top.Name
                OldFolderPath = $top.Path; NewFolderPath = $top.Path
                Action = "Skip"; ScummVMFileContent = $game.GameID
                MediaFiles = @(); GamelistAction = "None"
                Warnings = @("Carpeta no encontrada; el catalogo esta desactualizado. Vuelve a hacer Scan.")
            }
            continue
        }

        $oldName    = $top.Name
        $oldPath    = $top.Path
        $folderBroken = Test-SCMFolderNameIsBroken -Name $oldName

        # Acepta CUALQUIER *.scummvm de la carpeta (una carpeta renombrada a
        # mano conserva el .scummvm con el nombre viejo): asi no se clasifica
        # como Create ni se acaba escribiendo un SEGUNDO .scummvm duplicado.
        $svmFiles   = @(Get-ChildItem -Path $oldPath -Filter '*.scummvm' -File -ErrorAction SilentlyContinue)
        $hasScummvm = ($svmFiles.Count -gt 0)
        $entry      = Find-SCMGamelistEntryByFolder -Doc $doc -FolderName $oldName -Loose
        $hasEntry   = ($null -ne $entry)

        $isNew = (-not $hasScummvm) -or (-not $hasEntry)

        # Nombre propuesto (para rename o alta). Cascada de respaldo si el Title
        # viene vacio (algunos juegos AGS se detectan sin descripcion parseable):
        # Title -> nombre de carpeta actual -> ShortID -> "scummvm_game".
        $proposed = ConvertTo-SCMSafeFileName -Title $game.Title -MaxLength $maxLen
        if ([string]::IsNullOrWhiteSpace($proposed)) {
            $proposed = ConvertTo-SCMSafeFileName -Title $oldName -MaxLength $maxLen
        }
        if ([string]::IsNullOrWhiteSpace($proposed)) {
            $proposed = ConvertTo-SCMSafeFileName -Title ([string]$game.ShortID) -MaxLength $maxLen
        }
        if ([string]::IsNullOrWhiteSpace($proposed)) {
            $proposed = "scummvm_game"
        }

        # Determinar accion.
        $warnings = @()
        if ($folderBroken) {
            # Necesita renombrar: resolver nombre unico contra hermanos + ya usados.
            $blockList = @($existingFolders + $usedNames | Where-Object { $_ -ne $oldName })
            $newName = Resolve-SCMUniqueName -BaseName $proposed -ExistingNames $blockList
        }
        else {
            $newName = $oldName   # nombre ya valido: se conserva tal cual
        }

        if ($isNew) {
            $action = "Create"
        }
        elseif ($folderBroken) {
            $action = "Rename"
        }
        else {
            $action = "NoChange"
        }

        # Filtrar por modo.
        $include = switch ($Mode) {
            "New"      { $action -eq "Create" }
            "Existing" { $action -eq "Rename" }
            default    { $true }
        }
        if (-not $include) { continue }
        if ($action -eq "NoChange" -and $Mode -ne "All") { continue }

        $newPath = Join-Path $RomFolder $newName
        if ($newName -ne $oldName) { $usedNames += $newName }

        $media = @()
        if ($action -eq "Rename" -and $newName -ne $oldName) {
            $media = @(Get-SCMMediaFiles -RomFolder $RomFolder -OldName $oldName -NewName $newName)
        }

        $gamelistAction =
            if ($action -eq "Create") { if ($hasEntry) { "UpdatePaths" } else { "Insert" } }
            elseif ($action -eq "Rename") { if ($hasEntry) { "UpdatePaths" } else { "None" } }
            else { "None" }

        if ($action -eq "Rename" -and -not $hasEntry) {
            $warnings += "Sin entrada en gamelist.xml para '$oldName' (solo se renombra en disco)."
        }

        $plan += [PSCustomObject]@{
            Game               = $game
            OldFolderName      = $oldName
            NewFolderName      = $newName
            OldFolderPath      = $oldPath
            NewFolderPath      = $newPath
            Action             = $action
            ScummVMFileNeeded  = (-not $hasScummvm)
            ScummVMFileContent = $game.GameID
            MediaFiles         = $media
            GamelistAction     = $gamelistAction
            HasGamelistEntry   = $hasEntry
            Warnings           = $warnings
        }
    }

    return $plan
}

# --- informe dry-run --------------------------------------------------

function Show-SCMFrontendPlanReport {
    param([array]$Plan)

    Write-Host ""
    Write-Host "  Frontend Sync - Plan" -ForegroundColor $global:SCMTheme.Title
    Write-Host ""

    if ($null -eq $Plan -or @($Plan).Count -eq 0) {
        Write-Host "  Nothing to do." -ForegroundColor $global:SCMTheme.Ok
        Write-Host ""
        return
    }

    foreach ($item in $Plan) {
        switch ($item.Action) {
            "Create" {
                $line = "  [CREATE ] {0}  (target: {1}, gamelist: {2})" -f `
                    $item.NewFolderName, $item.ScummVMFileContent, $item.GamelistAction
                Write-Host $line -ForegroundColor $global:SCMTheme.Ok
            }
            "Rename" {
                $line = "  [RENAME ] {0}  ->  {1}  ({2} media, gamelist: {3})" -f `
                    $item.OldFolderName, $item.NewFolderName, @($item.MediaFiles).Count, $item.GamelistAction
                Write-Host $line -ForegroundColor $global:SCMTheme.Selected
            }
            "Skip" {
                Write-Host ("  [SKIP   ] {0}" -f $item.OldFolderName) -ForegroundColor $global:SCMTheme.Dim
            }
            default {
                Write-Host ("  [NOCHG  ] {0}" -f $item.OldFolderName) -ForegroundColor $global:SCMTheme.Dim
            }
        }
        foreach ($w in $item.Warnings) {
            Write-Host ("            ! {0}" -f $w) -ForegroundColor $global:SCMTheme.Warn
        }
    }
    Write-Host ""
}

# --- backup y log -----------------------------------------------------

function Backup-SCMGamelist {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    $stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $backup = "$Path.bak_$stamp"
    Copy-Item -Path $Path -Destination $backup -Force
    return $backup
}

function Write-SCMFrontendOperationLog {
    param(
        [Parameter(Mandatory)][array]$Ops,
        [Parameter(Mandatory)][string]$LogPath
    )

    $dir = Split-Path $LogPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    foreach ($op in $Ops) {
        ($op | ConvertTo-Json -Compress) | Add-Content -Path $LogPath -Encoding UTF8
    }
}

# --- ejecucion --------------------------------------------------------

function Invoke-SCMFrontendSync {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
    param(
        [Parameter(Mandatory)][array]$Plan,
        [Parameter(Mandatory)][string]$RomFolder,
        [Parameter(Mandatory)][string]$GamelistPath
    )

    $config  = Get-SCMConfig
    $stamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logPath = Join-Path $config.Paths.Logs ("FrontendSync_{0}.jsonl" -f $stamp)

    # -WhatIf: NO tocar nada. Sin esta guarda, los Rename/Copy heredaban WhatIf
    # (no se ejecutaban) pero el DOM en memoria SI se modificaba y el Save final
    # (XmlWriter puro, ajeno a WhatIf) reescribia el gamelist real sin backup.
    if ($WhatIfPreference) {
        Write-Host "  (WhatIf) Dry-run: no se aplica nada. Usa Show-SCMFrontendPlanReport para ver el plan." -ForegroundColor $global:SCMTheme.Dim
        return
    }

    $actionable = @($Plan | Where-Object { $_.Action -in @("Create", "Rename") })
    if ($actionable.Count -eq 0) {
        Write-Host "  Nothing to apply." -ForegroundColor $global:SCMTheme.Ok
        return
    }

    # Backup del gamelist una sola vez.
    $backup = Backup-SCMGamelist -Path $GamelistPath
    if ($backup) {
        Write-Host ("  Backup: {0}" -f $backup) -ForegroundColor $global:SCMTheme.Dim
    }

    $doc = Get-SCMGamelistDocument -Path $GamelistPath

    $ops     = @()
    $okCount = 0
    $failed  = @()

    foreach ($item in $actionable) {
        try {
            $oldName = $item.OldFolderName
            $newName = $item.NewFolderName
            $newPath = $item.NewFolderPath
            $renaming = ($newName -ne $oldName)

            # 1. Renombrar la carpeta (ancla).
            if ($renaming) {
                if ($PSCmdlet.ShouldProcess($item.OldFolderPath, "Rename folder to $newName")) {
                    Rename-Item -Path $item.OldFolderPath -NewName $newName -ErrorAction Stop
                    $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "RenameFolder"; old = $item.OldFolderPath; new = $newPath; shortId = $item.Game.GameID }
                }
            }

            # 2. Fichero .scummvm dentro de la carpeta (ya en su ruta nueva).
            #    Acepta CUALQUIER *.scummvm existente: si hay uno con otro
            #    nombre (carpeta renombrada a mano) se RENOMBRA en vez de
            #    crear un segundo fichero (que duplicaria el juego en ES).
            $scummvmNew = Join-Path $newPath ("$newName.scummvm")
            if (-not (Test-Path $scummvmNew)) {
                $svmExisting = @(Get-ChildItem -Path $newPath -Filter '*.scummvm' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($svmExisting.Count -gt 0) {
                    Rename-Item -Path $svmExisting[0].FullName -NewName ("$newName.scummvm") -ErrorAction Stop
                    $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "RenameScummvm"; old = $svmExisting[0].FullName; new = $scummvmNew; shortId = $item.Game.GameID }
                }
                else {
                    Set-Content -Path $scummvmNew -Value $item.ScummVMFileContent -Encoding ASCII -NoNewline -ErrorAction Stop
                    $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "CreateScummvm"; old = $null; new = $scummvmNew; shortId = $item.Game.GameID }
                }
            }

            # 3. Media (carpetas hermanas de la raiz). Una colision individual
            #    (el destino ya existe por restos de otra pasada) NO aborta el
            #    item: se salta ese fichero y se deja constancia en el log.
            foreach ($m in $item.MediaFiles) {
                if (Test-Path $m.OldPath) {
                    if (Test-Path $m.NewPath) {
                        $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "SkipMedia"; old = $m.OldPath; new = $m.NewPath; shortId = $item.Game.GameID; error = "destino ya existe" }
                        continue
                    }
                    Rename-Item -Path $m.OldPath -NewName (Split-Path $m.NewPath -Leaf) -ErrorAction Stop
                    $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "RenameMedia"; old = $m.OldPath; new = $m.NewPath; shortId = $item.Game.GameID }
                }
            }

            # 4. gamelist.xml (en memoria).
            if ($item.GamelistAction -eq "Insert") {
                New-SCMGamelistEntry -Doc $doc -Fields ([ordered]@{
                    path = "./$newName/$newName.scummvm"
                    name = $item.Game.DisplayTitle
                }) | Out-Null
                $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "InsertGamelistEntry"; old = $null; new = "./$newName/$newName.scummvm"; shortId = $item.Game.GameID }
            }
            elseif ($item.GamelistAction -eq "UpdatePaths") {
                $entry = Find-SCMGamelistEntryByFolder -Doc $doc -FolderName $oldName -Loose
                if ($null -ne $entry) {
                    Set-SCMGamelistEntryField -GameNode $entry -Field "path" -Value "./$newName/$newName.scummvm"
                    foreach ($mediaField in @("image", "video", "thumbnail", "fanart", "manual", "marquee")) {
                        $node = $entry.SelectSingleNode($mediaField)
                        if ($null -ne $node -and -not [string]::IsNullOrEmpty($node.InnerText)) {
                            # Case-INSENSITIVE: los ficheros se renombraron con
                            # OrdinalIgnoreCase; el tag debe seguirles aunque la
                            # capitalizacion difiera ("Monkey Island-" vs "monkey island").
                            $node.InnerText = [regex]::Replace($node.InnerText, [regex]::Escape("/$oldName-"), ("/$newName-".Replace('$', '$$')), 'IgnoreCase')
                        }
                    }
                    $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "UpdateGamelistEntry"; old = $oldName; new = $newName; shortId = $item.Game.GameID }
                }
            }

            $okCount++
        }
        catch {
            $failed += [PSCustomObject]@{ Item = $item.OldFolderName; Error = $_.Exception.Message }
            $ops += [PSCustomObject]@{ ts = (Get-Date -Format "o"); op = "ERROR"; old = $item.OldFolderName; new = $item.NewFolderName; shortId = $item.Game.GameID; error = $_.Exception.Message }
        }
    }

    # 5. Guardar el gamelist una sola vez al final.
    try {
        Save-SCMGamelistDocument -Doc $doc -Path $GamelistPath
    }
    catch {
        Write-Host ("  ERROR guardando gamelist.xml: {0}" -f $_.Exception.Message) -ForegroundColor $global:SCMTheme.Error
        Write-Host ("  El backup sigue disponible en: {0}" -f $backup) -ForegroundColor $global:SCMTheme.Warn
    }

    if ($ops.Count -gt 0) {
        Write-SCMFrontendOperationLog -Ops $ops -LogPath $logPath
    }

    Write-Host ""
    Write-Host ("  Done: {0} ok, {1} failed." -f $okCount, $failed.Count) -ForegroundColor $global:SCMTheme.Ok
    foreach ($f in $failed) {
        Write-Host ("  ! {0}: {1}" -f $f.Item, $f.Error) -ForegroundColor $global:SCMTheme.Error
    }
    Write-Host ("  Log: {0}" -f $logPath) -ForegroundColor $global:SCMTheme.Dim
}

# --- Undo del ultimo Sync ---------------------------------------------

# Devuelve la ruta del log FrontendSync_*.jsonl mas reciente, o $null.
function Get-SCMLastSyncLog {
    $config = Get-SCMConfig
    if (-not (Test-Path $config.Paths.Logs)) { return $null }
    $log = Get-ChildItem -Path $config.Paths.Logs -Filter "FrontendSync_*.jsonl" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $log) { return $null }
    return $log.FullName
}

# Revierte el ultimo Sync usando su log de operaciones.
function Invoke-SCMUndoLastSync {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
    param(
        [Parameter(Mandatory)][string]$RomFolder,
        [Parameter(Mandatory)][string]$GamelistPath,
        [string]$LogPath = $null
    )

    if ([string]::IsNullOrEmpty($LogPath)) { $LogPath = Get-SCMLastSyncLog }
    if ([string]::IsNullOrEmpty($LogPath) -or -not (Test-Path $LogPath)) {
        Write-Host "  No hay ningun log de Sync que deshacer." -ForegroundColor $global:SCMTheme.Warn
        return
    }

    $ops = @()
    foreach ($line in (Get-Content $LogPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $ops += ($line | ConvertFrom-Json) } catch { }
    }
    if ($ops.Count -eq 0) {
        Write-Host "  El log esta vacio o corrupto." -ForegroundColor $global:SCMTheme.Warn
        return
    }

    Write-Host ("  Deshaciendo {0} operacion(es) de:" -f $ops.Count) -ForegroundColor $global:SCMTheme.Title
    Write-Host ("  {0}" -f $LogPath) -ForegroundColor $global:SCMTheme.Dim

    Backup-SCMGamelist -Path $GamelistPath | Out-Null
    $doc = Get-SCMGamelistDocument -Path $GamelistPath

    $ok = 0; $fail = 0

    # Recorrer en orden INVERSO al de aplicacion.
    for ($i = $ops.Count - 1; $i -ge 0; $i--) {
        $op = $ops[$i]
        try {
            switch ($op.op) {
                "RenameFolder"   { if (Test-Path $op.new) { Rename-Item -Path $op.new -NewName (Split-Path $op.old -Leaf) -ErrorAction Stop; $ok++ } }
                "RenameScummvm"  { if (Test-Path $op.new) { Rename-Item -Path $op.new -NewName (Split-Path $op.old -Leaf) -ErrorAction Stop; $ok++ } }
                "RenameMedia"    { if (Test-Path $op.new) { Rename-Item -Path $op.new -NewName (Split-Path $op.old -Leaf) -ErrorAction Stop; $ok++ } }
                "CreateScummvm"  { if (Test-Path $op.new) { Remove-Item -Path $op.new -Force -ErrorAction Stop; $ok++ } }
                "InsertGamelistEntry" {
                    # op.new = "./folder/folder.scummvm" -> folder
                    $seg = ((ConvertTo-SCMComparablePath $op.new) -split "/")[0]
                    $entry = Find-SCMGamelistEntryByFolder -Doc $doc -FolderName $seg
                    if ($null -ne $entry) { [void]$entry.ParentNode.RemoveChild($entry); $ok++ }
                }
                "UpdateGamelistEntry" {
                    # op.old = nombre viejo, op.new = nombre nuevo (actual en disco/gamelist)
                    $entry = Find-SCMGamelistEntryByFolder -Doc $doc -FolderName $op.new -Loose
                    if ($null -ne $entry) {
                        Set-SCMGamelistEntryField -GameNode $entry -Field "path" -Value ("./{0}/{0}.scummvm" -f $op.old)
                        foreach ($mf in @("image", "video", "thumbnail", "fanart", "manual", "marquee")) {
                            $node = $entry.SelectSingleNode($mf)
                            if ($null -ne $node -and -not [string]::IsNullOrEmpty($node.InnerText)) {
                                $node.InnerText = [regex]::Replace($node.InnerText, [regex]::Escape("/$($op.new)-"), ("/$($op.old)-".Replace('$', '$$')), 'IgnoreCase')
                            }
                        }
                        $ok++
                    }
                }
                "ERROR" { }
            }
        }
        catch { $fail++ }
    }

    try { Save-SCMGamelistDocument -Doc $doc -Path $GamelistPath } catch { }

    # Renombrar el log para que no se deshaga dos veces.
    try { Rename-Item -Path $LogPath -NewName ((Split-Path $LogPath -Leaf) + ".undone") -ErrorAction SilentlyContinue } catch { }

    Write-Host ""
    Write-Host ("  Undo: {0} revertida(s), {1} fallo(s)." -f $ok, $fail) -ForegroundColor $global:SCMTheme.Ok
}

# Lista los backups de gamelist (gamelist.xml.bak_*) mas recientes primero.
function Get-SCMGamelistBackups {
    param([Parameter(Mandatory)][string]$RomFolder)
    $glDir = $RomFolder
    if (-not (Test-Path $glDir)) { return @() }
    return @(Get-ChildItem -Path $glDir -Filter "gamelist.xml.bak_*" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
}

# Restaura un backup sobre gamelist.xml (guardando antes una copia del actual).
function Restore-SCMGamelistBackup {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$GamelistPath
    )
    if (-not (Test-Path $BackupPath)) {
        Write-Host "  Backup no encontrado." -ForegroundColor $global:SCMTheme.Error
        return
    }
    # Salvar el actual antes de sobreescribir.
    if (Test-Path $GamelistPath) { Backup-SCMGamelist -Path $GamelistPath | Out-Null }
    Copy-Item -Path $BackupPath -Destination $GamelistPath -Force
    Write-Host ("  Restaurado: {0} -> gamelist.xml" -f (Split-Path $BackupPath -Leaf)) -ForegroundColor $global:SCMTheme.Ok
}

Export-ModuleMember -Function `
    Get-SCMFrontendPlan, `
    Show-SCMFrontendPlanReport, `
    Backup-SCMGamelist, `
    Write-SCMFrontendOperationLog, `
    Invoke-SCMFrontendSync, `
    Get-SCMLastSyncLog, `
    Invoke-SCMUndoLastSync, `
    Get-SCMGamelistBackups, `
    Restore-SCMGamelistBackup

Set-StrictMode -Version Latest

# =====================================================================
#  MediaStatus.psm1 - averigua que media tiene cada juego combinando DOS
#  fuentes:
#    1) el filesystem: carpetas hermanas de la raiz de ROMs. Los nombres se
#       descubren de forma FLEXIBLE (singular/plural/mayusculas): "video" y
#       "videos", "marquee" y "marquees", etc. cuentan igual.
#    2) el gamelist.xml central: para cada <game> se leen las rutas
#       <image>/<thumbnail>/<marquee>/<video>/<manual>/<fanart> y se comprueba
#       que el fichero apuntado EXISTE en disco. Esto detecta media aunque el
#       nombre del fichero no siga la convencion "<Carpeta>-<tipo>.<ext>".
#
#  Se construye un indice UNA vez (Get-SCMMediaIndex) y se consulta por juego
#  (Get-SCMMediaStatus). Base para Doctor, informe de media faltante, coloreado
#  del Browse, la galeria del GUI y estadisticas de cobertura.
# =====================================================================

# Categoria canonica -> alias de nombre de carpeta aceptados (case-insensitive).
$script:SCMMediaAliases = [ordered]@{
    images   = @('images', 'image')
    videos   = @('videos', 'video')
    manuals  = @('manuals', 'manual')
    marquees = @('marquees', 'marquee', 'wheel', 'wheels')
    snaps    = @('snaps', 'snap', 'screenshots', 'screenshot')
}

# Nombres canonicos (para quien los necesite: Doctor, etc.).
$script:SCMMediaRoots = @($script:SCMMediaAliases.Keys)

# TODOS los nombres de carpeta que cuentan como media (canonicos + alias).
# La consumen FrontendSync/Doctor/ImportStatus/Fallback para NO tratar una
# carpeta "video" o "screenshots" como si fuera un juego.
function Get-SCMMediaFolderNames {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($canon in $script:SCMMediaAliases.Keys) {
        foreach ($alias in $script:SCMMediaAliases[$canon]) { if (-not $names.Contains($alias)) { $names.Add($alias) } }
    }
    return @($names)
}

# Resuelve, dentro de $RomFolder, la carpeta real que corresponde a una
# categoria canonica probando sus alias. Devuelve la ruta o $null.
function Resolve-SCMMediaFolder {
    param([string]$RomFolder, [string]$Canonical)
    if (-not $script:SCMMediaAliases.Contains($Canonical)) { return $null }
    foreach ($alias in $script:SCMMediaAliases[$Canonical]) {
        $dir = Join-Path $RomFolder $alias
        if (Test-Path $dir) { return $dir }
    }
    return $null
}

# Deriva el nombre de carpeta del juego a partir del <path> del gamelist.
# "./Beneath_Steel_Sky/Beneath_Steel_Sky.scummvm" -> "Beneath_Steel_Sky"
# "./Beneath_Steel_Sky.scummvm"                    -> "Beneath_Steel_Sky"
function Get-SCMFolderFromGamelistPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim() -replace '^\.[\\/]', '' -replace '\\', '/'
    $segs = @($p -split '/' | Where-Object { $_ -ne '' })
    if ($segs.Count -ge 2) { return $segs[0] }
    if ($segs.Count -eq 1) { return [System.IO.Path]::GetFileNameWithoutExtension($segs[0]) }
    return ''
}

# Log de diagnostico del modulo (Logs\media_detect.log). Silencioso si falla.
function Write-SCMMediaDbg {
    param([string]$Msg)
    try {
        $cfg = Get-SCMConfig
        $logDir = $cfg.Paths.Logs
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg) | Out-File -FilePath (Join-Path $logDir 'media_detect.log') -Append -Encoding UTF8
    } catch { }
}

# Extrae de un bloque <game>...</game> (texto) el <path> y los tags de media.
# Robusto ante XML mal formado (un '&' sin escapar en otro juego no lo rompe).
function Get-SCMGameBlockMedia {
    param([string]$Block)
    $out = @{ path = ''; media = @{} }
    $mp = [regex]::Match($Block, '<path>(?<v>.*?)</path>', 'Singleline')
    if ($mp.Success) { $out.path = $mp.Groups['v'].Value.Trim() }
    $tagMap = @{ image = 'image'; thumbnail = 'thumb'; marquee = 'marquee'; video = 'video'; manual = 'manual'; fanart = 'fanart' }
    foreach ($tag in $tagMap.Keys) {
        $m = [regex]::Match($Block, "<$tag>(?<v>.*?)</$tag>", 'Singleline')
        if ($m.Success) {
            $v = $m.Groups['v'].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($v)) { $out.media[$tagMap[$tag]] = $v }
        }
    }
    return $out
}

# Lee el gamelist.xml (si existe) y devuelve un mapa:
#   folderName(lower) -> @{ image=$true; video=$true; ... }  (solo tipos cuyo
#   fichero apuntado EXISTE en disco). Parser TOLERANTE: intenta [xml] y, si
#   falla (p. ej. un '&' sin escapar en "Sam & Max"), cae a extraccion por regex
#   bloque a bloque para no perder TODO el gamelist por un solo juego malo.
function Get-SCMGamelistMediaMap {
    param([string]$RomFolder)
    $map = @{}
    $glPath = Join-Path $RomFolder 'gamelist.xml'
    if (-not (Test-Path $glPath)) { Write-SCMMediaDbg "gamelist.xml NO encontrado en $RomFolder"; return $map }

    $raw = $null
    try { $raw = Get-Content -LiteralPath $glPath -Raw -Encoding UTF8 } catch { Write-SCMMediaDbg "no se pudo leer gamelist.xml: $($_.Exception.Message)"; return $map }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $map }

    # Lista de (path, mediaHash) sea por [xml] o por regex.
    $entries = @()
    $parsedBy = 'xml'
    try {
        [xml]$doc = $raw
        $tagMap = @{ image = 'image'; thumbnail = 'thumb'; marquee = 'marquee'; video = 'video'; manual = 'manual'; fanart = 'fanart' }
        $games = $doc.SelectNodes('/gameList/game')
        foreach ($g in $games) {
            $pathNode = $g.SelectSingleNode('path'); if ($null -eq $pathNode) { continue }
            $mh = @{}
            foreach ($tag in $tagMap.Keys) {
                $node = $g.SelectSingleNode($tag)
                if ($null -ne $node -and -not [string]::IsNullOrWhiteSpace($node.InnerText)) { $mh[$tagMap[$tag]] = $node.InnerText.Trim() }
            }
            $entries += @{ path = $pathNode.InnerText; media = $mh }
        }
    }
    catch {
        $parsedBy = 'regex(fallback)'
        Write-SCMMediaDbg "xml fallo ($($_.Exception.Message)); uso regex tolerante"
        foreach ($bm in [regex]::Matches($raw, '<game\b[^>]*>(?<b>.*?)</game>', 'Singleline')) {
            $blk = Get-SCMGameBlockMedia $bm.Groups['b'].Value
            if ($blk.path) { $entries += @{ path = $blk.path; media = $blk.media } }
        }
    }

    $withMedia = 0
    foreach ($e in $entries) {
        $folder = Get-SCMFolderFromGamelistPath $e.path
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        $key = $folder.ToLowerInvariant()
        if (-not $map.ContainsKey($key)) { $map[$key] = @{} }
        foreach ($type in $e.media.Keys) {
            $rel = $e.media[$type]
            $abs = $rel.Trim() -replace '^\.[\\/]', '' -replace '/', '\'
            $full = if ([System.IO.Path]::IsPathRooted($abs)) { $abs } else { Join-Path $RomFolder $abs }
            if (Test-Path -LiteralPath $full) { $map[$key][$type] = $true; $withMedia++ }
        }
    }
    Write-SCMMediaDbg ("gamelist parseado por {0}: {1} juegos, {2} referencias de media existentes" -f $parsedBy, $entries.Count, $withMedia)
    return $map
}

# Indexa nombres de fichero de cada carpeta de media + el mapa del gamelist.
function Get-SCMMediaIndex {
    param([Parameter(Mandatory)][string]$RomFolder)

    $index = @{}
    foreach ($canon in $script:SCMMediaAliases.Keys) {
        $names = New-Object System.Collections.Generic.List[string]
        # Fusiona ficheros de TODAS las carpetas alias existentes (p. ej. si el
        # sistema tiene a la vez 'video' y 'videos', se leen ambas).
        foreach ($alias in $script:SCMMediaAliases[$canon]) {
            $dir = Join-Path $RomFolder $alias
            if (Test-Path $dir) {
                foreach ($n in @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })) { $names.Add($n) }
            }
        }
        $index[$canon] = @($names)
    }
    # claves especiales (los consumidores solo acceden por categoria canonica)
    $index['__root__'] = $RomFolder
    $index['__gl__'] = Get-SCMGamelistMediaMap -RomFolder $RomFolder
    Write-SCMMediaDbg ("indice: images={0} videos={1} manuals={2} marquees={3} snaps={4} | gamelist entries={5}" -f `
        @($index['images']).Count, @($index['videos']).Count, @($index['manuals']).Count, @($index['marquees']).Count, @($index['snaps']).Count, @($index['__gl__'].Keys).Count)
    return $index
}

# True si en $MediaFolder existe un fichero para "<FolderName>":
#   - con $Suffix: "<FolderName><Suffix>.<ext>"  (ej. "-image")
#   - sin $Suffix: empieza por "<FolderName>-"  o  "<FolderName>."  (fichero suelto)
function Test-SCMMediaFile {
    param(
        [hashtable]$Index,
        [string]$MediaFolder,
        [string]$FolderName,
        [string]$Suffix
    )
    if (-not $Index.ContainsKey($MediaFolder)) { return $false }
    foreach ($n in $Index[$MediaFolder]) {
        if ([string]::IsNullOrEmpty($Suffix)) {
            if ($n.StartsWith("$FolderName-", [System.StringComparison]::OrdinalIgnoreCase) -or
                $n.StartsWith("$FolderName.", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        else {
            if ($n.StartsWith("$FolderName$Suffix.", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

# Estado de media de un juego: filesystem OR gamelist. Prueba varios nombres
# candidatos (el de carpeta y, opcionalmente, el titulo saneado) por si la BD y
# el disco difieren.
function Get-SCMMediaStatus {
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][string]$FolderName,
        [string[]]$AltFolderNames = @()
    )

    # candidatos unicos (carpeta + alternativos), sin vacios
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($c in (@($FolderName) + @($AltFolderNames))) { if (-not [string]::IsNullOrWhiteSpace($c) -and -not $cands.Contains($c)) { $cands.Add($c) } }

    # tipos presentes segun gamelist para cualquiera de los candidatos
    $gl = @{}
    if ($Index.ContainsKey('__gl__')) {
        $glMap = $Index['__gl__']
        if ($glMap -is [hashtable]) {
            foreach ($c in $cands) {
                $k = $c.ToLowerInvariant()
                if ($glMap.ContainsKey($k)) { foreach ($t in $glMap[$k].Keys) { if ($glMap[$k][$t]) { $gl[$t] = $true } } }
            }
        }
    }
    $glHas = { param($t) return ($gl.ContainsKey($t) -and $gl[$t]) }
    # helper: ¿algún candidato tiene fichero en $folder con $suffix?
    $fs = { param($folder, $suffix) foreach ($c in $cands) { if (Test-SCMMediaFile -Index $Index -MediaFolder $folder -FolderName $c -Suffix $suffix) { return $true } } return $false }

    $image   = (& $fs "images"   "-image")  -or (& $glHas 'image')
    $thumb   = (& $fs "images"   "-thumb")  -or (& $glHas 'thumb')
    $fanart  = (& $fs "images"   "-fanart") -or (& $glHas 'fanart')
    $video   = (& $fs "videos"   "-video")  -or (& $fs "videos" "") -or (& $glHas 'video')
    $manual  = (& $fs "manuals"  "-manual") -or (& $fs "manuals" "") -or (& $glHas 'manual')
    $marquee = (& $fs "marquees" "")        -or (& $glHas 'marquee')
    $snap    = (& $fs "snaps"    "")

    # Falta lo "esencial" si no hay ni imagen ni video.
    $hasCore = $image -and $video
    $any = $image -or $thumb -or $fanart -or $video -or $manual -or $marquee -or $snap

    # Lista de tipos ausentes de los principales (para el informe).
    $missing = @()
    if (-not $image)  { $missing += "image" }
    if (-not $video)  { $missing += "video" }
    if (-not $manual) { $missing += "manual" }

    return [PSCustomObject]@{
        Image    = $image
        Thumb    = $thumb
        Fanart   = $fanart
        Video    = $video
        Manual   = $manual
        Marquee  = $marquee
        Snap     = $snap
        HasCore  = $hasCore
        AnyMedia = $any
        Missing  = $missing
    }
}

Export-ModuleMember -Function Get-SCMMediaIndex, Test-SCMMediaFile, Get-SCMMediaStatus, Resolve-SCMMediaFolder, Get-SCMGamelistMediaMap, Get-SCMFolderFromGamelistPath, Get-SCMMediaFolderNames

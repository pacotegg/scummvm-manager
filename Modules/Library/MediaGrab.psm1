Set-StrictMode -Version Latest

# =====================================================================
#  MediaGrab.psm1 - "buscar, elegir y colocar" media manualmente.
#   - Busqueda de imagenes por texto libre via DuckDuckGo (sin API key;
#     el sustituto practico de Google, que no tiene API libre usable).
#   - Coloca la imagen elegida en la carpeta correcta con el nombre de la
#     convencion y actualiza el campo de gamelist.xml correspondiente.
#   - Video: descarga un clip corto (<=15s por defecto) de YouTube con
#     yt-dlp (recorte con ffmpeg; ambos deben estar en el PATH).
#
#  Requiere: Config, GamelistXml (Get/Save/Find/Set), MediaFinder
#  (Save-SCMArtwork), MediaStatus.
# =====================================================================

# Mapa por tipo: carpeta destino, sufijo de fichero, campo de gamelist
# (vacio = no se toca gamelist), extension por defecto y pista de busqueda.
function Get-SCMMediaSlot {
    param([Parameter(Mandatory)][ValidateSet('image', 'fanart', 'marquee', 'snap', 'video')][string]$Type)
    switch ($Type) {
        'image'   { @{ Folder = 'images';   Suffix = '-image';   Field = 'image';   Ext = '.jpg'; Hint = 'cover art box';     Label = 'Portada' } }
        'fanart'  { @{ Folder = 'images';   Suffix = '-fanart';  Field = 'fanart';  Ext = '.jpg'; Hint = 'fanart wallpaper';   Label = 'Fanart' } }
        'marquee' { @{ Folder = 'marquees'; Suffix = '-marquee'; Field = 'marquee'; Ext = '.png'; Hint = 'logo transparent';  Label = 'Marquee/logo' } }
        'snap'    { @{ Folder = 'snaps';    Suffix = '-snap';    Field = '';        Ext = '.jpg'; Hint = 'screenshot gameplay'; Label = 'Snap' } }
        'video'   { @{ Folder = 'videos';   Suffix = '-video';   Field = 'video';   Ext = '.mp4'; Hint = 'gameplay';           Label = 'Video' } }
    }
}

function Initialize-SCMGrabTls {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
}

$script:GrabUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# Busca imagenes por texto libre en DuckDuckGo. Devuelve una lista de
# @{ Image; Thumb; Width; Height; Title }. Sin credenciales.
function Search-SCMDdgImages {
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$Max = 24
    )
    Initialize-SCMGrabTls
    $results = @()
    try {
        $q = [uri]::EscapeDataString($Query)
        # 1) token vqd de la pagina de busqueda
        $page = Invoke-WebRequest -Uri "https://duckduckgo.com/?q=$q&iar=images&iax=images&ia=images" `
            -Headers @{ 'User-Agent' = $script:GrabUA } -TimeoutSec 12 -UseBasicParsing
        $m = [regex]::Match($page.Content, 'vqd=([\d-]+)')
        if (-not $m.Success) { $m = [regex]::Match($page.Content, 'vqd="([^"]+)"') }
        if (-not $m.Success) { return @() }
        $vqd = $m.Groups[1].Value

        # 2) endpoint de imagenes
        Start-Sleep -Milliseconds 350
        $iurl = "https://duckduckgo.com/i.js?l=us-en&o=json&q=$q&vqd=$vqd&f=,,,&p=1"
        $r = Invoke-RestMethod -Uri $iurl -Headers @{ 'User-Agent' = $script:GrabUA; 'Referer' = 'https://duckduckgo.com/' } -TimeoutSec 12
        if ($r -and $r.PSObject.Properties.Name -contains 'results') {
            foreach ($it in @($r.results | Select-Object -First $Max)) {
                $results += [PSCustomObject]@{
                    Image  = [string]$it.image
                    Thumb  = [string]$it.thumbnail
                    Width  = [int]$it.width
                    Height = [int]$it.height
                    Title  = [string]$it.title
                }
            }
        }
    }
    catch { $results = @() }
    return @($results)
}

# Borra cualquier fichero previo <folder><suffix>.* del slot (para no dejar
# duplicados con otra extension) y devuelve la carpeta destino (creada).
function Clear-SCMMediaSlotFiles {
    param([string]$RomFolder, [hashtable]$Slot, [string]$FolderName)
    $dir = Join-Path $RomFolder $Slot.Folder
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($FolderName + $Slot.Suffix) + '\.') } |
        ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
    return $dir
}

# Actualiza el campo de media del <game> en gamelist.xml (si el slot lo tiene).
function Update-SCMGamelistMediaField {
    param([string]$RomFolder, [string]$FolderName, [string]$Field, [string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($Field)) { return }
    $gl = Join-Path $RomFolder 'gamelist.xml'
    try {
        $doc = Get-SCMGamelistDocument -Path $gl
        $entry = Find-SCMGamelistEntryByFolder -Doc $doc -FolderName $FolderName
        if ($null -ne $entry) {
            Set-SCMGamelistEntryField -GameNode $entry -Field $Field -Value $RelPath
            Save-SCMGamelistDocument -Doc $doc -Path $gl
        }
    }
    catch { }
}

# Descarga una URL de imagen al slot correcto y actualiza gamelist.
# Devuelve @{ Ok; Dest; Rel }.
function Save-SCMGrabbedImage {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('image', 'fanart', 'marquee', 'snap')][string]$Type,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$RomFolder
    )
    $slot = Get-SCMMediaSlot -Type $Type
    $ext = [System.IO.Path]::GetExtension(($Url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($ext) -or $ext.Length -gt 5) { $ext = $slot.Ext }

    $dir = Clear-SCMMediaSlotFiles -RomFolder $RomFolder -Slot $slot -FolderName $FolderName
    $dest = Join-Path $dir ("{0}{1}{2}" -f $FolderName, $slot.Suffix, $ext)

    Initialize-SCMGrabTls
    if (-not (Save-SCMArtwork -Url $Url -Dest $dest)) {
        return @{ Ok = $false; Dest = $null; Rel = $null }
    }
    $rel = "./{0}/{1}" -f $slot.Folder, (Split-Path $dest -Leaf)
    Update-SCMGamelistMediaField -RomFolder $RomFolder -FolderName $FolderName -Field $slot.Field -RelPath $rel
    return @{ Ok = $true; Dest = $dest; Rel = $rel }
}

# --- Video (yt-dlp + ffmpeg) -----------------------------------------

function Test-SCMYtDlp {
    return ($null -ne (Get-Command yt-dlp -ErrorAction SilentlyContinue))
}
function Test-SCMFfmpeg {
    return ($null -ne (Get-Command ffmpeg -ErrorAction SilentlyContinue))
}

# Ejecuta un proceso capturando salida sin que stderr aborte (EAP del llamante).
function Invoke-SCMProc {
    param([string]$Exe, [string[]]$ArgList)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = ''
    try { $out = (& $Exe @ArgList 2>&1 | Out-String) } catch { $out = "$_" } finally { $ErrorActionPreference = $prevEAP }
    return $out
}

# Descarga un clip de GAMEPLAY (no intro) de YouTube y lo comprime al maximo
# manteniendo calidad decente (480p, H.264 CRF 30). Coge una seccion central
# del video para saltarse logos/intro. $Source = URL de YouTube o texto de
# busqueda. Requiere yt-dlp + ffmpeg en el PATH. Devuelve @{ Ok; Dest; Log }.
function Save-SCMVideoClip {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$RomFolder,
        [int]$MaxSeconds = 15
    )
    if (-not (Test-SCMYtDlp)) { return @{ Ok = $false; Dest = $null; Log = 'yt-dlp no esta en el PATH.' } }
    if (-not (Test-SCMFfmpeg)) { return @{ Ok = $false; Dest = $null; Log = 'ffmpeg no esta en el PATH (necesario para comprimir).' } }

    $slot = Get-SCMMediaSlot -Type 'video'
    $dir = Clear-SCMMediaSlotFiles -RomFolder $RomFolder -Slot $slot -FolderName $FolderName
    $dest = Join-Path $dir ("{0}{1}.mp4" -f $FolderName, $slot.Suffix)

    $isUrl = $Source -match '^(https?://|www\.)'
    $target = if ($isUrl) { $Source } else { "ytsearch1:$Source" }
    $logAll = ''

    # 1) Resolver el video (id + duracion) para elegir un tramo de gameplay.
    $meta = Invoke-SCMProc -Exe 'yt-dlp' -ArgList @('--no-warnings', '--no-playlist', '--skip-download', '-I', '1', '--print', '%(id)s|%(duration)s', $target)
    $logAll += $meta
    $id = $null; $dur = 0
    $line = @($meta -split "`n" | Where-Object { $_ -match '\|' } | Select-Object -First 1)
    if ($line.Count -gt 0) {
        $parts = ($line[0].Trim() -split '\|', 2)
        $id = $parts[0]
        if ($parts.Count -gt 1) { [int]::TryParse(($parts[1] -replace '[^\d]', ''), [ref]$dur) | Out-Null }
    }
    if ([string]::IsNullOrWhiteSpace($id)) { return @{ Ok = $false; Dest = $null; Log = $logAll } }
    $videoUrl = if ($isUrl) { $Source } else { "https://www.youtube.com/watch?v=$id" }

    # Offset "gameplay": ~30% del video, saltando al menos 45s de intro, pero
    # dejando margen al final. Si el video es corto, empieza en 0.
    $start = 0
    if ($dur -gt ($MaxSeconds + 50)) {
        $cand = [int][math]::Floor($dur * 0.30)
        if ($cand -lt 45) { $cand = 45 }
        $maxStart = $dur - $MaxSeconds - 5
        if ($cand -gt $maxStart) { $cand = $maxStart }
        if ($cand -lt 0) { $cand = 0 }
        $start = $cand
    }
    $end = $start + $MaxSeconds + 2   # un poco de margen; ffmpeg recorta a $MaxSeconds

    # 2) Descargar SOLO ese tramo (copia, sin recodificar) a un temporal.
    $tmpBase = Join-Path $env:TEMP ('scmvid_' + [guid]::NewGuid().ToString('N'))
    $tmpOut = "$tmpBase.%(ext)s"
    $dl = Invoke-SCMProc -Exe 'yt-dlp' -ArgList @(
        '--no-warnings', '--no-playlist',
        '-f', 'b[height<=720]/bv*[height<=720]+ba/b',
        '--download-sections', ("*{0}-{1}" -f $start, $end),
        '-o', $tmpOut,
        $videoUrl
    )
    $logAll += "`n" + $dl

    $tmpFile = Get-ChildItem -Path (Split-Path $tmpBase -Parent) -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ((Split-Path $tmpBase -Leaf) + '.*') } | Select-Object -First 1
    if ($null -eq $tmpFile) { return @{ Ok = $false; Dest = $null; Log = $logAll } }

    # 3) Comprimir al maximo con calidad decente (480p, CRF 30, faststart).
    $ff = Invoke-SCMProc -Exe 'ffmpeg' -ArgList @(
        '-y', '-i', $tmpFile.FullName,
        '-t', "$MaxSeconds",
        '-vf', 'scale=-2:480',
        '-c:v', 'libx264', '-crf', '30', '-preset', 'slow', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '96k',
        '-movflags', '+faststart',
        $dest
    )
    $logAll += "`n" + $ff
    try { Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue } catch { }

    if (-not (Test-Path $dest)) { return @{ Ok = $false; Dest = $null; Log = $logAll } }

    $rel = "./{0}/{1}" -f $slot.Folder, (Split-Path $dest -Leaf)
    Update-SCMGamelistMediaField -RomFolder $RomFolder -FolderName $FolderName -Field $slot.Field -RelPath $rel
    return @{ Ok = $true; Dest = $dest; Log = $logAll }
}

# --- Manuales (archive.org: PDF; el mejor formato para RetroBat) -------

$script:ArcUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

# Devuelve la URL del PDF mas grande de un item de archive.org, o $null.
function Get-SCMArchivePdfUrl {
    param([string]$Id)
    try {
        Initialize-SCMGrabTls
        $r = Invoke-RestMethod -Uri "https://archive.org/metadata/$Id" -Headers @{ 'User-Agent' = $script:ArcUA } -TimeoutSec 10
        if ($r -and $r.PSObject.Properties.Name -contains 'files') {
            $pdf = @($r.files | Where-Object { $_.PSObject.Properties.Name -contains 'name' -and $_.name -like '*.pdf' } |
                Sort-Object { try { [long]$_.size } catch { 0 } } -Descending | Select-Object -First 1)
            if ($pdf.Count -gt 0) {
                return "https://archive.org/download/$Id/" + [uri]::EscapeDataString([string]$pdf[0].name)
            }
        }
    }
    catch { }
    return $null
}

# Busca manuales en archive.org y devuelve solo los items que tienen un PDF
# descargable: @{ Id; Title; PdfUrl }. Hace una llamada de metadata por item.
function Search-SCMArchiveManuals {
    param([Parameter(Mandatory)][string]$Query, [int]$Max = 8)
    Initialize-SCMGrabTls
    $out = @()
    try {
        $q = [uri]::EscapeDataString(($Query + ' manual'))
        $url = "https://archive.org/advancedsearch.php?q=$q&fl[]=identifier&fl[]=title&rows=20&page=1&output=json"
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $script:ArcUA } -TimeoutSec 15

        # Palabras significativas del titulo del juego, para puntuar relevancia.
        $qWords = @(($Query.ToLowerInvariant() -split '\W+') | Where-Object { $_.Length -ge 4 })

        $docs = @($r.response.docs)
        # Pre-filtrar por titulo relevante (contiene 'manual' o una palabra del
        # juego) ANTES de las llamadas de metadata; ahorra peticiones y ruido.
        $relevant = @($docs | Where-Object {
                $t = ([string]$_.title).ToLowerInvariant()
                ($t -match 'manual') -or (@($qWords | Where-Object { $t.Contains($_) }).Count -gt 0)
            })
        if ($relevant.Count -eq 0) { $relevant = $docs }

        foreach ($d in $relevant) {
            if ($out.Count -ge $Max) { break }
            $id = [string]$d.identifier
            $pdf = Get-SCMArchivePdfUrl -Id $id
            if (-not $pdf) { continue }
            $t = ([string]$d.title).ToLowerInvariant()
            $score = 0
            if ($t -match 'manual') { $score += 2 }
            $score += @($qWords | Where-Object { $t.Contains($_) }).Count
            $out += [PSCustomObject]@{ Id = $id; Title = [string]$d.title; PdfUrl = $pdf; Score = $score }
        }
        $out = @($out | Sort-Object -Property Score -Descending)
    }
    catch { $out = @() }
    return @($out)
}

# Descarga un manual (PDF) al slot manuals\ y actualiza gamelist <manual>.
function Save-SCMGrabbedManual {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$RomFolder
    )
    $dir = Join-Path $RomFolder 'manuals'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($FolderName + '-manual') + '\.') } |
        ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }

    $ext = [System.IO.Path]::GetExtension(($Url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($ext) -or $ext.Length -gt 5) { $ext = '.pdf' }
    $dest = Join-Path $dir ("{0}-manual{1}" -f $FolderName, $ext)

    Initialize-SCMGrabTls
    try {
        Invoke-WebRequest -Uri $Url -OutFile $dest -Headers @{ 'User-Agent' = $script:ArcUA } -TimeoutSec 120 -UseBasicParsing
    }
    catch {
        return @{ Ok = $false; Dest = $null }
    }
    if (-not (Test-Path $dest)) { return @{ Ok = $false; Dest = $null } }

    $rel = "./manuals/{0}" -f (Split-Path $dest -Leaf)
    Update-SCMGamelistMediaField -RomFolder $RomFolder -FolderName $FolderName -Field 'manual' -RelPath $rel
    return @{ Ok = $true; Dest = $dest; Rel = $rel }
}

Export-ModuleMember -Function `
    Get-SCMMediaSlot, Search-SCMDdgImages, Clear-SCMMediaSlotFiles, `
    Update-SCMGamelistMediaField, Save-SCMGrabbedImage, `
    Test-SCMYtDlp, Test-SCMFfmpeg, Save-SCMVideoClip, `
    Get-SCMArchivePdfUrl, Search-SCMArchiveManuals, Save-SCMGrabbedManual

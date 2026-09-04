Set-StrictMode -Version Latest

# =====================================================================
#  MediaFinder.psm1 - ayuda a rellenar la media que el scraper no cubre.
#   1) Asistente de busqueda: por cada juego, enlaces directos a Google
#      Imagenes / YouTube (longplay) / SteamGridDB / MobyGames, y te dice
#      el NOMBRE y CARPETA exactos donde soltar el fichero.
#   2) Descarga automatica de portadas via la API gratuita de SteamGridDB
#      (requiere API key en config: Preferences.ApiKeys.SteamGridDB).
#
#  No se hace scraping de Google (sin API libre, contra sus terminos y
#  fragil): para Google/YouTube se ABRE la busqueda y tu eliges.
# =====================================================================

function Get-SCMMediaSearchLinks {
    param([Parameter(Mandatory)][string]$Title)
    $q = [uri]::EscapeDataString($Title)
    return [ordered]@{
        "Google Imagenes"  = "https://www.google.com/search?tbm=isch&q=$q+adventure+game+cover"
        "YouTube longplay" = "https://www.youtube.com/results?search_query=$q+longplay"
        "SteamGridDB"      = "https://www.steamgriddb.com/search/grids?term=$q"
        "MobyGames"        = "https://www.mobygames.com/search/?q=$q"
        "Manual (archive)" = "https://archive.org/search?query=$q+manual"
    }
}

# Rutas destino (relativas a RomFolder) donde guardar cada tipo de media.
function Get-SCMMediaTargets {
    param([Parameter(Mandatory)][string]$FolderName)
    return [ordered]@{
        "Portada/imagen" = "images\$FolderName-image.png"
        "Miniatura"      = "images\$FolderName-thumb.png"
        "Fanart"         = "images\$FolderName-fanart.jpg"
        "Video"          = "videos\$FolderName-video.mp4"
        "Manual"         = "manuals\$FolderName-manual.pdf"
    }
}

# --- SteamGridDB (API gratuita, requiere key) -------------------------

function Get-SCMSteamGridKey {
    try {
        $c = Get-SCMConfig
        if (($c.Preferences.PSObject.Properties.Name -contains "ApiKeys") -and
            ($c.Preferences.ApiKeys.PSObject.Properties.Name -contains "SteamGridDB")) {
            return [string]$c.Preferences.ApiKeys.SteamGridDB
        }
    }
    catch { }
    return ""
}

function Initialize-SCMTls {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
}

# Busca el juego en SteamGridDB y devuelve su id (o $null).
function Find-SCMSteamGridGameId {
    param([Parameter(Mandatory)][string]$Term, [Parameter(Mandatory)][string]$Key)
    Initialize-SCMTls
    $q = [uri]::EscapeDataString($Term)
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$q" -Headers $headers -TimeoutSec 20
        if ($r.success -and @($r.data).Count -gt 0) { return $r.data[0].id }
    }
    catch { }
    return $null
}

# Devuelve la URL de una portada (grid vertical) para un gameId, o $null.
function Get-SCMSteamGridCoverUrl {
    param([Parameter(Mandatory)][int]$GameId, [Parameter(Mandatory)][string]$Key)
    Initialize-SCMTls
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/grids/game/$GameId`?dimensions=600x900" -Headers $headers -TimeoutSec 20
        if ($r.success -and @($r.data).Count -gt 0) { return $r.data[0].url }
    }
    catch { }
    # Fallback sin filtro de dimensiones.
    try {
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/grids/game/$GameId" -Headers $headers -TimeoutSec 20
        if ($r.success -and @($r.data).Count -gt 0) { return $r.data[0].url }
    }
    catch { }
    return $null
}

# (Invoke-SCMSteamGridDownloadCovers eliminada 2026-07-10: codigo muerto,
#  sustituida por el flujo con preview Get-SCMSteamGridMatches +
#  Invoke-SCMSteamGridDownloadFromMatches.)

# Autocompletado con nombre + id (para previsualizar antes de bajar).
function Find-SCMSteamGridMatch {
    param([Parameter(Mandatory)][string]$Term, [Parameter(Mandatory)][string]$Key)
    Initialize-SCMTls
    $q = [uri]::EscapeDataString($Term)
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$q" -Headers $headers -TimeoutSec 20
        if ($r.success -and @($r.data).Count -gt 0) {
            return [PSCustomObject]@{ Id = $r.data[0].id; Name = $r.data[0].name }
        }
    }
    catch { }
    return $null
}

# Previsualiza: para cada juego SIN el arte pedido, que juego casaria en
# SteamGridDB (autocompletado). $Kind: "cover" (falta imagen) o "marquee".
function Get-SCMSteamGridMatches {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet("cover", "marquee")][string]$Kind = "cover"
    )
    $mediaIndex = Get-SCMMediaIndex -RomFolder $RomFolder
    $out = @()
    foreach ($g in $Games) {
        $folder = Split-Path $g.FullPath -Leaf
        $st = Get-SCMMediaStatus -Index $mediaIndex -FolderName $folder
        $alreadyHas = if ($Kind -eq "marquee") { $st.Marquee } else { $st.Image }
        if ($alreadyHas) { continue }
        $m = Find-SCMSteamGridMatch -Term $g.Title -Key $Key
        $out += [PSCustomObject]@{
            Game        = $g
            Folder      = $folder
            MatchId     = if ($m) { $m.Id } else { $null }
            MatchName   = if ($m) { $m.Name } else { "(sin coincidencia)" }
        }
    }
    return @($out)
}

# Descarga una URL de arte a un fichero destino. Devuelve $true/$false.
# Con User-Agent de navegador: las APIs (SGDB/SS/Libretro) lo ignoran, pero el
# fallback DuckDuckGo apunta a webs arbitrarias que devuelven 403 sin UA.
function Save-SCMArtwork {
    param([string]$Url, [string]$Dest)
    if ([string]::IsNullOrEmpty($Url)) { return $false }
    try {
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        Invoke-WebRequest -Uri $Url -OutFile $Dest -TimeoutSec 40 -UseBasicParsing -Headers @{ 'User-Agent' = $ua }
        return $true
    }
    catch { return $false }
}

# URL de logo/marquee (transparente) para un gameId.
function Get-SCMSteamGridLogoUrl {
    param([Parameter(Mandatory)][int]$GameId, [Parameter(Mandatory)][string]$Key)
    Initialize-SCMTls
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/logos/game/$GameId" -Headers $headers -TimeoutSec 20
        if ($r.success -and @($r.data).Count -gt 0) { return $r.data[0].url }
    }
    catch { }
    return $null
}

# Descarga a partir de una lista de matches ya resuelta (portadas o marquees).
function Invoke-SCMSteamGridDownloadFromMatches {
    param(
        [Parameter(Mandatory)][array]$Matches,
        [Parameter(Mandatory)][string]$RomFolder,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet("cover", "marquee")][string]$Kind = "cover"
    )

    $targetDir = if ($Kind -eq "marquee") { Join-Path $RomFolder "marquees" } else { Join-Path $RomFolder "images" }
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

    $ok = 0; $fail = @()
    foreach ($m in $Matches) {
        if ($null -eq $m.MatchId) { $fail += ("{0} (sin match)" -f $m.Folder); continue }

        $url = if ($Kind -eq "marquee") {
            Get-SCMSteamGridLogoUrl -GameId $m.MatchId -Key $Key
        } else {
            Get-SCMSteamGridCoverUrl -GameId $m.MatchId -Key $Key
        }
        if ([string]::IsNullOrEmpty($url)) { $fail += ("{0} (sin arte)" -f $m.Folder); continue }

        $ext = [System.IO.Path]::GetExtension(($url -split '\?')[0])
        if ([string]::IsNullOrEmpty($ext)) { $ext = ".png" }
        $suffix = if ($Kind -eq "marquee") { "-marquee" } else { "-image" }
        $dest = Join-Path $targetDir ("{0}{1}{2}" -f $m.Folder, $suffix, $ext)

        if (Save-SCMArtwork -Url $url -Dest $dest) {
            $ok++
            Write-Host ("    OK -> {0}" -f (Split-Path $dest -Leaf)) -ForegroundColor $global:SCMTheme.Ok
        }
        else { $fail += ("{0} (fallo descarga)" -f $m.Folder) }
    }
    Write-Host ""
    Write-Host ("  Descargadas: {0}   Fallos: {1}" -f $ok, @($fail).Count) -ForegroundColor $global:SCMTheme.Ok
    foreach ($f in @($fail | Select-Object -First 30)) { Write-Host ("   ! {0}" -f $f) -ForegroundColor $global:SCMTheme.Dim }
    return [PSCustomObject]@{ Downloaded = $ok; Failed = @($fail).Count }
}

# Genera miniaturas (-thumb) redimensionando la portada (-image) existente.
function Invoke-SCMGenerateThumbnails {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder,
        [int]$Width = 320
    )
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop }
    catch {
        Write-Host "  No se pudo cargar System.Drawing (necesario para miniaturas)." -ForegroundColor $global:SCMTheme.Error
        return
    }

    $imagesDir = Join-Path $RomFolder "images"
    if (-not (Test-Path $imagesDir)) { Write-Host "  No hay carpeta images." -ForegroundColor $global:SCMTheme.Warn; return }

    $ok = 0; $skip = 0
    foreach ($g in $Games) {
        $folder = Split-Path $g.FullPath -Leaf
        $src = Get-ChildItem -Path $imagesDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ("^" + [regex]::Escape("$folder-image") + "\.") } |
            Select-Object -First 1
        if ($null -eq $src) { continue }   # sin portada de la que sacar miniatura
        $thumb = Get-ChildItem -Path $imagesDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ("^" + [regex]::Escape("$folder-thumb") + "\.") } |
            Select-Object -First 1
        if ($null -ne $thumb) { $skip++; continue }   # ya tiene miniatura

        $dest = Join-Path $imagesDir ("$folder-thumb.png")
        try {
            $img = [System.Drawing.Image]::FromFile($src.FullName)
            $ratio = $Width / $img.Width
            $w = $Width; $h = [int]($img.Height * $ratio)
            $bmp = New-Object System.Drawing.Bitmap $w, $h
            $gr = [System.Drawing.Graphics]::FromImage($bmp)
            $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $gr.DrawImage($img, 0, 0, $w, $h)
            $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
            $gr.Dispose(); $bmp.Dispose(); $img.Dispose()
            $ok++
        }
        catch { }
    }
    Write-Host ""
    Write-Host ("  Miniaturas generadas: {0}   Ya tenian: {1}" -f $ok, $skip) -ForegroundColor $global:SCMTheme.Ok
}

Export-ModuleMember -Function `
    Get-SCMMediaSearchLinks, Get-SCMMediaTargets, Get-SCMSteamGridKey, `
    Find-SCMSteamGridGameId, Get-SCMSteamGridCoverUrl, `
    Find-SCMSteamGridMatch, Get-SCMSteamGridMatches, Save-SCMArtwork, Get-SCMSteamGridLogoUrl, `
    Invoke-SCMSteamGridDownloadFromMatches, Invoke-SCMGenerateThumbnails

Set-StrictMode -Version Latest

# =====================================================================
#  Scrapers.psm1 - descarga de media multi-fuente con FALLBACK.
#
#  Por cada tipo de media (image/fanart/marquee/snap/video/manual) se prueban
#  varias fuentes EN ORDEN; la primera que devuelve una URL gana. Cada fuente
#  esta envuelta en try/catch: si falla o no tiene el arte, se devuelve $null y
#  el motor pasa a la siguiente fuente (nunca rompe la ejecucion).
#
#  Fuentes:
#    - SteamGridDB  (key)            : image(grid), fanart(hero), marquee(logo)
#    - ScreenScraper (dev+user creds): image, fanart, marquee, snap, video, manual
#    - TheGamesDB   (apikey)         : image(boxart), snap(screenshot), fanart, marquee(clearlogo)
#    - Libretro thumbnails (sin creds): image(boxart), snap
#
#  Requiere (importados por quien use este modulo): Config, MediaStatus,
#  MediaFinder (Save-SCMArtwork, Initialize-SCMTls, Get-SCMSteamGrid*).
# =====================================================================

$script:MediaRootByType = @{
    image = 'images'; fanart = 'images'; marquee = 'marquees'; snap = 'snaps'; video = 'videos'; manual = 'manuals'
}
$script:SuffixByType = @{
    image = '-image'; fanart = '-fanart'; marquee = '-marquee'; snap = '-snap'; video = '-video'; manual = '-manual'
}
# Campo de gamelist.xml por tipo (snap no tiene: es solo fichero por convencion).
$script:GamelistFieldByType = @{
    image = 'image'; fanart = 'fanart'; marquee = 'marquee'; video = 'video'; manual = 'manual'
}
# Todos los tipos soportados, en orden de presentacion.
$script:AllMediaTypes = @('image', 'snap', 'video', 'marquee', 'fanart', 'manual')

# TLS 1.2 propio del modulo. NO usar Initialize-SCMTls de MediaFinder: no esta
# exportada, asi que no es visible desde el scope de este modulo (daria
# command-not-found, que el try/catch tragaria dejando las fuentes "vacias").
function Set-SCMScraperTls {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
}

# Normaliza un titulo para comparar (sin tildes, sin parentesis, sin simbolos,
# sin articulo inicial). "Beneath a Steel Sky (CD_DOS)" -> "beneathsteelsky".
function ConvertTo-SCMNorm {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text
    # quitar cualquier "(...)" o "[...]"
    $t = [regex]::Replace($t, '[\(\[].*?[\)\]]', ' ')
    # quitar tildes
    $t = [string]::Join('', ($t.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray() |
        Where-Object { [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark }))
    $t = $t.ToLowerInvariant()
    # articulo "the" al principio o al final tras coma ("Dig, The")
    $t = [regex]::Replace($t, ',\s*the\b', ' ')
    $t = [regex]::Replace($t, '^the\b', ' ')
    # solo alfanumerico
    $t = [regex]::Replace($t, '[^a-z0-9]', '')
    return $t
}

# --- Credenciales -----------------------------------------------------
function Get-SCMScreenScraperCreds {
    try {
        $c = Get-SCMConfig
        if ($c.Preferences.PSObject.Properties.Name -notcontains 'Scrapers') { return $null }
        $s = $c.Preferences.Scrapers
        if ($s.PSObject.Properties.Name -notcontains 'ScreenScraper') { return $null }
        $ss = $s.ScreenScraper
        $get = { param($n) if ($ss.PSObject.Properties.Name -contains $n) { [string]$ss.$n } else { '' } }
        $devid = & $get 'DevId'; $devpass = & $get 'DevPassword'
        $user = & $get 'User'; $pass = & $get 'Password'
        if ([string]::IsNullOrWhiteSpace($devid) -or [string]::IsNullOrWhiteSpace($devpass)) { return $null }
        return @{ DevId = $devid; DevPassword = $devpass; User = $user; Password = $pass; SoftName = 'ScummVMCollectionManager' }
    } catch { return $null }
}
function Get-SCMTgdbKey {
    try {
        $c = Get-SCMConfig
        if ($c.Preferences.PSObject.Properties.Name -contains 'Scrapers' -and
            $c.Preferences.Scrapers.PSObject.Properties.Name -contains 'TheGamesDB' -and
            $c.Preferences.Scrapers.TheGamesDB.PSObject.Properties.Name -contains 'ApiKey') {
            return [string]$c.Preferences.Scrapers.TheGamesDB.ApiKey
        }
    } catch { }
    return ''
}
function Get-SCMMobyKey {
    try {
        $c = Get-SCMConfig
        if ($c.Preferences.PSObject.Properties.Name -contains 'Scrapers' -and
            $c.Preferences.Scrapers.PSObject.Properties.Name -contains 'MobyGames' -and
            $c.Preferences.Scrapers.MobyGames.PSObject.Properties.Name -contains 'ApiKey') {
            return [string]$c.Preferences.Scrapers.MobyGames.ApiKey
        }
    } catch { }
    return ''
}

# =====================================================================
#  ScreenScraper (una peticion por juego devuelve TODAS las medias)
# =====================================================================
$script:SSRegionPref = @('wor', 'eu', 'ss', 'us', 'jp', 'fr')
$script:SSTypeMap = @{
    image   = @('box-2D', 'box-3D', 'mixrbv2', 'mixrbv1')
    fanart  = @('fanart')
    marquee = @('wheel', 'wheel-hd', 'screenmarquee', 'wheel-carbon', 'wheel-steel')
    snap    = @('ss', 'sstitle')
    video   = @('video-normalized', 'video')
    manual  = @('manuel')
}
# Guardado de cuota (obligatorio por el doc de la API v2). maxthreads=1 en cuentas
# nivel 1: SIEMPRE secuencial, nunca en paralelo. Si se agota la cuota o la API
# responde limite/cerrada, se activa para no seguir aporreando en este lote.
$script:SSBlocked = $false

# Credenciales SS cacheadas por lote (en $Ctx): evita releer/parsear
# config.json en cada juego x tipo.
function Get-SCMSsCredsCached {
    param([hashtable]$Ctx)
    if ($null -eq $Ctx) { return (Get-SCMScreenScraperCreds) }
    if (-not $Ctx.ContainsKey('ss:creds')) { $Ctx['ss:creds'] = Get-SCMScreenScraperCreds }
    return $Ctx['ss:creds']
}

function Get-SCMScreenScraperMedias {
    param([string]$Term, [hashtable]$Ctx)
    if ($script:SSBlocked) { return @() }   # cuota agotada / API cerrada en este lote
    $key = 'ss:' + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($key)) { return $Ctx[$key] }
    $creds = Get-SCMSsCredsCached -Ctx $Ctx
    if (-not $creds) { return @() }

    $medias = @()
    try {
        Set-SCMScraperTls
        $q = [uri]::EscapeDataString($Term)
        # Endpoint de BUSQUEDA por nombre: jeuRecherche.php + recherche.
        # (jeuInfos.php espera romnom/hash; con 'recherche' da 400 "champs obligatoires".)
        $url = "https://api.screenscraper.fr/api2/jeuRecherche.php?devid=$($creds.DevId)&devpassword=$($creds.DevPassword)&softname=$($creds.SoftName)&output=json&ssid=$([uri]::EscapeDataString($creds.User))&sspassword=$([uri]::EscapeDataString($creds.Password))&systemeid=123&recherche=$q"
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 30
        if ($r -and $r.PSObject.Properties.Name -contains 'response' -and
            $r.response.PSObject.Properties.Name -contains 'jeux') {
            $jeux = @($r.response.jeux)
            if ($jeux.Count -gt 0) {
                # Preferir el juego cuyo nombre casa con el titulo buscado (como
                # hacen el resto de fuentes): el primer resultado de la busqueda
                # puede ser OTRO juego (titulos cortos/ambiguos tipo "The Dig").
                $best = $null
                $normTerm = ConvertTo-SCMNorm $Term
                foreach ($j in $jeux) {
                    $names = @()
                    try { if ($j.PSObject.Properties.Name -contains 'noms') { foreach ($n in @($j.noms)) { if ($n.PSObject.Properties.Name -contains 'text') { $names += [string]$n.text } } } } catch { }
                    try { if ($j.PSObject.Properties.Name -contains 'nom') { $names += [string]$j.nom } } catch { }
                    foreach ($nm in $names) { if ((ConvertTo-SCMNorm $nm) -eq $normTerm) { $best = $j; break } }
                    if ($best) { break }
                }
                if (-not $best) { $best = $jeux[0] }
                if ($best.PSObject.Properties.Name -contains 'medias') { $medias = @($best.medias) }
            }
        }
        # Gestion de cuota: si ya se alcanzo el maximo diario, no seguir pidiendo.
        try {
            $u = $r.response.ssuser
            if ($u -and ([int]$u.requeststoday) -ge ([int]$u.maxrequestsperday) -and ([int]$u.maxrequestsperday) -gt 0) { $script:SSBlocked = $true }
        } catch { }
    } catch {
        # Limite/cuota excedida o API cerrada -> bloquear ScreenScraper este lote.
        $emsg = "$($_.Exception.Message)"; $body = ''
        try { $body = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        if ($emsg -match '429|430' -or $body -match 'quota|maximum|ferm|closed|totalement') { $script:SSBlocked = $true }
        $medias = @()
    }
    $Ctx[$key] = $medias
    return $medias
}

function Resolve-SCMScreenScraper {
    param([string]$Type, [string]$Term, [hashtable]$Ctx)
    if (-not $script:SSTypeMap.ContainsKey($Type)) { return $null }
    $medias = Get-SCMScreenScraperMedias -Term $Term -Ctx $Ctx
    if (@($medias).Count -eq 0) { return $null }
    $creds = Get-SCMSsCredsCached -Ctx $Ctx
    foreach ($sstype in $script:SSTypeMap[$Type]) {
        $cands = @($medias | Where-Object { $_.PSObject.Properties.Name -contains 'type' -and $_.type -eq $sstype })
        if ($cands.Count -eq 0) { continue }
        $pick = $null
        foreach ($reg in $script:SSRegionPref) {
            $pick = $cands | Where-Object { ($_.PSObject.Properties.Name -contains 'region') -and ($_.region -eq $reg) } | Select-Object -First 1
            if ($pick) { break }
        }
        if (-not $pick) { $pick = $cands | Select-Object -First 1 }
        if ($pick -and ($pick.PSObject.Properties.Name -contains 'url') -and $pick.url) {
            $ext = if ($pick.PSObject.Properties.Name -contains 'format' -and $pick.format) { '.' + $pick.format } else { '' }
            # Las URL de media de ScreenScraper suelen requerir las credenciales anexadas.
            $u = [string]$pick.url
            if ($creds -and $u -notmatch 'devid=') {
                $sep = if ($u.Contains('?')) { '&' } else { '?' }
                $u = "$u${sep}devid=$($creds.DevId)&devpassword=$($creds.DevPassword)&softname=$($creds.SoftName)&ssid=$([uri]::EscapeDataString($creds.User))&sspassword=$([uri]::EscapeDataString($creds.Password))"
            }
            return @{ Url = $u; Ext = $ext }
        }
    }
    return $null
}

# =====================================================================
#  SteamGridDB (image=grid, fanart=hero, marquee=logo)
# =====================================================================
function Get-SCMSteamGridHeroUrl {
    param([Parameter(Mandatory)][int]$GameId, [Parameter(Mandatory)][string]$Key)
    Set-SCMScraperTls
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/heroes/game/$GameId" -Headers $headers -TimeoutSec 20
        if ($r.success -and @($r.data).Count -gt 0) { return $r.data[0].url }
    } catch { }
    return $null
}

function Resolve-SCMSteamGrid {
    param([string]$Type, [string]$Term, [string]$Key, [hashtable]$Ctx)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if ($Type -notin @('image', 'fanart', 'marquee')) { return $null }
    $idKey = 'sgdbid:' + $Term.ToLowerInvariant()
    if (-not $Ctx.ContainsKey($idKey)) {
        $Ctx[$idKey] = Find-SCMSteamGridGameId -Term $Term -Key $Key
    }
    $id = $Ctx[$idKey]
    if ($null -eq $id) { return $null }
    $url = switch ($Type) {
        'image' { Get-SCMSteamGridCoverUrl -GameId $id -Key $Key }
        'fanart' { Get-SCMSteamGridHeroUrl -GameId $id -Key $Key }
        'marquee' { Get-SCMSteamGridLogoUrl -GameId $id -Key $Key }
    }
    if ([string]::IsNullOrEmpty($url)) { return $null }
    $ext = [System.IO.Path]::GetExtension(($url -split '\?')[0]); if (-not $ext) { $ext = '.png' }
    return @{ Url = $url; Ext = $ext }
}

# =====================================================================
#  TheGamesDB (boxart/screenshot/fanart/clearlogo)
# =====================================================================
$script:TgdbTypeMap = @{ image = 'boxart'; snap = 'screenshot'; fanart = 'fanart'; marquee = 'clearlogo' }

function Get-SCMTgdbData {
    param([string]$Term, [string]$Key, [hashtable]$Ctx)
    $ck = 'tgdb:' + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }
    $data = $null
    try {
        Set-SCMScraperTls
        $q = [uri]::EscapeDataString($Term)
        $r = Invoke-RestMethod -Uri "https://api.thegamesdb.net/v1/Games/ByGameName?apikey=$Key&name=$q&fields=game_title" -TimeoutSec 25
        $id = $null
        if ($r -and $r.PSObject.Properties.Name -contains 'data' -and $r.data.PSObject.Properties.Name -contains 'games' -and @($r.data.games).Count -gt 0) {
            $norm = ConvertTo-SCMNorm $Term
            $exact = @($r.data.games | Where-Object { (ConvertTo-SCMNorm $_.game_title) -eq $norm } | Select-Object -First 1)
            $id = if ($exact.Count -gt 0) { $exact[0].id } else { $r.data.games[0].id }
        }
        if ($id) {
            $img = Invoke-RestMethod -Uri "https://api.thegamesdb.net/v1/Games/Images?apikey=$Key&games_id=$id" -TimeoutSec 25
            $base = ''
            if ($img.PSObject.Properties.Name -contains 'data' -and $img.data.PSObject.Properties.Name -contains 'base_url') {
                $base = [string]$img.data.base_url.original
            }
            $list = @()
            if ($img.data.PSObject.Properties.Name -contains 'images' -and $img.data.images.PSObject.Properties.Name -contains "$id") {
                $list = @($img.data.images."$id")
            }
            $data = @{ Base = $base; Images = $list }
        }
    } catch { $data = $null }
    $Ctx[$ck] = $data
    return $data
}

function Resolve-SCMTgdb {
    param([string]$Type, [string]$Term, [string]$Key, [hashtable]$Ctx)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if (-not $script:TgdbTypeMap.ContainsKey($Type)) { return $null }
    $data = Get-SCMTgdbData -Term $Term -Key $Key -Ctx $Ctx
    if ($null -eq $data -or [string]::IsNullOrEmpty($data.Base)) { return $null }
    $want = $script:TgdbTypeMap[$Type]
    $hit = @($data.Images | Where-Object { $_.PSObject.Properties.Name -contains 'type' -and $_.type -eq $want } | Select-Object -First 1)
    if ($hit.Count -eq 0) { return $null }
    $fn = [string]$hit[0].filename
    if ([string]::IsNullOrWhiteSpace($fn)) { return $null }
    $url = $data.Base + $fn
    $ext = [System.IO.Path]::GetExtension($fn); if (-not $ext) { $ext = '.jpg' }
    return @{ Url = $url; Ext = $ext }
}

# =====================================================================
#  Libretro thumbnails (sin credenciales) - matching difuso por listado
# =====================================================================
$script:LrFolderByType = @{ image = @('Named_Boxarts'); snap = @('Named_Snaps', 'Named_Titles') }

# Un unico "git tree recursive" trae TODOS los ficheros del repo en una sola
# llamada (evita el tope de 1000 y no agota el rate-limit anonimo de GitHub).
function Get-SCMLibretroIndex {
    param([hashtable]$Ctx)
    $ck = 'lr:index'
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }
    $folders = @{ Named_Boxarts = @{}; Named_Snaps = @{}; Named_Titles = @{} }
    try {
        Set-SCMScraperTls
        $tree = Invoke-RestMethod -Uri "https://api.github.com/repos/libretro-thumbnails/ScummVM/git/trees/master?recursive=1" -Headers @{ 'User-Agent' = 'ScummVMCollectionManager' } -TimeoutSec 45
        if ($tree.PSObject.Properties.Name -contains 'tree') {
            foreach ($node in @($tree.tree)) {
                if (($node.PSObject.Properties.Name -notcontains 'type') -or ($node.type -ne 'blob')) { continue }
                # Saltar symlinks (mode 120000): son punteros de texto a la imagen
                # canonica; raw.githubusercontent serviria el texto, no el PNG.
                if (($node.PSObject.Properties.Name -contains 'mode') -and ($node.mode -eq '120000')) { continue }
                $path = [string]$node.path
                if ($path -notlike '*.png') { continue }
                $seg = $path.Split('/')
                if ($seg.Count -lt 2 -or -not $folders.ContainsKey($seg[0])) { continue }
                $norm = ConvertTo-SCMNorm ([System.IO.Path]::GetFileNameWithoutExtension($seg[-1]))
                if (-not $norm) { continue }
                $encoded = ($seg | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                $url = "https://raw.githubusercontent.com/libretro-thumbnails/ScummVM/master/$encoded"
                if (-not $folders[$seg[0]].ContainsKey($norm)) { $folders[$seg[0]][$norm] = $url }
            }
        }
    } catch { }
    $Ctx[$ck] = $folders
    return $folders
}

function Resolve-SCMLibretro {
    param([string]$Type, [string]$Term, [hashtable]$Ctx)
    if (-not $script:LrFolderByType.ContainsKey($Type)) { return $null }
    $norm = ConvertTo-SCMNorm $Term
    if (-not $norm) { return $null }
    $index = Get-SCMLibretroIndex -Ctx $Ctx
    foreach ($folder in $script:LrFolderByType[$Type]) {
        if (-not $index.ContainsKey($folder)) { continue }
        $map = $index[$folder]
        if ($map.Count -eq 0) { continue }
        if ($map.ContainsKey($norm)) { return @{ Url = $map[$norm]; Ext = '.png' } }
        if ($norm.Length -ge 5) {
            $hit = $map.Keys | Where-Object { $_.StartsWith($norm) } | Select-Object -First 1
            if ($hit) { return @{ Url = $map[$hit]; Ext = '.png' } }
        }
    }
    return $null
}

# =====================================================================
#  MobyGames (API v1, key gratuita) - portada + captura. La mejor cobertura
#  para aventuras graficas clasicas de PC. Free tier: 1 peticion/seg, ~360/h;
#  por eso hay throttle y se cachea el juego por titulo en $Ctx.
# =====================================================================
$script:MobyBase = 'https://api.mobygames.com/v1'

function Get-SCMMobyGame {
    param([string]$Term, [string]$Key, [hashtable]$Ctx)
    $ck = 'moby:' + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }

    $game = $null
    try {
        Set-SCMScraperTls
        # Throttle: el free tier exige <= 1 req/seg (si no, HTTP 429).
        Start-Sleep -Milliseconds 1100
        $q = [uri]::EscapeDataString($Term)
        $r = Invoke-RestMethod -Uri "$script:MobyBase/games?api_key=$Key&title=$q&format=normal" -TimeoutSec 30
        if ($r -and $r.PSObject.Properties.Name -contains 'games' -and @($r.games).Count -gt 0) {
            $norm = ConvertTo-SCMNorm $Term
            $exact = @($r.games | Where-Object { (ConvertTo-SCMNorm $_.title) -eq $norm } | Select-Object -First 1)
            $game = if ($exact.Count -gt 0) { $exact[0] } else { $r.games[0] }
        }
    } catch { $game = $null }
    $Ctx[$ck] = $game
    return $game
}

function Resolve-SCMMobyGames {
    param([string]$Type, [string]$Term, [string]$Key, [hashtable]$Ctx)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if ($Type -notin @('image', 'snap')) { return $null }   # MobyGames: portada + captura

    $game = Get-SCMMobyGame -Term $Term -Key $Key -Ctx $Ctx
    if ($null -eq $game) { return $null }

    $url = $null
    if ($Type -eq 'image') {
        if (($game.PSObject.Properties.Name -contains 'sample_cover') -and $game.sample_cover -and
            ($game.sample_cover.PSObject.Properties.Name -contains 'image')) {
            $url = [string]$game.sample_cover.image
        }
    }
    else {
        if (($game.PSObject.Properties.Name -contains 'sample_screenshots') -and @($game.sample_screenshots).Count -gt 0) {
            $url = [string]$game.sample_screenshots[0].image
        }
    }
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    $ext = [System.IO.Path]::GetExtension(($url -split '\?')[0]); if (-not $ext) { $ext = '.jpg' }
    return @{ Url = $url; Ext = $ext }
}

# =====================================================================
#  GiantBomb (API v1, key gratuita) - portada + captura. Buena cobertura de
#  juegos de PC. IMPORTANTE: exige una cabecera User-Agent propia (si no,
#  responde 403 / captcha). Free tier ~200 req/recurso/hora; throttle 1/seg.
# =====================================================================
$script:GbBase = 'https://www.giantbomb.com/api'
$script:GbUA = 'ScummVMCollectionManager/1.0'

function Get-SCMGiantBombKey {
    try {
        $c = Get-SCMConfig
        if ($c.Preferences.PSObject.Properties.Name -contains 'Scrapers' -and
            $c.Preferences.Scrapers.PSObject.Properties.Name -contains 'GiantBomb' -and
            $c.Preferences.Scrapers.GiantBomb.PSObject.Properties.Name -contains 'ApiKey') {
            return [string]$c.Preferences.Scrapers.GiantBomb.ApiKey
        }
    } catch { }
    return ''
}

# Algunas URL de GiantBomb vienen relativas; las normaliza a absolutas.
function Resolve-SCMGbUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ($Url.StartsWith('//')) { return 'https:' + $Url }
    if ($Url.StartsWith('/')) { return 'https://www.giantbomb.com' + $Url }
    return $Url
}

function Get-SCMGiantBombGame {
    param([string]$Term, [string]$Key, [hashtable]$Ctx)
    $ck = 'gb:' + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }

    $game = $null
    try {
        Set-SCMScraperTls
        Start-Sleep -Milliseconds 1100
        $q = [uri]::EscapeDataString($Term)
        $url = "$script:GbBase/search/?api_key=$Key&format=json&resources=game&limit=5&field_list=name,guid,image&query=$q"
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $script:GbUA } -TimeoutSec 30
        if ($r -and $r.PSObject.Properties.Name -contains 'results' -and @($r.results).Count -gt 0) {
            $norm = ConvertTo-SCMNorm $Term
            $exact = @($r.results | Where-Object { (ConvertTo-SCMNorm $_.name) -eq $norm } | Select-Object -First 1)
            $game = if ($exact.Count -gt 0) { $exact[0] } else { $r.results[0] }
        }
    } catch { $game = $null }
    $Ctx[$ck] = $game
    return $game
}

function Get-SCMGiantBombImages {
    param([string]$Guid, [string]$Key, [hashtable]$Ctx)
    $ck = 'gbimg:' + $Guid
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }

    $images = @()
    try {
        Set-SCMScraperTls
        Start-Sleep -Milliseconds 1100
        $url = "$script:GbBase/game/$Guid/?api_key=$Key&format=json&field_list=images"
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $script:GbUA } -TimeoutSec 30
        if ($r -and $r.PSObject.Properties.Name -contains 'results' -and
            $r.results.PSObject.Properties.Name -contains 'images') {
            $images = @($r.results.images)
        }
    } catch { $images = @() }
    $Ctx[$ck] = $images
    return $images
}

function Resolve-SCMGiantBomb {
    param([string]$Type, [string]$Term, [string]$Key, [hashtable]$Ctx)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if ($Type -notin @('image', 'snap')) { return $null }

    $game = Get-SCMGiantBombGame -Term $Term -Key $Key -Ctx $Ctx
    if ($null -eq $game) { return $null }

    $url = $null
    if ($Type -eq 'image') {
        if (($game.PSObject.Properties.Name -contains 'image') -and $game.image) {
            $img = $game.image
            foreach ($f in @('super_url', 'original_url', 'medium_url', 'screen_url')) {
                if (($img.PSObject.Properties.Name -contains $f) -and $img.$f) { $url = [string]$img.$f; break }
            }
        }
    }
    else {
        if (($game.PSObject.Properties.Name -contains 'guid') -and $game.guid) {
            $imgs = Get-SCMGiantBombImages -Guid ([string]$game.guid) -Key $Key -Ctx $Ctx
            $shot = @($imgs | Where-Object { ($_.PSObject.Properties.Name -contains 'tags') -and ($_.tags -like '*Screenshot*') } | Select-Object -First 1)
            if ($shot.Count -eq 0) { $shot = @($imgs | Select-Object -First 1) }
            if ($shot.Count -gt 0) {
                foreach ($f in @('super_url', 'original', 'medium_url', 'screen_url')) {
                    if (($shot[0].PSObject.Properties.Name -contains $f) -and $shot[0].$f) { $url = [string]$shot[0].$f; break }
                }
            }
        }
    }

    $url = Resolve-SCMGbUrl $url
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    $ext = [System.IO.Path]::GetExtension(($url -split '\?')[0]); if (-not $ext) { $ext = '.jpg' }
    return @{ Url = $url; Ext = $ext }
}

# =====================================================================
#  IGDB (Twitch OAuth) - portada + screenshot + artwork(fanart). Sin
#  Cloudflare. Requiere Client-ID + Client-Secret de un dev app de Twitch
#  (dev.twitch.tv). El token se pide una vez y se cachea en $Ctx.
# =====================================================================
function Get-SCMIgdbCreds {
    try {
        $c = Get-SCMConfig
        if ($c.Preferences.PSObject.Properties.Name -contains 'Scrapers' -and
            $c.Preferences.Scrapers.PSObject.Properties.Name -contains 'IGDB') {
            $ig = $c.Preferences.Scrapers.IGDB
            $get = { param($n) if ($ig.PSObject.Properties.Name -contains $n) { [string]$ig.$n } else { '' } }
            $cid = & $get 'ClientId'; $sec = & $get 'ClientSecret'
            if (-not [string]::IsNullOrWhiteSpace($cid) -and -not [string]::IsNullOrWhiteSpace($sec)) {
                return @{ ClientId = $cid; ClientSecret = $sec }
            }
        }
    }
    catch { }
    return $null
}

function Get-SCMIgdbToken {
    param([hashtable]$Ctx)
    if ($Ctx.ContainsKey('igdbtoken')) { return $Ctx['igdbtoken'] }
    $creds = Get-SCMIgdbCreds
    if (-not $creds) { $Ctx['igdbtoken'] = $null; return $null }
    $tok = $null
    try {
        Set-SCMScraperTls
        $u = "https://id.twitch.tv/oauth2/token?client_id=$($creds.ClientId)&client_secret=$($creds.ClientSecret)&grant_type=client_credentials"
        $r = Invoke-RestMethod -Uri $u -Method Post -TimeoutSec 25
        if ($r -and $r.PSObject.Properties.Name -contains 'access_token') {
            $tok = @{ Token = [string]$r.access_token; ClientId = $creds.ClientId }
        }
    }
    catch { $tok = $null }
    $Ctx['igdbtoken'] = $tok
    return $tok
}

function Get-SCMIgdbGame {
    param([string]$Term, [hashtable]$Ctx)
    $ck = 'igdb:' + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }
    $game = $null
    $tok = Get-SCMIgdbToken -Ctx $Ctx
    if ($tok) {
        try {
            Set-SCMScraperTls
            $headers = @{ 'Client-ID' = $tok.ClientId; 'Authorization' = "Bearer $($tok.Token)"; 'Accept' = 'application/json' }
            $safe = $Term -replace '"', ' '
            $body = 'search "' + $safe + '"; fields name,cover.image_id,screenshots.image_id,artworks.image_id; limit 6;'
            $r = Invoke-RestMethod -Uri 'https://api.igdb.com/v4/games' -Method Post -Headers $headers -Body $body -ContentType 'text/plain' -TimeoutSec 30
            if (@($r).Count -gt 0) {
                $norm = ConvertTo-SCMNorm $Term
                $exact = @($r | Where-Object { (ConvertTo-SCMNorm $_.name) -eq $norm } | Select-Object -First 1)
                $game = if ($exact.Count -gt 0) { $exact[0] } else { @($r)[0] }
            }
        }
        catch { $game = $null }
    }
    $Ctx[$ck] = $game
    return $game
}

function Resolve-SCMIgdb {
    param([string]$Type, [string]$Term, [hashtable]$Ctx)
    if ($Type -notin @('image', 'snap', 'fanart')) { return $null }
    $game = Get-SCMIgdbGame -Term $Term -Ctx $Ctx
    if ($null -eq $game) { return $null }

    $imgId = $null; $size = 't_1080p'
    if ($Type -eq 'image') {
        if (($game.PSObject.Properties.Name -contains 'cover') -and $game.cover -and ($game.cover.PSObject.Properties.Name -contains 'image_id')) {
            $imgId = [string]$game.cover.image_id; $size = 't_cover_big'
        }
    }
    elseif ($Type -eq 'snap') {
        if (($game.PSObject.Properties.Name -contains 'screenshots') -and @($game.screenshots).Count -gt 0) {
            $imgId = [string]@($game.screenshots)[0].image_id; $size = 't_screenshot_huge'
        }
    }
    else {
        if (($game.PSObject.Properties.Name -contains 'artworks') -and @($game.artworks).Count -gt 0) {
            $imgId = [string]@($game.artworks)[0].image_id; $size = 't_1080p'
        }
    }
    if ([string]::IsNullOrWhiteSpace($imgId)) { return $null }
    return @{ Url = "https://images.igdb.com/igdb/image/upload/$size/$imgId.jpg"; Ext = '.jpg' }
}

# =====================================================================
#  DuckDuckGo Images (sin key) - ULTIMO recurso para rellenar lo que las
#  APIs no encuentran. Usa Search-SCMDdgImages de MediaGrab (cargado en el
#  mismo runspace). Menos preciso (imagen web arbitraria), por eso va al final.
# =====================================================================
$script:DdgHintByType = @{
    image = 'cover art box'; fanart = 'fanart wallpaper'; snap = 'screenshot gameplay'; marquee = 'logo'
}
function Resolve-SCMDdg {
    param([string]$Type, [string]$Term, [hashtable]$Ctx)
    if (-not $script:DdgHintByType.ContainsKey($Type)) { return $null }
    if (-not (Get-Command Search-SCMDdgImages -ErrorAction SilentlyContinue)) { return $null }

    $ck = "ddg:${Type}:" + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }

    $res = $null
    try {
        $q = "{0} {1}" -f $Term, $script:DdgHintByType[$Type]
        $imgs = @(Search-SCMDdgImages -Query $q -Max 6)
        # Primer resultado con tamano razonable (evita iconos diminutos).
        $pick = @($imgs | Where-Object { $_.Width -ge 200 -and $_.Height -ge 200 } | Select-Object -First 1)
        if ($pick.Count -eq 0) { $pick = @($imgs | Select-Object -First 1) }
        if ($pick.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($pick[0].Image)) {
            $url = [string]$pick[0].Image
            $ext = [System.IO.Path]::GetExtension(($url -split '\?')[0]); if (-not $ext -or $ext.Length -gt 5) { $ext = '.jpg' }
            $res = @{ Url = $url; Ext = $ext }
        }
    }
    catch { $res = $null }
    $Ctx[$ck] = $res
    return $res
}

# =====================================================================
#  archive.org - manual (PDF). Solo para type='manual'. En lote solo baja si
#  hay confianza (score alto: titulo con 'manual' + palabra del juego).
# =====================================================================
function Resolve-SCMArchiveManual {
    param([string]$Term, [hashtable]$Ctx)
    if (-not (Get-Command Search-SCMArchiveManuals -ErrorAction SilentlyContinue)) { return $null }
    $ck = 'arcman:' + $Term.ToLowerInvariant()
    if ($Ctx.ContainsKey($ck)) { return $Ctx[$ck] }
    $res = $null
    try {
        $cands = @(Search-SCMArchiveManuals -Query $Term -Max 3)
        $best = @($cands | Where-Object { $_.Score -ge 3 } | Select-Object -First 1)
        if ($best.Count -gt 0) { $res = @{ Url = $best[0].PdfUrl; Ext = '.pdf' } }
    }
    catch { $res = $null }
    $Ctx[$ck] = $res
    return $res
}

# =====================================================================
#  Motor: resuelve por tipo probando fuentes en orden, y descarga.
# =====================================================================
function Resolve-SCMMediaUrl {
    param([string]$Type, [string]$Term, [string[]]$Order, [string]$SgdbKey, [string]$TgdbKey, [hashtable]$Ctx)
    # Keys de Moby/GiantBomb cacheadas por lote en $Ctx (evita releer config.json
    # en cada iteracion fuente x tarea).
    if (-not $Ctx.ContainsKey('key:moby')) { $Ctx['key:moby'] = Get-SCMMobyKey }
    if (-not $Ctx.ContainsKey('key:gb')) { $Ctx['key:gb'] = Get-SCMGiantBombKey }
    foreach ($src in $Order) {
        $res = $null
        switch ($src) {
            'SteamGridDB'   { $res = Resolve-SCMSteamGrid -Type $Type -Term $Term -Key $SgdbKey -Ctx $Ctx }
            'ScreenScraper' { $res = Resolve-SCMScreenScraper -Type $Type -Term $Term -Ctx $Ctx }
            'Archive'       { if ($Type -eq 'manual') { $res = Resolve-SCMArchiveManual -Term $Term -Ctx $Ctx } }
            'IGDB'          { $res = Resolve-SCMIgdb -Type $Type -Term $Term -Ctx $Ctx }
            'TheGamesDB'    { $res = Resolve-SCMTgdb -Type $Type -Term $Term -Key $TgdbKey -Ctx $Ctx }
            'MobyGames'     { $res = Resolve-SCMMobyGames -Type $Type -Term $Term -Key $Ctx['key:moby'] -Ctx $Ctx }
            'GiantBomb'     { $res = Resolve-SCMGiantBomb -Type $Type -Term $Term -Key $Ctx['key:gb'] -Ctx $Ctx }
            'Libretro'      { $res = Resolve-SCMLibretro -Type $Type -Term $Term -Ctx $Ctx }
            'Ddg'           { $res = Resolve-SCMDdg -Type $Type -Term $Term -Ctx $Ctx }
        }
        if ($res -and $res.Url) { return ([PSCustomObject]@{ Url = $res.Url; Ext = $res.Ext; Source = $src }) }
    }
    return $null
}

# Genera una miniatura -thumb.png a partir de una imagen ya descargada.
function New-SCMThumbForImage {
    param([string]$ImagePath, [string]$Folder, [string]$ImagesDir, [int]$Width = 320)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        $src = [System.Drawing.Image]::FromStream($ms)
        $w = $Width; if ($src.Width -le $Width) { $w = $src.Width }
        $h = [int]($src.Height * ($w / $src.Width))
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $w, $h)
        $g.Dispose(); $src.Dispose(); $ms.Dispose()
        $dest = Join-Path $ImagesDir ("{0}-thumb.png" -f $Folder)
        $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $true
    } catch { return $false }
}

# Descarga la media pedida (solo la que falta si -OnlyMissing) para todos los
# juegos, con fallback. $Sync (synchronized) recibe Done/Total/Current/Log.
# -RetryTasks: lista de tareas {Game;Folder;Type} exactas (para reintentar fallidos).
function Invoke-SCMScrapeMedia {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder,
        [string[]]$Types = @('image'),
        [bool]$OnlyMissing = $true,
        # GiantBomb NO va en el orden por defecto: su API esta tras Cloudflare y
        # devuelve 403 a cualquier cliente HTTP que no sea un navegador real.
        # Se deja el resolver por si en el futuro fuera accesible.
        [string[]]$Order = @('SteamGridDB', 'ScreenScraper', 'Archive', 'IGDB', 'MobyGames', 'TheGamesDB', 'Libretro', 'Ddg'),
        [hashtable]$Sync,
        [array]$RetryTasks
    )
    Set-SCMScraperTls

    # --- Log de diagnostico (Logs\media_debug.log) - configurar PRIMERO, para
    #     capturar tambien fallos tempranos (indice, config) a escala. ---
    $dbgLog = $null
    try {
        $cfgL = Get-SCMConfig
        if (-not (Test-Path $cfgL.Paths.Logs)) { New-Item -ItemType Directory -Path $cfgL.Paths.Logs -Force | Out-Null }
        $dbgLog = Join-Path $cfgL.Paths.Logs 'media_debug.log'
    } catch { }
    function Write-SCMGrabDbg { param([string]$Msg) if ($dbgLog) { try { ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg) | Out-File -FilePath $dbgLog -Append -Encoding UTF8 } catch { } } }
    Write-SCMGrabDbg ("===== START types=[{0}] juegos={1} soloFalta={2} orden=[{3}] =====" -f ($Types -join ','), @($Games).Count, $OnlyMissing, ($Order -join '>'))

    $sgdbKey = ''
    try {
        $cfg = Get-SCMConfig
        if ($cfg.Preferences.PSObject.Properties.Name -contains 'ApiKeys' -and $cfg.Preferences.ApiKeys.PSObject.Properties.Name -contains 'SteamGridDB') { $sgdbKey = [string]$cfg.Preferences.ApiKeys.SteamGridDB }
    } catch { }
    $tgdbKey = Get-SCMTgdbKey
    Write-SCMGrabDbg ("keys: sgdb={0} tgdb={1} moby={2} ss={3} igdb={4}" -f [bool]$sgdbKey, [bool]$tgdbKey, [bool](Get-SCMMobyKey), ($null -ne (Get-SCMScreenScraperCreds)), ($null -ne (Get-SCMIgdbCreds)))

    try { $index = Get-SCMMediaIndex -RomFolder $RomFolder }
    catch { Write-SCMGrabDbg ("ERROR Get-SCMMediaIndex: {0}" -f $_.Exception.Message); throw }
    $ctx = @{}
    $downloaded = 0; $failed = 0; $tasks = @(); $srcCounts = @{}; $failedTasks = @()

    # Construir la lista de (juego,tipo) que hay que intentar.
    if ($RetryTasks) {
        $tasks = @($RetryTasks)
    }
    else {
        foreach ($g in $Games) {
            # Un juego con FullPath nulo/raro NO debe abortar el lote entero.
            try {
                $fp = [string]$g.FullPath
                if ([string]::IsNullOrWhiteSpace($fp)) { Write-SCMGrabDbg ("  SKIP juego sin FullPath: '{0}'" -f $g.DisplayTitle); continue }
                $folder = Split-Path $fp -Leaf
                $st = Get-SCMMediaStatus -Index $index -FolderName $folder
                foreach ($t in $Types) {
                    $has = switch ($t) {
                        'image' { $st.Image } 'fanart' { $st.Fanart } 'marquee' { $st.Marquee }
                        'snap' { $st.Snap } 'video' { $st.Video } 'manual' { $st.Manual } default { $false }
                    }
                    if ($OnlyMissing -and $has) { continue }
                    $tasks += [PSCustomObject]@{ Game = $g; Folder = $folder; Type = $t }
                }
            } catch {
                Write-SCMGrabDbg ("  ERROR construyendo tareas para '{0}': {1}" -f $g.DisplayTitle, $_.Exception.Message)
            }
        }
    }

    if ($Sync) { $Sync.Total = $tasks.Count; $Sync.Done = 0 }
    Write-SCMGrabDbg ("tareas a intentar: {0}" -f $tasks.Count)

    foreach ($task in $tasks) {
        if ($Sync) { $Sync.Current = ("{0} - {1}" -f $task.Game.DisplayTitle, $task.Type) }
        try {
            $res = Resolve-SCMMediaUrl -Type $task.Type -Term $task.Game.Title -Order $Order -SgdbKey $sgdbKey -TgdbKey $tgdbKey -Ctx $ctx
            Write-SCMGrabDbg ("[{0}] {1}: {2}" -f $task.Type, $task.Game.Title, $(if ($res) { "$($res.Source) -> $($res.Url)" } else { 'SIN FUENTE' }))
            if ($res) {
                $canon = $script:MediaRootByType[$task.Type]
                # Reutiliza la carpeta existente (respeta 'video' singular, etc.);
                # si no hay ninguna, crea la canonica en plural.
                $dir = $null
                if (Get-Command Resolve-SCMMediaFolder -ErrorAction SilentlyContinue) { $dir = Resolve-SCMMediaFolder -RomFolder $RomFolder -Canonical $canon }
                if (-not $dir) { $dir = Join-Path $RomFolder $canon }
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $dirLeaf = Split-Path $dir -Leaf
                $ext = if ($res.Ext) { $res.Ext } else { '.png' }
                $dest = Join-Path $dir ("{0}{1}{2}" -f $task.Folder, $script:SuffixByType[$task.Type], $ext)
                $saved = Save-SCMArtwork -Url $res.Url -Dest $dest
                Write-SCMGrabDbg ("    guardado={0} -> {1}\{2}" -f $saved, $dirLeaf, (Split-Path $dest -Leaf))
                if ($saved) {
                    $downloaded++
                    if ($srcCounts.ContainsKey($res.Source)) { $srcCounts[$res.Source]++ } else { $srcCounts[$res.Source] = 1 }
                    # Actualizar el gamelist.xml (solo el campo de este tipo) si
                    # las funciones estan cargadas y el tipo tiene campo.
                    if ($script:GamelistFieldByType.ContainsKey($task.Type) -and
                        (Get-Command Update-SCMGamelistMediaField -ErrorAction SilentlyContinue)) {
                        $rel = "./{0}/{1}" -f $dirLeaf, (Split-Path $dest -Leaf)
                        Update-SCMGamelistMediaField -RomFolder $RomFolder -FolderName $task.Folder -Field $script:GamelistFieldByType[$task.Type] -RelPath $rel
                    }
                    # (Miniatura -thumb DESACTIVADA: RetroBat muestra el thumbnail
                    #  encima de la imagen/video y queda mal. La portada -image basta.)
                }
                else { $failed++; $failedTasks += $task }
            } else { $failed++; $failedTasks += $task }
        } catch { $failed++; $failedTasks += $task }
        if ($Sync) { $Sync.Done++ }
    }

    $srcSummary = (($srcCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "{0} x{1}" -f $_.Key, $_.Value }) -join ', ')
    Write-SCMGrabDbg ("===== END descargadas={0} fallos={1} total={2} fuentes=[{3}] =====" -f $downloaded, $failed, $tasks.Count, $srcSummary)
    return [PSCustomObject]@{ Downloaded = $downloaded; Failed = $failed; Total = $tasks.Count; Sources = $srcSummary; FailedTasks = @($failedTasks) }
}

Export-ModuleMember -Function *

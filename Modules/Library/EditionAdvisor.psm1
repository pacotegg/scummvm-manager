Set-StrictMode -Version Latest

# =====================================================================
#  EditionAdvisor.psm1 - detecta la edicion de cada juego (floppy / CD /
#  talkie / VGA / EGA / idioma) a partir de lo que reporta ScummVM, y
#  senala los que parecen una edicion "menor" por si existe una mejor.
#  NO descarga nada ni localiza copias; solo da enlaces a fuentes
#  legitimas (ficha de ScummVM y busqueda en GOG) para que el usuario
#  compruebe/consiga por su cuenta.
# =====================================================================

# Analiza el texto de edicion de un juego. Devuelve etiqueta + si es
# candidato a mejora (parece floppy/EGA sin CD ni voces).
function Get-SCMEditionInfo {
    param([Parameter(Mandatory)]$Game)

    $desc = ""
    if ($Game.PSObject.Properties.Name -contains "Description") { $desc = [string]$Game.Description }
    $edi = ""
    if ($Game.PSObject.Properties.Name -contains "Edition") { $edi = [string]$Game.Edition }
    $text = ("{0} {1}" -f $desc, $edi).ToLowerInvariant()

    $hasTalkie = ($text -match "talkie") -or ($text -match "voice")
    $hasCD     = ($text -match "cd")
    $hasFloppy = ($text -match "floppy") -or ($text -match "diskette") -or ($text -match "disk")
    $hasEGA    = ($text -match "ega")
    $hasVGA    = ($text -match "vga")

    $tags = @()
    if ($hasTalkie) { $tags += "Talkie" }
    if ($hasCD)     { $tags += "CD" }
    if ($hasFloppy) { $tags += "Floppy" }
    if ($hasEGA)    { $tags += "EGA" }
    if ($hasVGA)    { $tags += "VGA" }

    $label = if ($tags.Count -gt 0) { $tags -join "/" } else { "?" }

    # Candidato a mejora: parece floppy/EGA y NO hay senal de CD ni voces.
    $isCandidate = (($hasFloppy) -or ($hasEGA)) -and -not ($hasCD -or $hasTalkie)

    return [PSCustomObject]@{ Label = $label; IsUpgradeCandidate = $isCandidate }
}

function Get-SCMGogSearchUrl {
    param([string]$Title)
    $q = [uri]::EscapeDataString($Title)
    return "https://www.gog.com/en/games?query=$q"
}

# Carga la tabla curada ShortID -> nota de mejor edicion (o vacio).
function Get-SCMEditionUpgrades {
    try {
        $config = Get-SCMConfig
        $file = Join-Path $config.Paths.Definitions "EditionUpgrades.json"
        if (-not (Test-Path $file)) { return @{} }
        $data = Get-Content $file -Raw | ConvertFrom-Json
        $map = @{}
        $list = if ($data.PSObject.Properties.Name -contains "games") { $data.games } else { $data }
        foreach ($e in $list) { $map[[string]$e.ShortID] = [string]$e.Note }
        return $map
    }
    catch { return @{} }
}

function Show-SCMEditionAdvisor {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Games
    )

    $Games = @($Games)
    if ($Games.Count -eq 0) {
        Write-Host ""
        Write-Host "  Database is empty. Run 'Scan Collection' first." -ForegroundColor $global:SCMTheme.Warn
        return
    }

    $upgrades = Get-SCMEditionUpgrades

    $rows = foreach ($g in $Games) {
        $info = Get-SCMEditionInfo -Game $g
        $sid = [string]$g.ShortID
        # Nota curada: solo si la edicion actual NO es ya CD/Talkie.
        $curatedNote = ""
        $alreadyGood = ($info.Label -match "Talkie") -or ($info.Label -match "CD")
        if ($upgrades.ContainsKey($sid) -and -not $alreadyGood) { $curatedNote = $upgrades[$sid] }

        [PSCustomObject]@{
            Title     = $g.DisplayTitle
            ShortID   = $sid
            Edition   = $info.Label
            Candidate = ($info.IsUpgradeCandidate -or ($curatedNote -ne ""))
            Note      = $curatedNote
        }
    }
    $rows = @($rows)

    # Los que tienen nota curada primero (mas fiables), luego el resto.
    $candidates = @($rows | Where-Object { $_.Candidate } | Sort-Object @{Expression={[string]::IsNullOrEmpty($_.Note)}}, Title)

    Write-Host ""
    Show-SCMPanel -Title "Edition Advisor" -Lines @(
        ("Games analizados : {0}" -f $rows.Count),
        ("Ediciones 'menores' detectadas : {0}" -f $candidates.Count),
        "",
        "Se marca como candidato lo que parece Floppy/EGA sin senal",
        "de CD ni voces (Talkie). Es orientativo: comprueba la ficha",
        "oficial de ScummVM y GOG antes de sustituir nada."
    )

    if ($candidates.Count -eq 0) {
        Write-Host ""
        Write-Host "  No se han detectado ediciones claramente mejorables." -ForegroundColor $global:SCMTheme.Ok
        return
    }

    Write-Host ""
    Write-Host "  Posibles mejoras (Floppy/EGA -> busca CD/Talkie):" -ForegroundColor $global:SCMTheme.Title
    Write-Host ""
    foreach ($c in $candidates) {
        Write-Host ("  - {0}  [{1}]" -f $c.Title, $c.Edition) -ForegroundColor $global:SCMTheme.Selected
        if (-not [string]::IsNullOrEmpty($c.Note)) {
            Write-Host ("      {0}" -f $c.Note) -ForegroundColor $global:SCMTheme.Ok
        }
        Write-Host ("      GOG: {0}" -f (Get-SCMGogSearchUrl -Title $c.Title)) -ForegroundColor $global:SCMTheme.Dim
    }

    Write-Host ""
    Write-Host "  Catalogo/compatibilidad ScummVM: https://www.scummvm.org/compatibility" -ForegroundColor $global:SCMTheme.Dim
    Write-Host "  Juegos gratuitos oficiales:      https://www.scummvm.org/games/" -ForegroundColor $global:SCMTheme.Dim
}

Export-ModuleMember -Function Get-SCMEditionInfo, Get-SCMGogSearchUrl, Show-SCMEditionAdvisor

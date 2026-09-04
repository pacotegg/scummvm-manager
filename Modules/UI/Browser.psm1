Set-StrictMode -Version Latest

# =====================================================================
#  Browser.psm1 - navegacion de la coleccion. Browse por Titulo / Serie /
#  Engine / Idioma / Plataforma, con buscador (en el selector), badge de
#  engine y color por estado de media (verde=completa, amarillo=parcial,
#  gris=sin media).
# =====================================================================

# Construye textos e (colores) para una lista de juegos.
function Get-SCMBrowseItems {
    param([array]$Games, [hashtable]$MediaIndex)

    $texts  = @()
    $colors = @()
    foreach ($g in $Games) {
        $folder = Split-Path $g.FullPath -Leaf
        $st = Get-SCMMediaStatus -Index $MediaIndex -FolderName $folder

        $color = "DarkGray"
        if ($st.HasCore)      { $color = "Green" }
        elseif ($st.AnyMedia) { $color = "DarkYellow" }

        $badge = if ($g.Engine) { "[{0}]" -f $g.Engine } else { "[?]" }
        $texts  += ("{0,-12} {1}" -f $badge, $g.DisplayTitle)
        $colors += $color
    }
    return @{ Texts = @($texts); Colors = @($colors) }
}

function Show-SCMBrowseMenu {
    param(
        [Parameter(Mandatory)]
        [array]$Games
    )

    $config = Get-SCMConfig
    $mediaIndex = Get-SCMMediaIndex -RomFolder $config.Paths.RomFolder

    while ($true) {

        $choice = Show-SCMMenu -Title "Browse Collection" -Header @(
            ("{0} juegos   Verde=media completa  Amarillo=parcial  Gris=sin media" -f @($Games).Count)
        ) -Options @(
            "Browse by Title",
            "Browse by Series",
            "Browse by Engine",
            "Browse by Language",
            "Browse by Platform"
        )

        switch ($choice) {
            0 { Show-SCMBrowseByTitle -Games $Games -MediaIndex $mediaIndex }
            1 { Show-SCMBrowseByGroup -Games $Games -Field "SeriesName" -Title "Series" -MediaIndex $mediaIndex }
            2 { Show-SCMBrowseByGroup -Games $Games -Field "Engine"     -Title "Engine" -MediaIndex $mediaIndex }
            3 { Show-SCMBrowseByGroup -Games $Games -Field "Language"   -Title "Language" -MediaIndex $mediaIndex }
            4 { Show-SCMBrowseByGroup -Games $Games -Field "Platform"   -Title "Platform" -MediaIndex $mediaIndex }
            default { return }
        }
    }
}

function Show-SCMBrowseByTitle {
    param([array]$Games, [hashtable]$MediaIndex)

    $sorted = @($Games | Sort-Object DisplayTitle)
    while ($true) {
        $items = Get-SCMBrowseItems -Games $sorted -MediaIndex $MediaIndex
        $sel = Show-SCMSelector -Title "Browse by Title" -Items $items.Texts -ItemColors $items.Colors
        if ($sel -lt 0) { return }
        Show-SCMGameDetails -Game $sorted[$sel] -MediaIndex $MediaIndex
    }
}

# Agrupa por un campo, elige grupo, luego lista los juegos del grupo.
function Show-SCMBrowseByGroup {
    param([array]$Games, [string]$Field, [string]$Title, [hashtable]$MediaIndex)

    $groups = @(
        $Games |
        Group-Object -Property $Field |
        Sort-Object Name
    )
    # Etiqueta legible por grupo (valor vacio -> "(none)").
    $labels = @()
    foreach ($grp in $groups) {
        $name = if ([string]::IsNullOrWhiteSpace($grp.Name)) { "(none)" } else { $grp.Name }
        $labels += ("{0}  ({1})" -f $name, $grp.Count)
    }

    while ($true) {
        $gsel = Show-SCMSelector -Title ("Browse by " + $Title) -Items $labels
        if ($gsel -lt 0) { return }

        $inGroup = @($groups[$gsel].Group | Sort-Object DisplayTitle)
        while ($true) {
            $items = Get-SCMBrowseItems -Games $inGroup -MediaIndex $MediaIndex
            $label = if ([string]::IsNullOrWhiteSpace($groups[$gsel].Name)) { "(none)" } else { $groups[$gsel].Name }
            $sel = Show-SCMSelector -Title ("{0}: {1}" -f $Title, $label) -Items $items.Texts -ItemColors $items.Colors
            if ($sel -lt 0) { break }
            Show-SCMGameDetails -Game $inGroup[$sel] -MediaIndex $MediaIndex
        }
    }
}

function Show-SCMGameDetails {
    param(
        [Parameter(Mandatory)] $Game,
        [hashtable]$MediaIndex
    )

    $folder = Split-Path $Game.FullPath -Leaf
    $st = if ($MediaIndex) { Get-SCMMediaStatus -Index $MediaIndex -FolderName $folder } else { $null }

    while ($true) {

        Clear-Host

        $mediaLine = if ($st) {
            $have = @()
            if ($st.Image)  { $have += "image" }
            if ($st.Video)  { $have += "video" }
            if ($st.Manual) { $have += "manual" }
            if ($st.Marquee){ $have += "marquee" }
            if ($st.Snap)   { $have += "snap" }
            if ($have.Count -eq 0) { "(ninguna)" } else { $have -join ", " }
        } else { "?" }

        Show-SCMPanel -Title $Game.DisplayTitle -Lines @(
            ("Series     : {0}" -f $Game.SeriesName),
            ("Engine     : {0}" -f $Game.Engine),
            ("Edition    : {0}" -f $Game.Edition),
            ("Platform   : {0}" -f $Game.Platform),
            ("Language   : {0}" -f $Game.Language),
            ("Short ID   : {0}" -f $Game.ShortID),
            ("Game ID    : {0}" -f $Game.GameID),
            ("Media      : {0}" -f $mediaLine),
            "",
            "Folder:",
            $Game.FullPath
        )

        $choice = Show-SCMMenu -Title "Game" -Options @("Open Folder")

        switch ($choice) {
            0 {
                if (Test-Path $Game.FullPath) {
                    Start-Process explorer.exe $Game.FullPath
                }
                else {
                    Write-Host ""
                    Write-Host "Folder not found: $($Game.FullPath)" -ForegroundColor $global:SCMTheme.Error
                    Pause-SCM
                }
            }
            default { return }
        }
    }
}

Export-ModuleMember -Function Show-SCMBrowseMenu, Get-SCMBrowseItems

Set-StrictMode -Version Latest

# =====================================================================
#  CollectionStats.psm1 - resumen agregado de la coleccion escaneada.
#  Se llama al final de Invoke-SCMScan y muestra recuentos por motor,
#  plataforma, idioma y series, con el panel visual de Theme.psm1.
# =====================================================================

# Agrupa los juegos por una propiedad y devuelve {Label; Count} ordenado
# de mayor a menor. Los valores vacios se etiquetan como "(unknown)".
function Get-SCMBreakdown {
    param(
        [array]$Games,
        [string]$Property
    )

    $Games |
        Group-Object -Property $Property |
        Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name" } |
        ForEach-Object {
            $label = if ([string]::IsNullOrWhiteSpace($_.Name)) { "(unknown)" } else { $_.Name }
            [PSCustomObject]@{ Label = $label; Count = $_.Count }
        }
}

# Convierte un breakdown en lineas "  NN  ##########  Etiqueta" (barra ASCII).
function Format-SCMBreakdownLines {
    param(
        [array]$Rows,
        [int]$Top = 12,
        [int]$BarWidth = 18
    )

    $lines = @()
    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return @("  (sin datos)")
    }

    $max = ($Rows | Measure-Object -Property Count -Maximum).Maximum
    if ($max -le 0) { $max = 1 }

    $shown = @($Rows | Select-Object -First $Top)
    foreach ($r in $shown) {
        $barLen = [int][Math]::Round(($r.Count / $max) * $BarWidth)
        if ($r.Count -gt 0 -and $barLen -lt 1) { $barLen = 1 }
        $bar = ("#" * $barLen).PadRight($BarWidth)
        $lines += ("  {0,4}  {1}  {2}" -f $r.Count, $bar, $r.Label)
    }

    $rest = @($Rows).Count - $shown.Count
    if ($rest -gt 0) {
        $lines += ("  ... (+{0} mas)" -f $rest)
    }
    return $lines
}

function Show-SCMCollectionStats {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Games
    )

    $Games = @($Games)
    $total = $Games.Count

    if ($total -eq 0) {
        Write-Host ""
        Write-Host "  No games in collection." -ForegroundColor $global:SCMTheme.Warn
        return
    }

    $engines   = @($Games | Group-Object Engine   | Where-Object { $_.Name })
    $platforms = @($Games | Group-Object Platform  | Where-Object { $_.Name })
    $languages = @($Games | Group-Object Language  | Where-Object { $_.Name })
    $inSeries  = @($Games | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SeriesName) })
    $series    = @($inSeries | Group-Object SeriesName)

    # Cobertura de media (image/video/manual) usando el indice de la raiz.
    $imgN = 0; $vidN = 0; $manN = 0
    try {
        $cfg = Get-SCMConfig
        if (Test-Path $cfg.Paths.RomFolder) {
            $mi = Get-SCMMediaIndex -RomFolder $cfg.Paths.RomFolder
            foreach ($g in $Games) {
                $st = Get-SCMMediaStatus -Index $mi -FolderName (Split-Path $g.FullPath -Leaf)
                if ($st.Image)  { $imgN++ }
                if ($st.Video)  { $vidN++ }
                if ($st.Manual) { $manN++ }
            }
        }
    }
    catch { }
    $pct = { param($n) if ($total -gt 0) { [int](($n / $total) * 100) } else { 0 } }

    Write-Host ""
    Show-SCMPanel -Title "Collection Summary" -Lines @(
        ("Games      : {0}" -f $total),
        ("Engines    : {0}" -f $engines.Count),
        ("Platforms  : {0}" -f $platforms.Count),
        ("Languages  : {0}" -f $languages.Count),
        ("Series     : {0} ({1} games in a series)" -f $series.Count, $inSeries.Count),
        "",
        ("Media image : {0}/{1} ({2}%)" -f $imgN, $total, (& $pct $imgN)),
        ("Media video : {0}/{1} ({2}%)" -f $vidN, $total, (& $pct $vidN)),
        ("Media manual: {0}/{1} ({2}%)" -f $manN, $total, (& $pct $manN))
    )

    Write-Host ""
    Show-SCMPanel -Title "By Engine" -Lines (Format-SCMBreakdownLines -Rows (Get-SCMBreakdown -Games $Games -Property "Engine"))

    Write-Host ""
    Show-SCMPanel -Title "By Platform" -Lines (Format-SCMBreakdownLines -Rows (Get-SCMBreakdown -Games $Games -Property "Platform"))

    Write-Host ""
    Show-SCMPanel -Title "By Language" -Lines (Format-SCMBreakdownLines -Rows (Get-SCMBreakdown -Games $Games -Property "Language"))

    if ($series.Count -gt 0) {
        $seriesRows = $series |
            Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name" } |
            ForEach-Object { [PSCustomObject]@{ Label = $_.Name; Count = $_.Count } }
        Write-Host ""
        Show-SCMPanel -Title "Top Series" -Lines (Format-SCMBreakdownLines -Rows $seriesRows)
    }
}

Export-ModuleMember -Function Show-SCMCollectionStats

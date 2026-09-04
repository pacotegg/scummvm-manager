Set-StrictMode -Version Latest

# Selector navegable con flechas + BUSCADOR incremental (escribe para filtrar).
# La opcion seleccionada se resalta con barra de color de fondo (sin glifos
# Unicode raros). Opcionalmente cada item puede tener su propio color (para
# colorear el Browse por estado). Devuelve el indice (0-based) del item en el
# array ORIGINAL, o -1 si el usuario pulsa Esc.
function Show-SCMSelector {

    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [array]$Items,

        [string[]]$Header = @(),

        # Colores (ConsoleColor) paralelos a $Items para las filas no resaltadas.
        [string[]]$ItemColors = @(),

        # Permitir escribir para filtrar.
        [bool]$AllowFilter = $true
    )

    if ($Items.Count -eq 0) {
        return -1
    }

    $barWidth = 60
    foreach ($it in $Items) {
        $len = ([string]$it).Length + 4
        if ($len -gt $barWidth) { $barWidth = $len }
    }
    if ($barWidth -gt 74) { $barWidth = 74 }

    $filter = ""
    $sel = 0     # indice dentro de la lista filtrada

    while ($true) {

        # Construir lista visible (indices originales que cumplen el filtro).
        $visible = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ([string]::IsNullOrEmpty($filter) -or
                ([string]$Items[$i]).ToLowerInvariant().Contains($filter.ToLowerInvariant())) {
                $visible += $i
            }
        }
        if ($visible.Count -eq 0) { $sel = 0 }
        elseif ($sel -ge $visible.Count) { $sel = $visible.Count - 1 }
        elseif ($sel -lt 0) { $sel = 0 }

        Clear-Host
        Show-SCMHeader

        if ($Header.Count -gt 0) {
            foreach ($h in $Header) { Write-Host ("   " + $h) -ForegroundColor $global:SCMTheme.Dim }
            Write-Host ""
        }

        Write-Host ("  " + $Title) -ForegroundColor $global:SCMTheme.Title
        Write-Host ("  " + ([string]$global:SCMChars.H * [Math]::Min($barWidth, $Title.Length + 6))) -ForegroundColor $global:SCMTheme.Accent
        Write-Host ""

        if ($visible.Count -eq 0) {
            Write-Host "   (sin coincidencias)" -ForegroundColor $global:SCMTheme.Warn
        }
        else {
            $window = 14
            $top = 0
            if ($visible.Count -gt $window) {
                $top = [Math]::Max(0, $sel - [int]($window / 2))
                $top = [Math]::Min($top, $visible.Count - $window)
            }
            $bottom = [Math]::Min($visible.Count - 1, $top + $window - 1)

            for ($v = $top; $v -le $bottom; $v++) {
                $orig = $visible[$v]
                $text = [string]$Items[$orig]

                if ($v -eq $sel) {
                    $line = (" " + [string]$global:SCMChars.Sel + " " + $text).PadRight($barWidth)
                    Write-Host $line -ForegroundColor $global:SCMTheme.Selected -BackgroundColor $global:SCMTheme.SelectedBg
                }
                else {
                    $color = $global:SCMTheme.Menu
                    if ($ItemColors.Count -gt $orig -and $ItemColors[$orig]) { $color = $ItemColors[$orig] }
                    Write-Host ("   " + $text) -ForegroundColor $color
                }
            }

            if ($visible.Count -gt $window) {
                Write-Host ""
                Write-Host ("   ({0}-{1} de {2})" -f ($top + 1), ($bottom + 1), $visible.Count) -ForegroundColor $global:SCMTheme.Dim
            }
        }

        Write-Host ""
        if ($AllowFilter -and -not [string]::IsNullOrEmpty($filter)) {
            Write-Host ("   Filtro: {0}_" -f $filter) -ForegroundColor $global:SCMTheme.Title
        }
        $hint = if ($AllowFilter) { "   [Up/Down] mover  [Enter] seleccionar  [Esc] volver  [escribe]=filtrar  [Backspace]=borrar" }
                else { "   [Up/Down] mover  [Enter] seleccionar  [Esc] volver" }
        Write-Host $hint -ForegroundColor $global:SCMTheme.Dim

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            "UpArrow"    { if ($visible.Count -gt 0) { if ($sel -gt 0) { $sel-- } else { $sel = $visible.Count - 1 } } }
            "DownArrow"  { if ($visible.Count -gt 0) { if ($sel -lt ($visible.Count - 1)) { $sel++ } else { $sel = 0 } } }
            "Home"       { $sel = 0 }
            "End"        { if ($visible.Count -gt 0) { $sel = $visible.Count - 1 } }
            "Enter"      { if ($visible.Count -gt 0) { return $visible[$sel] } }
            "Escape"     { return -1 }
            "Backspace"  { if ($AllowFilter -and $filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0 } }
            default {
                if ($AllowFilter) {
                    $ch = $key.KeyChar
                    if ($ch -and [char]::IsLetterOrDigit($ch) -or $ch -eq ' ' -or [char]::IsPunctuation($ch)) {
                        if (-not [char]::IsControl($ch)) { $filter += $ch; $sel = 0 }
                    }
                }
            }
        }
    }
}

Export-ModuleMember -Function Show-SCMSelector

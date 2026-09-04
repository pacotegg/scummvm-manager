Set-StrictMode -Version Latest

# =====================================================================
#  Theme.psm1 - aspecto visual, encoding de consola y navegacion.
#
#  Los caracteres de caja/flechas se construyen en runtime desde sus
#  code points Unicode ([char]0x....), NUNCA como literales guardados en
#  el fichero .ps1. Asi el codigo fuente es ASCII puro y no vuelve a
#  ocurrir el problema de mojibake, se guarde el fichero como se guarde.
# =====================================================================

# Paleta de colores (nombres de ConsoleColor de PowerShell).
$global:SCMTheme = @{
    Title      = "Cyan"
    Accent     = "DarkCyan"
    Menu       = "Gray"
    Selected   = "Black"    # texto de la opcion resaltada
    SelectedBg = "Cyan"     # fondo de la barra resaltada
    Ok         = "Green"
    Warn       = "Yellow"
    Error      = "Red"
    Dim        = "DarkGray"
    Header     = "White"
}

# Presets de acento: cada uno define color de titulo, borde y barra resaltada.
$global:SCMAccents = @{
    "Cyan"    = @{ Title = "Cyan";    Accent = "DarkCyan";    SelectedBg = "Cyan" }
    "Green"   = @{ Title = "Green";   Accent = "DarkGreen";   SelectedBg = "Green" }
    "Magenta" = @{ Title = "Magenta"; Accent = "DarkMagenta"; SelectedBg = "Magenta" }
    "Yellow"  = @{ Title = "Yellow";  Accent = "DarkYellow";  SelectedBg = "Yellow" }
    "Blue"    = @{ Title = "Blue";    Accent = "DarkBlue";    SelectedBg = "Blue" }
}

# Aplica un preset de acento a la paleta ($global:SCMTheme).
function Set-SCMAccent {
    param([string]$Name = "Cyan")
    if (-not $global:SCMAccents.ContainsKey($Name)) { $Name = "Cyan" }
    $a = $global:SCMAccents[$Name]
    $global:SCMTheme.Title      = $a.Title
    $global:SCMTheme.Accent     = $a.Accent
    $global:SCMTheme.SelectedBg = $a.SelectedBg
}

function Initialize-SCMConsole {
    param(
        [bool]$Unicode = $true,
        [string]$Accent = "Cyan"
    )

    Set-SCMAccent -Name $Accent

    # UTF-8 en la consola para que se rendericen bien acentos y bordes.
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $global:OutputEncoding    = [System.Text.Encoding]::UTF8
    }
    catch {
        # Algunas consolas no permiten cambiar el encoding; seguimos.
    }

    if ($Unicode) {
        $global:SCMChars = @{
            TL   = [char]0x2554   # esquina superior izquierda
            TR   = [char]0x2557   # esquina superior derecha
            BL   = [char]0x255A   # esquina inferior izquierda
            BR   = [char]0x255D   # esquina inferior derecha
            ML   = [char]0x2560   # conector en T izquierdo (rule intermedia)
            MR   = [char]0x2563   # conector en T derecho
            H    = [char]0x2550   # horizontal
            V    = [char]0x2551   # vertical
            # Marcador y flechas en ASCII a proposito: los glifos Unicode de
            # flecha (U+2191/2193) y triangulo (U+25B6) no existen en muchas
            # fuentes/codepages de consola de Windows y se ven como "?".
            Up   = "Up"
            Down = "Down"
            Sel  = ">"
        }
    }
    else {
        $global:SCMChars = @{
            TL = '+'; TR = '+'; BL = '+'; BR = '+'
            ML = '+'; MR = '+'
            H  = '-'; V  = '|'
            Up = 'Up'; Down = 'Down'; Sel = '>'
        }
    }
}

# Valores por defecto al importar el modulo, por si Initialize-SCMConsole
# no se ha llamado todavia (evita errores con Set-StrictMode).
if (-not (Get-Variable -Name SCMChars -Scope Global -ErrorAction SilentlyContinue)) {
    Initialize-SCMConsole -Unicode $true
}

function Write-SCMBoxLine {
    param(
        [string]$Text,
        [int]$Width,
        $Color,
        [ValidateSet("Left", "Center")]
        [string]$Align = "Left"
    )

    $c = $global:SCMChars
    $inner = $Width - 4   # 2 bordes + 1 espacio de margen a cada lado

    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -gt $inner) {
        $Text = $Text.Substring(0, $inner)
    }

    $pad = $inner - $Text.Length
    if ($Align -eq "Center") {
        $left  = [int]($pad / 2)
        $right = $pad - $left
    }
    else {
        $left  = 0
        $right = $pad
    }

    Write-Host ([string]$c.V + " ") -ForegroundColor $global:SCMTheme.Accent -NoNewline
    Write-Host ((" " * $left) + $Text + (" " * $right)) -ForegroundColor $Color -NoNewline
    Write-Host (" " + [string]$c.V) -ForegroundColor $global:SCMTheme.Accent
}

function Write-SCMRule {
    param(
        [int]$Width,
        [ValidateSet("Top", "Mid", "Bottom")]
        [string]$Kind = "Mid"
    )
    $c = $global:SCMChars
    switch ($Kind) {
        "Top"    { $l = $c.TL; $r = $c.TR }
        "Bottom" { $l = $c.BL; $r = $c.BR }
        default  { $l = $c.ML; $r = $c.MR }
    }
    Write-Host ([string]$l + ([string]$c.H * ($Width - 2)) + [string]$r) -ForegroundColor $global:SCMTheme.Accent
}

function Show-SCMHeader {
    param(
        [string]$Version
    )

    Clear-Host
    $w = 68

    Write-Host ""
    Write-SCMRule -Width $w -Kind Top
    Write-SCMBoxLine -Text "ScummVM Collection Manager" -Width $w -Color $global:SCMTheme.Title -Align Center
    if ($Version) {
        Write-SCMBoxLine -Text ("Version " + $Version) -Width $w -Color $global:SCMTheme.Dim -Align Center
    }
    Write-SCMRule -Width $w -Kind Bottom
    Write-Host ""
}

function Show-SCMPanel {
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [string[]]$Lines = @(),
        [int]$Width = 68
    )

    Write-SCMRule -Width $Width -Kind Top
    Write-SCMBoxLine -Text $Title -Width $Width -Color $global:SCMTheme.Title -Align Center
    Write-SCMRule -Width $Width -Kind Mid
    foreach ($line in $Lines) {
        Write-SCMBoxLine -Text $line -Width $Width -Color $global:SCMTheme.Menu -Align Left
    }
    Write-SCMRule -Width $Width -Kind Bottom
}

# Menu navegable con flechas. Devuelve el indice elegido (0-based) o -1 (Esc).
function Show-SCMMenu {
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string[]]$Options,
        [string[]]$Header = @()
    )

    return Show-SCMSelector -Title $Title -Items $Options -Header $Header
}

Export-ModuleMember -Function Initialize-SCMConsole, Set-SCMAccent, Write-SCMBoxLine, Write-SCMRule, Show-SCMHeader, Show-SCMPanel, Show-SCMMenu

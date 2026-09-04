Set-StrictMode -Version Latest

function Get-SCMDetectionLines {

    param(
        [string[]]$ScummVMOutput
    )

    $Lines = @()
    $Buffer = ""

    foreach ($Line in $ScummVMOutput) {

        if ([string]::IsNullOrWhiteSpace($Line)) {
            continue
        }

        if ($Line -match 'GameID|Description|Full Path|Scanning|Detected') {
            continue
        }

        if ($Line -match '^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\s') {

            if ($Buffer) {
                $Lines += $Buffer.Trim()
            }

            $Buffer = $Line.Trim()
        }
        else {

            if ($Buffer) {
                $Buffer += " " + $Line.Trim()
            }
        }
    }

    if ($Buffer) {
        $Lines += $Buffer.Trim()
    }

    return $Lines
}

function Convert-SCMDetectionLine {

    param(
        [string]$Line
    )

    $PathMatch = [regex]::Match(
        $Line,
        '(?<Path>[A-Za-z]:\\.+)$'
    )

    if (-not $PathMatch.Success) {
        return $null
    }

    $FullPath = $PathMatch.Groups["Path"].Value.Trim()

    $Left = $Line.Substring(0, $PathMatch.Index).TrimEnd()

    $FirstSpace = $Left.IndexOf(' ')

    if ($FirstSpace -lt 0) {
        return $null
    }

    $GameID = $Left.Substring(0, $FirstSpace)

    $Description = $Left.Substring($FirstSpace).Trim()

    # Descartar detecciones FANTASMA de ScummVM: empareja ficheros sueltos (.dat,
    # etc.) con un engine y los marca como "Unknown ... game or version" (tipico
    # glk:level9v3 en subcarpetas). No son juegos reales de la coleccion, solo
    # ensucian la galeria y la BD. Un juego identificado nunca empieza por "Unknown".
    if ($Description -match '^\s*Unknown\b') { return $null }

    $Parts = $GameID.Split(':', 2)

    if ($Parts.Count -eq 2) {
        $Engine = $Parts[0]
        $ShortID = $Parts[1]
    }
    else {
        $Engine = ""
        $ShortID = $GameID
    }

    [PSCustomObject]@{
        GameID      = $GameID
        Engine      = $Engine
        ShortID     = $ShortID
        Description = $Description
        FullPath    = $FullPath
    }
}

Export-ModuleMember -Function *

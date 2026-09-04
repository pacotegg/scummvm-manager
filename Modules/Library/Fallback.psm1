Set-StrictMode -Version Latest

# =====================================================================
#  Fallback.psm1 - deteccion de respaldo por NOMBRE de carpeta cuando
#  'scummvm.exe --detect' no reconoce un juego. Empareja el nombre de la
#  carpeta contra Definitions\KnownGames.json (tabla verificada). Nunca
#  inventa un ID: si no hay match, la carpeta se reporta como no
#  identificada para que el usuario anada el ID a mano.
# =====================================================================

# Normaliza un nombre a clave de comparacion: minusculas, sin contenido
# entre parentesis (info de edicion) y solo caracteres a-z0-9.
function ConvertTo-SCMMatchKey {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $s = $Name.ToLowerInvariant()
    $s = $s -replace "\([^)]*\)", ""          # quitar "(CD DOS)", etc.
    $s = $s -replace "[^a-z0-9]", ""           # solo alfanumerico
    return $s
}

function Get-SCMKnownGames {
    $config = Get-SCMConfig
    $file = Join-Path $config.Paths.Definitions "KnownGames.json"
    if (-not (Test-Path $file)) { return @() }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    if ($data.PSObject.Properties.Name -contains "games") {
        return @($data.games)
    }
    return @($data)
}

# Devuelve la entrada KnownGames que corresponde al nombre de carpeta, o $null.
function Find-SCMKnownGame {
    param(
        [Parameter(Mandatory)][string]$FolderName,
        $KnownGames = $null
    )
    if ($null -eq $KnownGames) { $KnownGames = Get-SCMKnownGames }
    $key = ConvertTo-SCMMatchKey $FolderName
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }
    foreach ($g in $KnownGames) {
        if ($g.Match -eq $key) { return $g }
    }
    return $null
}

# Primer segmento de carpeta bajo RomFolder para un FullPath dado.
function Get-SCMFirstSegment {
    param([string]$RomFolder, [string]$FullPath)
    $root = (Resolve-Path $RomFolder).Path.TrimEnd('\')
    $full = ([string]$FullPath).TrimEnd('\')
    # Exigir separador tras la raiz ("...\scummvm2" no esta dentro de "...\scummvm").
    $rootL = $root.ToLowerInvariant(); $fullL = $full.ToLowerInvariant()
    if (-not ($fullL -eq $rootL -or $fullL.StartsWith($rootL + '\'))) { return $null }
    $rel = $full.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }
    return $rel.Split('\')[0]
}

# Aumenta la lista de juegos con los que --detect no encontro pero SI estan
# en KnownGames. Devuelve @{ Games = <lista aumentada>; Unidentified = <nombres> }.
function Expand-SCMGamesWithFallback {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$RomFolder,
        [string[]]$MediaFolders = $null
    )

    # Default dinamico: alias completos de MediaStatus si esta cargado.
    if ($null -eq $MediaFolders -or @($MediaFolders).Count -eq 0) {
        $MediaFolders = @("images", "videos", "manuals", "marquees", "snaps")
        try { if (Get-Command Get-SCMMediaFolderNames -ErrorAction SilentlyContinue) { $MediaFolders = @(Get-SCMMediaFolderNames) } } catch { }
    }

    if (-not (Test-Path $RomFolder)) {
        return @{ Games = $Games; Unidentified = @() }
    }

    # Carpetas ya cubiertas por juegos detectados.
    $covered = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($g in $Games) {
        $seg = Get-SCMFirstSegment -RomFolder $RomFolder -FullPath $g.FullPath
        if ($seg) { [void]$covered.Add($seg.ToLowerInvariant()) }
    }

    $known = Get-SCMKnownGames
    $augmented = @($Games)
    $unidentified = @()

    Get-ChildItem -Path $RomFolder -Directory | ForEach-Object {
        $name = $_.Name
        if ($MediaFolders -contains $name) { return }
        if ($covered.Contains($name.ToLowerInvariant())) { return }

        # Carpeta no detectada por --detect: probar tabla por nombre.
        $match = Find-SCMKnownGame -FolderName $name -KnownGames $known
        if ($null -eq $match) {
            $unidentified += $name
            return
        }

        $parts = ([string]$match.Id).Split(':', 2)
        $engine  = $parts[0]
        $shortId = if ($parts.Count -eq 2) { $parts[1] } else { $parts[0] }

        $augmented += [PSCustomObject]@{
            GameID       = $match.Id
            Engine       = $engine
            ShortID      = $shortId
            SeriesId     = ""
            SeriesName   = ""
            Title        = $match.Title
            DisplayTitle = $match.Title
            Edition      = ""
            Platform     = ""
            Language     = ""
            Description  = $match.Title
            FullPath     = $_.FullName
            Source       = "fallback"
        }
    }

    return @{ Games = @($augmented); Unidentified = @($unidentified) }
}

Export-ModuleMember -Function ConvertTo-SCMMatchKey, Get-SCMKnownGames, Find-SCMKnownGame, Expand-SCMGamesWithFallback, Get-SCMFirstSegment

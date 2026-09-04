Set-StrictMode -Version Latest

function Invoke-SCMLibraryCleanup {

    param(
        [Parameter(Mandatory)]
        [array]$Games,

        # Raiz de ROMs: para agrupar por CARPETA DE PRIMER NIVEL. Si no se da,
        # se agrupa por la ruta completa de deteccion (comportamiento simple).
        [string]$RomFolder
    )

    $config = Get-SCMConfig
    $prefs = $config.Preferences

    # Carpeta de primer nivel bajo RomFolder que contiene la deteccion (la
    # deteccion puede estar en una subcarpeta mas profunda).
    $topOf = {
        param($fullPath)
        $fp = ([string]$fullPath).TrimEnd('\')
        if (-not [string]::IsNullOrWhiteSpace($RomFolder)) {
            $root = $RomFolder.TrimEnd('\')
            # Con separador: "...\scummvm2\x" NO esta dentro de "...\scummvm".
            if ($fp.ToLowerInvariant().StartsWith($root.ToLowerInvariant() + '\')) {
                $rel = $fp.Substring($root.Length).TrimStart('\')
                $seg = @($rel -split '\\')[0]
                if ($seg) { return (Join-Path $root $seg) }
            }
        }
        return $fp
    }

    # Clave de agrupacion = CARPETA DE PRIMER NIVEL + ShortID. Asi:
    #  - El mismo juego detectado en subcarpetas ruido (Beavis .../VNM, .../BBLOOGIE)
    #    -> misma carpeta + mismo ID -> 1 entrada (se elige la del nivel superior).
    #  - Un bundle con juegos de IDs distintos en subcarpetas (Blackwell Legacy/
    #    Unbound/Convergence/Deception) -> misma carpeta pero IDs distintos -> se
    #    conservan todos.
    #  - Dos carpetas distintas con el mismo juego (DOTT Remastered vs Maniac_Mansion_2,
    #    ambas 'tentacle') -> carpetas distintas -> se conservan las dos.
    $Clean = foreach ($group in ($Games | Group-Object { ((& $topOf $_.FullPath).ToLowerInvariant()) + '|' + [string]$_.ShortID })) {

        $best =
            $group.Group |
            Sort-Object {

                $score = 1000

                # Ignore unwanted entries
                if ($prefs.IgnoreUnknown -and $_.Description -match "Unknown") {
                    $score += 500
                }

                if ($prefs.IgnoreDemo -and $_.Description -match "Demo") {
                    $score += 500
                }

                # Preferred language
                for ($i = 0; $i -lt $prefs.Languages.Count; $i++) {
                    if ($_.Description -match [regex]::Escape($prefs.Languages[$i])) {
                        $score -= (200 - $i)
                        break
                    }
                }

                # Preferred platform
                for ($i = 0; $i -lt $prefs.Platforms.Count; $i++) {
                    if ($_.Description -match [regex]::Escape($prefs.Platforms[$i])) {
                        $score -= (100 - $i)
                        break
                    }
                }

                if ($prefs.PreferCD -and $_.Description -match "CD") {
                    $score -= 20
                }

                if ($prefs.PreferTalkie -and $_.Description -match "Talkie") {
                    $score -= 10
                }

                if ($prefs.PreferRestored -and $_.Description -match "Restored") {
                    $score -= 10
                }

                # Preferir la deteccion en el NIVEL MAS ALTO (ruta mas corta): asi
                # el juego queda en su carpeta y no en una subcarpeta ruido (VNM...).
                $score += (@(([string]$_.FullPath).TrimEnd('\') -split '\\').Count)

                $score
            } |
            Select-Object -First 1

        $best
    }

    return $Clean
}


Export-ModuleMember -Function Invoke-SCMLibraryCleanup

Set-StrictMode -Version Latest

# Cache de SeriesRules.json a nivel de modulo: Convert-SCMMetadata se llama en
# bucle (una vez por juego en cada scan); sin cache se releian y reparseaban
# config.json + SeriesRules.json POR JUEGO (cientos de I/O de disco por scan).
$script:SeriesRulesCache = $null

function Get-SCMSeriesRules {
    if ($null -ne $script:SeriesRulesCache) { return $script:SeriesRulesCache }
    $rules = @()
    try {
        $rulesFile = Join-Path (Get-SCMConfig).Paths.Database "SeriesRules.json"
        if (Test-Path $rulesFile) {
            $rules = @(Get-Content $rulesFile -Raw | ConvertFrom-Json)
        }
    } catch { $rules = @() }
    $script:SeriesRulesCache = $rules
    return $rules
}

function Convert-SCMMetadata {

    param(
        [Parameter(Mandatory)]
        $Game
    )

    # -------------------------
    # BASE VALUES (DO NOT TOUCH)
    # -------------------------

    $rawTitle = $Game.Description
    $title = $rawTitle

    $edition  = ""
    $platform = ""
    $language = ""

    # -------------------------
    # EXTRA METADATA PARSING
    # -------------------------

    if ($rawTitle -match '^(.*?)\s*\((.*?)\)$') {

        $title = $Matches[1].Trim()
        $parts = $Matches[2].Split('/')

        switch ($parts.Count) {
            1 { $edition  = $parts[0].Trim() }
            2 {
                $platform = $parts[0].Trim()
                $language = $parts[1].Trim()
            }
            default {
                $edition  = $parts[0].Trim()
                $platform = $parts[1].Trim()
                $language = $parts[2].Trim()
            }
        }
    }

    # -------------------------
    # SERIES RULES (READ ONLY)
    # -------------------------

    $rules = Get-SCMSeriesRules

    $seriesId   = ""
    $seriesName = ""
    $gameTitle  = $title

    foreach ($rule in $rules) {

        if ($title -match $rule.Pattern) {

            $seriesId   = $rule.SeriesId
            $seriesName = $rule.Series

            # RemovePrefix SOLO si el titulo empieza literalmente por el (si el
            # Pattern matchea pero el prefijo no coincide/queda corto, Substring
            # lanzaria ArgumentOutOfRange o trocearia el titulo por la mitad).
            if (($rule.PSObject.Properties.Name -contains "RemovePrefix") -and
                $title.StartsWith([string]$rule.RemovePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $gameTitle = $title.Substring(([string]$rule.RemovePrefix).Length)
            }
            else {
                $gameTitle = $title -replace $rule.Pattern, ""
            }

            $gameTitle = $gameTitle.Trim(" :-").Trim()
            # Si al quitar la serie no queda nada (el titulo ERA el nombre de la
            # serie), conservar el titulo original en vez de un DisplayTitle
            # colgado tipo "Indiana Jones: ".
            if ([string]::IsNullOrWhiteSpace($gameTitle)) { $gameTitle = $title; $seriesName = "" }
            break
        }
    }

    # -------------------------
    # DISPLAY TITLE (SAFE)
    # -------------------------

    $displayTitle = if ($seriesName) {
        # FIX DE RECONSTRUCCION: "$seriesName:" rompe el parseo de PowerShell
        # (interpreta "seriesName:" como referencia de unidad/ambito, ej. env:).
        # Este mismo bug ya se habia corregido antes en el chat (turno 391, con
        # ${Series}:) pero volvio a colarse sin llaves en esta version posterior
        # (turno 457). Sin este arreglo, Import-Module de este fichero falla y
        # todo el script se detiene al arrancar - por eso si lo corrijo aqui.
        "${seriesName}: $gameTitle"
    } else {
        $gameTitle
    }

    # -------------------------
    # OUTPUT OBJECT
    # -------------------------

    [PSCustomObject]@{
        GameID   = $Game.GameID
        Engine   = $Game.Engine
        ShortID  = $Game.ShortID

        SeriesId   = $seriesId
        SeriesName = $seriesName

        Title        = $gameTitle
        DisplayTitle = $displayTitle

        Edition  = $edition
        Platform = $platform
        Language = $language

        Description = $rawTitle
        FullPath    = $Game.FullPath
    }
}

Export-ModuleMember -Function Convert-SCMMetadata, Get-SCMSeriesRules

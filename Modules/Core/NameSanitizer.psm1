Set-StrictMode -Version Latest

# =====================================================================
#  NameSanitizer.psm1 - convierte titulos a nombres de carpeta/fichero
#  seguros con la convencion "Guiones_Bajos". Funciones puras (sin I/O)
#  salvo Resolve-SCMUniqueName, que recibe la lista de nombres ya usados.
# =====================================================================

# Title -> nombre de carpeta/fichero seguro (guiones bajos, ASCII).
function ConvertTo-SCMSafeFileName {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title,

        [int]$MaxLength = 100
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $s = $Title

    # 1. Quitar acentos: normalizar a FormD y descartar los diacriticos.
    $s = $s.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $s = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)

    # 2. Apostrofes (recto y tipografico) -> se eliminan sin dejar hueco.
    #    Patron en variable para evitar ambiguedad de precedencia con '+'.
    $apostrophes = "[" + "'" + [char]0x2019 + "]"
    $s = $s -replace $apostrophes, ""

    # 3. Separadores de subtitulo -> espacio:
    #    dos puntos, y guiones (normal/largo) rodeados de espacios.
    $dash = "[-" + [char]0x2013 + [char]0x2014 + "]"       # - EN-dash EM-dash
    $s = $s -replace "\s*:\s*", " "
    $s = $s -replace ("\s+" + $dash + "\s+"), " "

    # 4. Guion interno de palabra (p.ej. Butt-head) -> se conserva.
    #    Resto de caracteres no [A-Za-z0-9-] -> espacio.
    $s = $s -replace "[^A-Za-z0-9\-]", " "

    # 5. Colapsar espacios a "_", colapsar "_" y "-" repetidos, y recortar.
    $s = $s -replace "\s+", "_"
    $s = $s -replace "_+", "_"
    $s = $s -replace "\-+", "-"
    $s = $s.Trim("_", "-", " ")

    # 6. Truncar en el ultimo "_" antes del limite (sin cortar a media palabra).
    if ($s.Length -gt $MaxLength) {
        $cut = $s.Substring(0, $MaxLength)
        $lastUnderscore = $cut.LastIndexOf("_")
        if ($lastUnderscore -gt 0) {
            $cut = $cut.Substring(0, $lastUnderscore)
        }
        $s = $cut.Trim("_", "-", " ")
    }

    return $s
}

# Devuelve $true solo si el nombre ACTUAL esta "roto" segun la convencion:
# tiene espacios, parentesis, o caracteres invalidos en Windows/NTFS.
# Un nombre que ya usa guiones bajos y solo [A-Za-z0-9_-] se considera OK
# (aunque difiera del sanitizador en mayusculas o articulos curados a mano).
function Test-SCMFolderNameIsBroken {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    # Cualquier caracter fuera de este set -> roto (incluye espacio, (), acentos,
    # y los prohibidos por NTFS \ / : * ? " < > |).
    if ($Name -match "[^A-Za-z0-9_\-]") {
        return $true
    }

    return $false
}

# Resuelve colisiones de nombre anadiendo sufijo _2, _3, ... comparando
# (case-insensitive) contra una lista de nombres ya existentes/usados.
function Resolve-SCMUniqueName {
    param(
        [Parameter(Mandatory)]
        [string]$BaseName,

        [string[]]$ExistingNames = @()
    )

    $existingLower = @($ExistingNames | ForEach-Object { $_.ToLowerInvariant() })

    if ($existingLower -notcontains $BaseName.ToLowerInvariant()) {
        return $BaseName
    }

    $n = 2
    while ($true) {
        $candidate = "{0}_{1}" -f $BaseName, $n
        if ($existingLower -notcontains $candidate.ToLowerInvariant()) {
            return $candidate
        }
        $n++
    }
}

Export-ModuleMember -Function ConvertTo-SCMSafeFileName, Test-SCMFolderNameIsBroken, Resolve-SCMUniqueName

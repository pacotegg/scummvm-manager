Set-StrictMode -Version Latest

# =====================================================================
#  GamelistXml.psm1 - lectura/escritura de gamelist.xml via [xml] de .NET.
#  NUNCA se manipula el XML con regex, y se usan metodos DOM reales
#  (SelectNodes / DocumentElement / SelectSingleNode) en lugar del
#  adaptador de PowerShell con punto ($doc.gameList.game), que bajo
#  Set-StrictMode lanza si no existe el hijo y que devuelve una CADENA
#  (no el elemento) cuando el nodo esta vacio -> rompia AppendChild.
# =====================================================================

# Normaliza un <path> o nombre de carpeta a la forma "carpeta/fichero"
# comparable: sin "./" inicial, con "/" como separador, en minusculas.
function ConvertTo-SCMComparablePath {
    param([string]$Value)

    if ($null -eq $Value) { return "" }

    $v = $Value.Trim()
    $v = $v -replace "\\", "/"
    $v = $v -replace "^\./", ""
    $v = $v.TrimStart("/")
    return $v.ToLowerInvariant()
}

function Get-SCMGamelistDocument {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path $Path) {
        [xml]$doc = Get-Content -Path $Path -Raw -Encoding UTF8
        if (($null -eq $doc.DocumentElement) -or ($doc.DocumentElement.Name -ne "gameList")) {
            throw "El fichero no tiene un elemento raiz <gameList>: $Path"
        }
        return $doc
    }

    # No existe: crear documento minimo en memoria.
    [xml]$doc = New-Object System.Xml.XmlDocument
    $decl = $doc.CreateXmlDeclaration("1.0", $null, $null)
    [void]$doc.AppendChild($decl)
    $root = $doc.CreateElement("gameList")
    [void]$doc.AppendChild($root)
    return $doc
}

# Localiza el <game> cuyo <path> apunta a la carpeta indicada.
# Se compara por <path> (no por <name>, que puede haberse editado a mano
# en el scraper). Devuelve el XmlElement o $null.
function Find-SCMGamelistEntryByFolder {
    param(
        [Parameter(Mandatory)]
        [xml]$Doc,

        [Parameter(Mandatory)]
        [string]$FolderName,

        # -Loose: si no hay match exacto "carpeta/carpeta.scummvm", acepta
        # cualquier <path> cuyo PRIMER SEGMENTO sea la carpeta (p. ej. una
        # entrada "./Carpeta/otro_nombre.scummvm" creada/renombrada a mano).
        [switch]$Loose
    )

    $expected = ConvertTo-SCMComparablePath ("{0}/{0}.scummvm" -f $FolderName)

    # SelectNodes devuelve una lista vacia (no error) si no hay <game>.
    foreach ($game in $Doc.SelectNodes("/gameList/game")) {
        $pathNode = $game.SelectSingleNode("path")
        if ($null -eq $pathNode) { continue }
        if ((ConvertTo-SCMComparablePath $pathNode.InnerText) -eq $expected) {
            return $game
        }
    }

    if ($Loose) {
        $folderKey = $FolderName.ToLowerInvariant()
        foreach ($game in $Doc.SelectNodes("/gameList/game")) {
            $pathNode = $game.SelectSingleNode("path")
            if ($null -eq $pathNode) { continue }
            $segs = @((ConvertTo-SCMComparablePath $pathNode.InnerText) -split "/" | Where-Object { $_ -ne "" })
            if ($segs.Count -ge 2 -and $segs[0] -eq $folderKey) { return $game }
        }
    }

    return $null
}

# Crea o actualiza un nodo hijo simple (<field>value</field>) SIN tocar
# los demas hijos del <game>. Si $Value es $null/"" no crea el nodo.
function Set-SCMGamelistEntryField {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$GameNode,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return
    }

    $child = $GameNode.SelectSingleNode($Field)
    if ($null -eq $child) {
        $child = $GameNode.OwnerDocument.CreateElement($Field)
        [void]$GameNode.AppendChild($child)
    }
    $child.InnerText = $Value
}

# Crea un nuevo <game> (SIN atributo id) con los campos indicados y lo
# anade al <gameList>. $Fields es un diccionario ordenado, p.ej.
# [ordered]@{ path = "..."; name = "..." }. Devuelve el XmlElement creado.
function New-SCMGamelistEntry {
    param(
        [Parameter(Mandatory)]
        [xml]$Doc,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Fields
    )

    $game = $Doc.CreateElement("game")

    foreach ($key in $Fields.Keys) {
        $val = [string]$Fields[$key]
        if ([string]::IsNullOrEmpty($val)) { continue }
        $child = $Doc.CreateElement([string]$key)
        $child.InnerText = $val
        [void]$game.AppendChild($child)
    }

    [void]$Doc.DocumentElement.AppendChild($game)
    return $game
}

function Save-SCMGamelistDocument {
    param(
        [Parameter(Mandatory)]
        [xml]$Doc,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = "`t"
    # UTF-8 sin BOM (los frontends estilo ES lo esperan asi).
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)

    # Escritura ATOMICA: XmlWriter trunca el destino al abrirlo; si algo falla a
    # mitad (fichero bloqueado por ES/RetroBat, disco lleno) dejaria el gamelist
    # truncado. Se escribe a un .tmp y se sustituye solo si termino bien.
    $tmp = "$Path.tmp"
    $writer = [System.Xml.XmlWriter]::Create($tmp, $settings)
    try {
        $Doc.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

Export-ModuleMember -Function `
    Get-SCMGamelistDocument, `
    Find-SCMGamelistEntryByFolder, `
    Set-SCMGamelistEntryField, `
    New-SCMGamelistEntry, `
    Save-SCMGamelistDocument, `
    ConvertTo-SCMComparablePath

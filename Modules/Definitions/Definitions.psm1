Set-StrictMode -Version Latest

# =====================================================================
#  Definitions.psm1 - catalogo canonico de juegos en Definitions\games.json.
#  Update-SCMDefinitions anade al catalogo los juegos escaneados que aun
#  no esten (por ShortID). Es la base contra la que Test-SCMCollection
#  (Validator) compara la coleccion.
#
#  Historia: en el chat original aparecia un bug "INVALID OBJECT" con
#  enteros sueltos mezclados. En la reconstruccion se verifico con tests
#  y se corrigieron dos fallos reales: (1) $Definitions.ShortID petaba bajo
#  Set-StrictMode con el catalogo vacio; (2) no era idempotente. Ademas el
#  guard de objetos invalidos ya no bloquea con Pause-SCM: cuenta y avisa
#  una vez al final.
# =====================================================================

function Update-SCMDefinitions {

    param(
        [Parameter(Mandatory)]
        [array]$Games
    )

    $Config = Get-SCMConfig
    $File   = Join-Path $Config.Paths.Definitions "games.json"

    # Acumular en una List para que el conteo sea fiable y evitar los quirks de
    # arrays de PowerShell (@()/+=) y del anidamiento al recargar de JSON.
    $defs = [System.Collections.Generic.List[object]]::new()
    if ((Test-Path $File) -and ((Get-Item $File).Length -gt 0)) {
        $parsed = Get-Content $File -Raw | ConvertFrom-Json
        foreach ($d in @($parsed)) { $defs.Add($d) }
    }

    # Set de ShortIDs ya presentes. Acceso a .ShortID via try/catch: bajo
    # Set-StrictMode, tocar una propiedad inexistente (o en un escalar) lanza.
    $existingIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in $defs) {
        $sid = $null; try { $sid = [string]$d.ShortID } catch { $sid = $null }
        if ($sid) { [void]$existingIds.Add($sid) }
    }

    $invalid = 0

    foreach ($Game in $Games) {

        $sid = $null; try { $sid = [string]$Game.ShortID } catch { $sid = $null }
        if ([string]::IsNullOrEmpty($sid)) {
            $invalid++
            continue
        }

        if ($existingIds.Contains($sid)) {
            continue
        }

        $defs.Add([PSCustomObject]@{
            ShortID      = $Game.ShortID
            Engine       = $Game.Engine
            Title        = $Game.Title
            Series       = $Game.SeriesName
            FolderName   = Split-Path $Game.FullPath -Leaf
            ScummVMID    = $Game.ShortID
            ScraperTitle = $Game.Description
            Aliases      = @()
        })
        [void]$existingIds.Add($sid)
    }

    # Guardado robusto: en PowerShell 5.1, "Sort-Object | ConvertTo-Json" envuelve
    # el array como { "value": [...], "Count": N }, que al recargar corrompe el
    # catalogo (se pierde la idempotencia). Se ordena en una lista y se serializa
    # con -InputObject sobre un array fresco, lo que produce un array JSON limpio.
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($d in ($defs | Sort-Object ShortID)) { $ordered.Add($d) }
    $json = ConvertTo-Json -InputObject $ordered.ToArray() -Depth 10
    Set-Content -Path $File -Value $json -Encoding UTF8

    Write-Host ""
    Write-Host ("Definitions: {0}" -f $defs.Count) -ForegroundColor Green
    if ($invalid -gt 0) {
        Write-Host ("  ({0} objeto(s) invalido(s) omitido(s))" -f $invalid) -ForegroundColor DarkYellow
    }
}

Export-ModuleMember -Function Update-SCMDefinitions

Set-StrictMode -Version Latest

# Raiz del proyecto: Config.psm1 vive en <root>\Modules\Core, subir dos niveles.
function Get-SCMRoot {
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

# Resuelve una ruta contra la raiz del proyecto SOLO si es relativa.
# Las rutas absolutas (p.ej. RomFolder) se dejan tal cual. Esto hace el
# proyecto portable: funciona este donde este (C:\scripts\..., C:\Users\..., etc.).
function Resolve-SCMPath {
    param([string]$Root, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Root $Path)
}

function Get-SCMConfig {

    $Root = Get-SCMRoot
    $ConfigFile = Join-Path $Root "config.json"

    if (!(Test-Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }

    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    # Resolver rutas relativas del config a rutas absolutas para uso interno.
    if ($cfg.PSObject.Properties.Name -contains "Paths") {
        foreach ($name in @("ScummVM", "RomFolder", "Logs", "Database", "Definitions")) {
            if ($cfg.Paths.PSObject.Properties.Name -contains $name) {
                $cfg.Paths.$name = Resolve-SCMPath -Root $Root -Path $cfg.Paths.$name
            }
        }
    }

    return $cfg
}

function Set-SCMConfig {

    param(
        [Parameter(Mandatory)]
        $Config
    )

    $Root = Get-SCMRoot
    $ConfigFile = Join-Path $Root "config.json"

    # Releer el fichero en disco y sobreescribir solo Preferences/Application.
    # Asi las rutas se conservan TAL CUAL estan en disco (relativas) y no se
    # persisten las versiones absolutas ya resueltas en memoria por Get-SCMConfig.
    $onDisk = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    if ($Config.PSObject.Properties.Name -contains "Preferences") {
        $onDisk.Preferences = $Config.Preferences
    }
    if ($Config.PSObject.Properties.Name -contains "Application") {
        $onDisk.Application = $Config.Application
    }

    # -InputObject evita el wrapper {value,Count}; el root es un objeto, no un array.
    $json = ConvertTo-Json -InputObject $onDisk -Depth 8
    Set-Content -Path $ConfigFile -Value $json -Encoding UTF8
}

# Actualiza UNA ruta en config.json (leyendo el fichero en disco, para no
# tocar las demas ni convertir a absolutas las relativas internas).
function Update-SCMConfigPath {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $Root = Get-SCMRoot
    $ConfigFile = Join-Path $Root "config.json"
    $onDisk = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if ($onDisk.Paths.PSObject.Properties.Name -contains $Name) {
        $onDisk.Paths.$Name = $Value
    }
    else {
        $onDisk.Paths | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    $json = ConvertTo-Json -InputObject $onDisk -Depth 8
    Set-Content -Path $ConfigFile -Value $json -Encoding UTF8
}

Export-ModuleMember -Function *

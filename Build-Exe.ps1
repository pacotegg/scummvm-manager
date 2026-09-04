<#
  Compila la GUI (ScummVM-Manager-GUI.ps1) a un .exe de Windows sin consola,
  con icono y metadatos, usando el modulo ps2exe.

  IMPORTANTE: el .exe resultante debe quedarse en la raiz del proyecto (junto a
  Modules\, config.json, Bin\, etc.). El .exe NO empaqueta los modulos: los
  carga en runtime desde su misma carpeta. Si mueves el .exe, muevelo con toda
  la carpeta.

  Uso:
     powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
#>
param(
    [string]$OutputName = 'ScummVM Manager.exe'
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$gui = Join-Path $Root 'ScummVM-Manager-GUI.ps1'
$ico = Join-Path $Root 'app.ico'
$out = Join-Path $Root $OutputName

Write-Host ''
Write-Host '=== Build ScummVM Manager (GUI) -> .exe ===' -ForegroundColor Cyan

if (-not (Test-Path $gui)) { throw "No encuentro la GUI: $gui" }

# 1. Icono (generarlo si falta).
if (-not (Test-Path $ico)) {
    Write-Host 'Generando icono...' -ForegroundColor DarkGray
    & (Join-Path $Root 'Tools\Generate-Icon.ps1')
}

# 2. Asegurar ps2exe.
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'El modulo ps2exe no esta instalado. Intentando instalarlo desde PSGallery (CurrentUser)...' -ForegroundColor Yellow
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    }
    catch {
        Write-Host ''
        Write-Host 'No se pudo instalar ps2exe automaticamente.' -ForegroundColor Red
        Write-Host 'Instalalo a mano (una vez) y vuelve a ejecutar este script:' -ForegroundColor Yellow
        Write-Host '   Install-Module ps2exe -Scope CurrentUser' -ForegroundColor Gray
        throw
    }
}
Import-Module ps2exe -Force

# 3. Compilar.
Write-Host "Compilando -> $out" -ForegroundColor DarkGray
Invoke-ps2exe `
    -inputFile  $gui `
    -outputFile $out `
    -iconFile   $ico `
    -noConsole `
    -STA `
    -title       'ScummVM Collection Manager' `
    -product     'ScummVM Collection Manager' `
    -description 'Gestor de coleccion ScummVM (by PaCo_El_FLaCo)' `
    -company     'PaCo_El_FLaCo' `
    -copyright   'PaCo_El_FLaCo' `
    -version     '1.0.0.0'

if (Test-Path $out) {
    $kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
    Write-Host ''
    Write-Host "OK -> $out  ($kb KB)" -ForegroundColor Green
    Write-Host 'Deja el .exe en esta carpeta (necesita Modules\ y config.json al lado).' -ForegroundColor DarkGray
    Write-Host 'Si Windows lo marca como bloqueado: Unblock-File "' -NoNewline -ForegroundColor DarkGray
    Write-Host "$out" -NoNewline -ForegroundColor DarkGray
    Write-Host '"' -ForegroundColor DarkGray
}
else {
    Write-Host 'La compilacion no genero el .exe.' -ForegroundColor Red
}

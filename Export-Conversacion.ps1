<#
.SYNOPSIS
  Exporta una sesion de Claude Code (.jsonl) a un Markdown legible.
.DESCRIPTION
  Lee el transcript JSON-lines de una sesion y genera un .md con solo el
  dialogo (mensajes del usuario y respuestas del asistente en texto),
  saltandose tool calls, tool results, recordatorios del sistema y ruido.
.PARAMETER Session
  Ruta al .jsonl. Por defecto, la sesion mas reciente de este proyecto.
.PARAMETER Out
  Ruta del .md de salida. Por defecto, junto al script.
.PARAMETER IncludeToolNotes
  Si se indica, deja una marca compacta [herramienta: X] donde hubo tool calls.
.EXAMPLE
  .\Export-Conversacion.ps1
#>
[CmdletBinding()]
param(
    [string]$Session,
    [string]$Out,
    [switch]$IncludeToolNotes,
    [string]$FromMatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectDir = "C:\Users\franc\.claude\projects\C--Users-franc-QX-quixotic-kb"

if (-not $Session) {
    $latest = Get-ChildItem (Join-Path $projectDir "*.jsonl") |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No se encontraron .jsonl en $projectDir" }
    $Session = $latest.FullName
}
if (-not (Test-Path $Session)) { throw "No existe: $Session" }

if (-not $Out) {
    $Out = Join-Path $PSScriptRoot ("Conversacion_" +
        [IO.Path]::GetFileNameWithoutExtension($Session) + ".md")
}

function Get-TextFromContent {
    param($Content, [switch]$ToolNotes)
    if ($null -eq $Content) { return "" }
    if ($Content -is [string]) { return $Content }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($block in $Content) {
        $btype = $null
        if ($block.PSObject.Properties.Name -contains 'type') { $btype = $block.type }
        switch ($btype) {
            'text' {
                if ($block.PSObject.Properties.Name -contains 'text') { $parts.Add([string]$block.text) }
            }
            'tool_use' {
                if ($ToolNotes) {
                    $name = if ($block.PSObject.Properties.Name -contains 'name') { $block.name } else { '?' }
                    $parts.Add("_[herramienta: $name]_")
                }
            }
            default { }
        }
    }
    return ($parts -join "`n`n")
}

function Test-IsNoise {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $t = $Text.TrimStart()
    if ($t.StartsWith('<system-reminder')) { return $true }
    if ($t.StartsWith('<task-notification')) { return $true }
    if ($t.StartsWith('<local-command')) { return $true }
    if ($t.StartsWith('<command-name>')) { return $true }
    if ($t.StartsWith('Caveat:')) { return $true }
    if ($t -match '^\s*<command-message>') { return $true }
    return $false
}

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("# Conversacion ScummVM Collection Manager")
$null = $sb.AppendLine()
$null = $sb.AppendLine("> Exportado de Claude Code - sesion ``$([IO.Path]::GetFileNameWithoutExtension($Session))``")
$null = $sb.AppendLine()
$null = $sb.AppendLine("---")
$null = $sb.AppendLine()

$countUser = 0; $countAsst = 0
# Si se da -FromMatch, no incluir nada hasta el primer mensaje de USUARIO que
# contenga esa subcadena (inclusive). Sin -FromMatch se incluye todo.
$started = [string]::IsNullOrEmpty($FromMatch)

Get-Content $Session -Encoding UTF8 | ForEach-Object {
    $line = $_
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    try { $o = $line | ConvertFrom-Json } catch { return }
    if (($o.PSObject.Properties.Name -notcontains 'type')) { return }
    if ($o.type -ne 'user' -and $o.type -ne 'assistant') { return }
    if ($o.PSObject.Properties.Name -notcontains 'message') { return }
    if ($null -eq $o.message) { return }

    $role = $o.message.role
    $content = if ($o.message.PSObject.Properties.Name -contains 'content') { $o.message.content } else { $null }
    $text = Get-TextFromContent -Content $content -ToolNotes:$IncludeToolNotes
    if (Test-IsNoise $text) { return }

    if (-not $started) {
        if ($role -eq 'user' -and $text.Trim() -eq $FromMatch) { $started = $true }
        else { return }
    }

    if ($role -eq 'user') {
        $null = $sb.AppendLine("## Usuario"); $null = $sb.AppendLine()
        $null = $sb.AppendLine($text.Trim()); $null = $sb.AppendLine()
        $countUser++
    }
    elseif ($role -eq 'assistant') {
        $null = $sb.AppendLine("## Claude"); $null = $sb.AppendLine()
        $null = $sb.AppendLine($text.Trim()); $null = $sb.AppendLine()
        $countAsst++
    }
}

$enc = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Out, $sb.ToString(), $enc)

$kb = [math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host ""
Write-Host "  Exportado OK" -ForegroundColor Green
Write-Host "  Origen : $Session"
Write-Host "  Salida : $Out  ($kb KB)"
Write-Host "  Turnos : $countUser del usuario / $countAsst de Claude"
Write-Host ""

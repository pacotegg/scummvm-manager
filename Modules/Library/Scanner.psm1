Set-StrictMode -Version Latest

function Invoke-SCMScan {

    $config = Get-SCMConfig

    $ScummVM   = $config.Paths.ScummVM
    $RomFolder = $config.Paths.RomFolder
    $LogFolder = $config.Paths.Logs

    if (!(Test-Path $ScummVM)) {
        Write-Host ""
        Write-Host "ScummVM executable not found." -ForegroundColor Red
        return
    }

    if (!(Test-Path $RomFolder)) {
        Write-Host ""
        Write-Host "ROM folder not found." -ForegroundColor Red
        return
    }

    if (!(Test-Path $LogFolder)) {
        New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
    }

    $Stamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $LogFile = Join-Path $LogFolder ("Scan_{0}.txt" -f $Stamp)
    $OutFile = Join-Path $LogFolder ("scummvm_out_{0}.txt" -f $Stamp)
    $ErrFile = Join-Path $LogFolder ("scummvm_err_{0}.txt" -f $Stamp)

    Write-Host ""
    Write-Host "Scanning collection..." -ForegroundColor Cyan
    Write-Host "(running ScummVM detection, this may take a moment)" -ForegroundColor DarkGray

    # Splatting: evita el bug de continuacion de linea sin backtick.
    $spArgs = @{
        FilePath               = $ScummVM
        ArgumentList           = @("--detect", "--recursive", "--path=$RomFolder")
        NoNewWindow            = $true
        Wait                   = $true
        PassThru               = $true
        RedirectStandardOutput = $OutFile
        RedirectStandardError  = $ErrFile
    }
    $proc = Start-Process @spArgs

    if (!(Test-Path $OutFile)) {
        Write-Host ""
        Write-Host "ScummVM produced no output." -ForegroundColor Red
        return
    }

    # Guardas anti-perdida de BD: si scummvm.exe fallo (DLL/plugin roto,
    # argumento invalido) NO seguir — machacariamos games.json con [].
    $exitCode = 0
    try { $exitCode = [int]$proc.ExitCode } catch { }
    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Host ("ScummVM fallo (exit code {0}) - scan abortado, la base de datos NO se toca. Revisa: {1}" -f $exitCode, $ErrFile) -ForegroundColor Red
        return
    }

    $Output = Get-Content $OutFile
    $Output | Out-File $LogFile -Encoding UTF8

    $DetectionLines = Get-SCMDetectionLines -ScummVMOutput $Output

    $Games = foreach ($Line in $DetectionLines) {
        Convert-SCMDetectionLine $Line
    }

    $Games = @($Games | Where-Object { $_ -ne $null })

    Write-Host ""
    Write-Host "Games detected: $($Games.Count)" -ForegroundColor Cyan

    $CleanGames = Invoke-SCMLibraryCleanup -Games $Games -RomFolder $RomFolder

    if (-not $CleanGames) {
        Write-Host "Cleanup returned nothing - using raw list." -ForegroundColor Yellow
        $CleanGames = $Games
    }

    $CleanGames = @($CleanGames)

    Write-Host "Clean games:    $($CleanGames.Count)" -ForegroundColor Green
    Write-Host ""

    $MetadataGames = @()
    $idx = 0
    $totalClean = @($CleanGames).Count
    foreach ($Game in $CleanGames) {
        $idx++
        if ($totalClean -gt 0) {
            Write-Progress -Activity "Procesando metadata" -Status ("{0}/{1}" -f $idx, $totalClean) -PercentComplete ([int](($idx / $totalClean) * 100))
        }
        $MetadataGames += Convert-SCMMetadata $Game
    }
    Write-Progress -Activity "Procesando metadata" -Completed

    $MetadataGames = @($MetadataGames)

    # Guardado robusto (evita el wrapper {value,Count} de "array | ConvertTo-Json"
    # en PowerShell 5.1, que romperia Get-SCMDatabase al recargar).
    $json = ConvertTo-Json -InputObject $MetadataGames -Depth 5
    Set-Content -Path (Join-Path $config.Paths.Database "games.json") -Value $json -Encoding UTF8

    Show-SCMCollectionStats -Games $MetadataGames

    # Informe de carpetas que quedaron fuera del scan (no importadas / sin
    # .scummvm). Envuelto en try/catch para no romper el scan si falla.
    try {
        $importStatus = Get-SCMImportStatus -Games $MetadataGames -RomFolder $RomFolder
        Show-SCMImportStatusReport -Status $importStatus
    }
    catch {
        Write-Host ("  (No se pudo generar el informe de importacion: {0})" -f $_.Exception.Message) -ForegroundColor DarkGray
    }

    return $MetadataGames
}


Export-ModuleMember -Function Invoke-SCMScan

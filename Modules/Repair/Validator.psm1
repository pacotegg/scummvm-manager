Set-StrictMode -Version Latest

function Get-SCMDefinitions {

    $Config = Get-SCMConfig

    $File = Join-Path $Config.Paths.Definitions "games.json"

    if (!(Test-Path $File)) {
        throw "Definitions database not found:`n$File"
    }

    Get-Content $File -Raw | ConvertFrom-Json
}

function Test-SCMCollection {

    param(
        [Parameter(Mandatory)]
        [array]$Games
    )

    $Definitions = Get-SCMDefinitions

    foreach ($Game in ($Games | Sort-Object DisplayTitle)) {

        $Definition = $Definitions |
            Where-Object { $_.ScummVMId -eq $Game.ShortID } |
            Select-Object -First 1

        if ($null -eq $Definition) {

            Write-Host ("[MISS] {0}" -f $Game.ShortID) -ForegroundColor DarkYellow
            continue
        }

        if ($Game.Title -ne $Definition.Title) {

            Write-Host ("[FAIL] {0}" -f $Game.Title) -ForegroundColor Red
            Write-Host ("       Current : {0}" -f $Game.Title)
            Write-Host ("       Expected: {0}" -f $Definition.Title)
        }
        else {

            Write-Host ("[ OK ] {0}" -f $Game.Title) -ForegroundColor Green
        }
    }
}

Export-ModuleMember -Function *

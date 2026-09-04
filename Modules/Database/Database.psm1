Set-StrictMode -Version Latest

function Get-SCMDatabase {

    $config = Get-SCMConfig

    $DatabaseFile = Join-Path $config.Paths.Database "games.json"

    if (!(Test-Path $DatabaseFile)) {
        return @()
    }

    $Games = Get-Content $DatabaseFile -Raw | ConvertFrom-Json

    return @($Games)
}

Export-ModuleMember -Function Get-SCMDatabase

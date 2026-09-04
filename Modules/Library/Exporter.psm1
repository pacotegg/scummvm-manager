Set-StrictMode -Version Latest

# =====================================================================
#  Exporter.psm1 - exporta la coleccion a CSV o HTML (con estado de media).
# =====================================================================

function ConvertTo-SCMHtmlText {
    param([string]$Text)
    return ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-SCMExportRows {
    param([array]$Games, [hashtable]$MediaIndex)

    foreach ($g in ($Games | Sort-Object DisplayTitle)) {
        $folder = Split-Path $g.FullPath -Leaf
        $st = Get-SCMMediaStatus -Index $MediaIndex -FolderName $folder
        [PSCustomObject]@{
            Title    = $g.DisplayTitle
            Series   = $g.SeriesName
            Engine   = $g.Engine
            ShortID  = $g.ShortID
            GameID   = $g.GameID
            Edition  = $g.Edition
            Platform = $g.Platform
            Language = $g.Language
            Folder   = $folder
            Image    = if ($st.Image)  { "yes" } else { "no" }
            Video    = if ($st.Video)  { "yes" } else { "no" }
            Manual   = if ($st.Manual) { "yes" } else { "no" }
        }
    }
}

function Export-SCMCollectionCsv {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$MediaIndex
    )
    $rows = @(Get-SCMExportRows -Games $Games -MediaIndex $MediaIndex)
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $rows.Count
}

function Export-SCMCollectionHtml {
    param(
        [Parameter(Mandatory)][array]$Games,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$MediaIndex
    )
    $rows = @(Get-SCMExportRows -Games $Games -MediaIndex $MediaIndex)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>ScummVM Collection</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;background:#1e1e1e;color:#ddd;margin:20px}')
    [void]$sb.AppendLine('h1{color:#4ec9d0}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%}')
    [void]$sb.AppendLine('th,td{border:1px solid #444;padding:4px 8px;font-size:13px;text-align:left}')
    [void]$sb.AppendLine('th{background:#333;color:#4ec9d0;position:sticky;top:0}')
    [void]$sb.AppendLine('tr:nth-child(even){background:#252525}')
    [void]$sb.AppendLine('.yes{color:#4caf50}.no{color:#888}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine(("<h1>ScummVM Collection ({0} games)</h1>" -f $rows.Count))
    [void]$sb.AppendLine('<table><tr><th>Title</th><th>Series</th><th>Engine</th><th>ShortID</th><th>Edition</th><th>Platform</th><th>Lang</th><th>Img</th><th>Vid</th><th>Man</th></tr>')

    foreach ($r in $rows) {
        [void]$sb.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td class='{7}'>{8}</td><td class='{9}'>{10}</td><td class='{11}'>{12}</td></tr>" -f `
            (ConvertTo-SCMHtmlText $r.Title), (ConvertTo-SCMHtmlText $r.Series), (ConvertTo-SCMHtmlText $r.Engine), (ConvertTo-SCMHtmlText $r.ShortID), `
            (ConvertTo-SCMHtmlText $r.Edition), (ConvertTo-SCMHtmlText $r.Platform), (ConvertTo-SCMHtmlText $r.Language), `
            $r.Image, $r.Image, $r.Video, $r.Video, $r.Manual, $r.Manual))
    }
    [void]$sb.AppendLine('</table></body></html>')

    Set-Content -Path $Path -Value $sb.ToString() -Encoding UTF8
    return $rows.Count
}

Export-ModuleMember -Function Get-SCMExportRows, Export-SCMCollectionCsv, Export-SCMCollectionHtml

<#
  ScummVM Collection Manager - Interfaz grafica (WPF)  v2
  by PaCo_El_FLaCo

  GUI de ventanas encima del mismo motor (los modulos .psm1). No reimplementa
  logica de negocio: llama a Get-SCMDatabase, Invoke-SCMScan, Get-SCMFrontendPlan,
  Invoke-SCMFrontendSync, Get-SCMDoctorReport, MediaFinder, GamelistXml, etc.

  Rediseno "aventura grafica": galeria de caratulas, barra de verbos estilo
  SCUMM, tema Noche/Dia conmutable en caliente y acento configurable.

  Funciones: watch-folder, galeria visual, editor de ficha (gamelist.xml),
  cola de descarga de caratulas con progreso, y modo claro/oscuro.

  Las tareas lentas (scan, descargas) corren en un runspace de fondo con un
  DispatcherTimer, para que la ventana no se congele.
#>
param([switch]$NoShow)   # -NoShow: construye todo pero no abre la ventana (tests)

# --- WPF requiere STA. Si nos han lanzado en MTA, relanzar en STA. ---
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().Path
    if (-not $exe) { $exe = 'powershell.exe' }
    if ($PSCommandPath) {
        Start-Process $exe -ArgumentList @('-STA', '-NoProfile', '-File', "`"$PSCommandPath`"")
    }
    return
}

$ErrorActionPreference = 'Stop'

# Ocultar la ventana de consola (la "ventana negra"): es una app WPF, la consola
# no aporta nada. Funciona con cualquier lanzador (.cmd/.vbs/doble-clic).
try {
    if (-not ('SCM.Win32' -as [type])) {
        Add-Type -Namespace SCM -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
    }
    $__con = [SCM.Win32]::GetConsoleWindow()
    if ($__con -ne [System.IntPtr]::Zero) { [void][SCM.Win32]::ShowWindow($__con, 0) }  # 0 = SW_HIDE
} catch { }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Fila de la galeria como CLASE .NET tipada (no PSCustomObject): los brushes /
# imagenes creados en PowerShell van envueltos en PSObject y el DATA BINDING de
# WPF los recibe como null. Con propiedades tipadas (Brush/ImageSource) el
# binding recibe el tipo limpio. (Verificado en pruebas headless.)
if (-not ('SCMRow' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase -TypeDefinition @"
using System.Windows;
using System.Windows.Media;
public class SCMRow {
    public string Title { get; set; }
    public string Engine { get; set; }
    public string EngineChip { get; set; }
    public string MediaState { get; set; }
    public string Folder { get; set; }
    public Brush StripeBrush { get; set; }
    public Brush CoverBrush { get; set; }
    public ImageSource CoverImage { get; set; }
    public Visibility CoverVisible { get; set; }
    public Stretch CoverStretch { get; set; }
    public string Badges { get; set; }
    public object Game { get; set; }
    public object Media { get; set; }
}
"@
}

$script:Root =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($PSCommandPath) { Split-Path $PSCommandPath }
    else { Split-Path ([System.Reflection.Assembly]::GetEntryAssembly().Location) }

$script:ImportBlockText = @'
Import-Module "$Root\Modules\UI\Theme.psm1"            -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\Core.psm1"           -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\Config.psm1"         -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\Logger.psm1"         -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\LibraryCleaner.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Core\NameSanitizer.psm1"  -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Scanner.psm1"         -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Parser.psm1"          -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Metadata.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\CollectionStats.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Fallback.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\EditionAdvisor.psm1"  -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\MediaStatus.psm1"     -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\MediaFinder.psm1"     -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Scrapers.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\Exporter.psm1"        -Force -DisableNameChecking
Import-Module "$Root\Modules\Repair\Doctor.psm1"           -Force -DisableNameChecking
Import-Module "$Root\Modules\Database\Database.psm1"       -Force -DisableNameChecking
Import-Module "$Root\Modules\Definitions\Definitions.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\GamelistXml.psm1"    -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\FrontendSync.psm1"   -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\BundleAssistant.psm1" -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\ImportStatus.psm1"    -Force -DisableNameChecking
Import-Module "$Root\Modules\Frontend\WindowsLinker.psm1"   -Force -DisableNameChecking
Import-Module "$Root\Modules\Library\MediaGrab.psm1"        -Force -DisableNameChecking
'@
. ([scriptblock]::Create($script:ImportBlockText))

$script:Config = Get-SCMConfig
$script:MediaFolderNames = @('images', 'videos', 'manuals', 'marquees', 'snaps')

$script:AppVer = '1.0'; $script:AppAuth = 'PaCo_El_FLaCo'
# Sello de build: si al arrancar la cabecera NO muestra esto, estas ejecutando
# una copia vieja del codigo (recopia la carpeta al PC de juegos).
$script:BuildTag = 'build 2026-07-10a (revision integral: 20+ fixes, Undo en GUI, banner miniaturas)'
try {
    if ($script:Config.PSObject.Properties.Name -contains 'Application') {
        if ($script:Config.Application.PSObject.Properties.Name -contains 'Version') { $script:AppVer = [string]$script:Config.Application.Version }
        if ($script:Config.Application.PSObject.Properties.Name -contains 'Author') { $script:AppAuth = [string]$script:Config.Application.Author }
    }
} catch { }

# =====================================================================
#  Tema (paletas Noche/Dia + acento configurable)
# =====================================================================
$script:Palettes = @{
    Dark = @{ Ink = '#141220'; Slate = '#1D1A2B'; Raised = '#262234'; Line = '#332C46'; Text = '#EDE6D6'; Muted = '#9A93B0'; AccentInk = '#141220'; Ok = '#59C39A'; Partial = '#E8935C'; None = '#6C6785' }
    Light = @{ Ink = '#E9E2D2'; Slate = '#F6F1E7'; Raised = '#FCF9F2'; Line = '#DCD2BE'; Text = '#2A2436'; Muted = '#6D6480'; AccentInk = '#FBF8F1'; Ok = '#2E9E70'; Partial = '#BF6733'; None = '#938BA6' }
}
$script:AccentMap = @{
    Gold    = @{ Dark = '#F2B84B'; Light = '#B47F16' }
    Cyan    = @{ Dark = '#22D3EE'; Light = '#0E7490' }
    Green   = @{ Dark = '#59C39A'; Light = '#2E9E70' }
    Magenta = @{ Dark = '#E879F9'; Light = '#A21CAF' }
    Blue    = @{ Dark = '#60A5FA'; Light = '#2563EB' }
}
$script:ThemeMode = 'Dark'; $script:ThemeAccent = 'Gold'
try {
    if ($script:Config.Preferences.PSObject.Properties.Name -contains 'UI') {
        $ui = $script:Config.Preferences.UI
        if ($ui.PSObject.Properties.Name -contains 'Theme' -and $script:Palettes.ContainsKey([string]$ui.Theme)) { $script:ThemeMode = [string]$ui.Theme }
        if ($ui.PSObject.Properties.Name -contains 'GuiAccent' -and $script:AccentMap.ContainsKey([string]$ui.GuiAccent)) { $script:ThemeAccent = [string]$ui.GuiAccent }
    }
} catch { }

$script:ThemeTokens = @{}
$script:Sem = @{}

function New-SCMBrush {
    param([string]$Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze(); return $b
}

# Aplica el tema: siembra los brushes DynamicResource de la ventana principal,
# los brushes semanticos ($script:Sem) y los tokens para los dialogos.
function Set-SCMTheme {
    param([string]$Mode, [string]$AccentName)
    if (-not $script:Palettes.ContainsKey($Mode)) { $Mode = 'Dark' }
    if (-not $script:AccentMap.ContainsKey($AccentName)) { $AccentName = 'Gold' }
    $p = $script:Palettes[$Mode]
    $acc = $script:AccentMap[$AccentName][$Mode]

    $vals = @{
        Ink = $p.Ink; Slate = $p.Slate; Raised = $p.Raised; Line = $p.Line
        Text = $p.Text; Muted = $p.Muted; Accent = $acc; AccentInk = $p.AccentInk
        Ok = $p.Ok; Partial = $p.Partial; None = $p.None
    }
    if ($script:Window) {
        # BrushConverter inline: evita el envoltorio PSObject que rompe DynamicResource.
        $conv = New-Object System.Windows.Media.BrushConverter
        foreach ($k in $vals.Keys) { $script:Window.Resources[$k] = $conv.ConvertFromString($vals[$k]) }
    }
    $script:Sem = @{ Full = (New-SCMBrush $p.Ok); Partial = (New-SCMBrush $p.Partial); None = (New-SCMBrush $p.None) }

    $script:ThemeTokens = @{}
    foreach ($k in $vals.Keys) { $script:ThemeTokens["@$($k.ToUpper())@"] = $vals[$k] }

    $script:ThemeMode = $Mode; $script:ThemeAccent = $AccentName
}
Set-SCMTheme -Mode $script:ThemeMode -AccentName $script:ThemeAccent

# =====================================================================
#  Helpers de imagen / filas
# =====================================================================
function New-SCMBitmap {
    param([string]$Path, [int]$DecodeWidth = 0)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        if ($DecodeWidth -gt 0) { $bi.DecodePixelWidth = $DecodeWidth }
        $bi.StreamSource = $ms
        $bi.EndInit()
        $bi.Freeze()
        return $bi
    } catch { return $null }
}

# --- Contexto activo: ScummVM por defecto, Windows mientras su ventana esta
#     abierta. Permite reusar el motor de media para los dos sistemas sin tocar
#     el comportamiento de ScummVM (WinMode=$false por defecto). ---
$script:WinMode = $false
$script:WinRows = @()
$script:WinList = $null

function Get-SCMActiveRom {
    if ($script:WinMode) { try { return (Get-SCMWindowsRomFolder) } catch { return '' } }
    return $script:Config.Paths.RomFolder
}
function Get-SCMActiveRows {
    if ($script:WinMode) { return $script:WinRows }
    return $script:AllRows
}

# Lista los ficheros de la carpeta images UNA vez (para bucles: pasarla a
# Find-SCMCoverPath -Files y evitar cientos de Get-ChildItem por refresco).
function Get-SCMImagesFiles {
    param([string]$RomFolder)
    $dir = Join-Path $RomFolder 'images'
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue)
}

function Find-SCMCoverPath {
    param([string]$Folder, [string]$RomFolder, [object[]]$Files)
    if ($null -eq $Files) {
        if ([string]::IsNullOrWhiteSpace($RomFolder)) { $RomFolder = Get-SCMActiveRom }
        $Files = Get-SCMImagesFiles -RomFolder $RomFolder
    }
    foreach ($suffix in @('-image', '-thumb', '-fanart')) {
        $rx = '^' + [regex]::Escape("$Folder$suffix") + '\.'
        foreach ($f in $Files) { if ($f.Name -match $rx) { return $f.FullName } }
    }
    return $null
}

# Gradiente "caja de juego" determinista a partir del titulo (para placeholders).
$script:CoverPairs = @(
    @('#1b3a5c', '#0d1730'), @('#6d1f2e', '#25101c'), @('#31384a', '#12131b'),
    @('#4a3410', '#1a1206'), @('#264a2a', '#0e1a10'), @('#59371c', '#1c0f07'),
    @('#3a2340', '#150c18'), @('#204a4a', '#0c1a1a'), @('#3d1f34', '#160b13'),
    @('#4a4118', '#1a1708'), @('#153a2e', '#081a13'), @('#22304a', '#0b111c')
)
function New-SCMCoverBrush {
    param([string]$Key)
    $h = 0
    foreach ($ch in $Key.ToCharArray()) { $h = (($h * 31) + [int]$ch) -band 0x7fffffff }
    $pair = $script:CoverPairs[$h % $script:CoverPairs.Count]
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point 0, 0
    $b.EndPoint = New-Object System.Windows.Point 1, 1
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($pair[0]), 0)))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($pair[1]), 1)))
    $b.Freeze(); return $b
}

function Get-SCMRows {
    $games = @(Get-SCMDatabase)
    $rom = Get-SCMActiveRom
    $idx = @{}
    if (Test-Path $rom) { $idx = Get-SCMMediaIndex -RomFolder $rom }
    # Lista de images UNA vez para todo el bucle (no un Get-ChildItem por juego).
    $imgFiles = Get-SCMImagesFiles -RomFolder $rom
    # Modo de ajuste de caratula (Ajustes -> CoverFit: 'Fill' recorta, si no entera).
    $stretch = [System.Windows.Media.Stretch]::Uniform
    try { if ([string]$script:Config.Preferences.UI.CoverFit -eq 'Fill') { $stretch = [System.Windows.Media.Stretch]::UniformToFill } } catch { }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($g in $games) {
        $folder = Split-Path $g.FullPath -Leaf
        # Nombres alternativos (titulo saneado) por si la BD y el disco difieren.
        $alts = @()
        try {
            if (Get-Command ConvertTo-SCMSafeFileName -ErrorAction SilentlyContinue) {
                foreach ($t in @([string]$g.DisplayTitle, [string]$g.Title)) {
                    if (-not [string]::IsNullOrWhiteSpace($t)) { $a = ConvertTo-SCMSafeFileName $t; if ($a -and $a -ne $folder) { $alts += $a } }
                }
            }
        } catch { }
        $st = $null
        if ($idx.Count -gt 0) { $st = Get-SCMMediaStatus -Index $idx -FolderName $folder -AltFolderNames $alts }
        $state = 'None'
        if ($st) { if ($st.HasCore) { $state = 'Full' } elseif ($st.AnyMedia) { $state = 'Partial' } }

        # Badges de media presente (para el vistazo rapido en la tarjeta).
        $badges = ''
        if ($st) {
            if ($st.Video) { $badges += 'V ' }
            if ($st.Manual) { $badges += 'M ' }
            if ($st.Snap) { $badges += 'S ' }
            if ($st.Marquee) { $badges += 'Q ' }
        }

        $cover = Find-SCMCoverPath -Folder $folder -Files $imgFiles
        if (-not $cover) { foreach ($a in $alts) { $cover = Find-SCMCoverPath -Folder $a -Files $imgFiles; if ($cover) { break } } }
        $img = if ($cover) { New-SCMBitmap -Path $cover -DecodeWidth 220 } else { $null }
        $engine = [string]$g.Engine
        if (-not $engine) { $engine = '?' }

        $r = New-Object SCMRow
        $r.Title = [string]$g.DisplayTitle
        $r.Engine = $engine
        $r.EngineChip = ("[{0}]" -f $engine)
        $r.MediaState = $state
        $r.StripeBrush = $script:Sem[$state]
        $r.CoverBrush = (New-SCMCoverBrush ($g.DisplayTitle + '|' + $folder))
        $r.CoverImage = $img
        $r.CoverVisible = $(if ($img) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
        $r.CoverStretch = $stretch
        $r.Badges = $badges.Trim()
        $r.Folder = $folder
        $r.Game = $g
        $r.Media = $st
        $rows.Add($r)
    }
    return $rows
}

# =====================================================================
#  Trabajo en segundo plano (runspace + DispatcherTimer, uno a la vez)
# =====================================================================
$script:Job = $null

function Set-SCMBusy {
    param([bool]$On, [string]$Text = '')
    if ($script:UI.Progress) { $script:UI.Progress.Visibility = $(if ($On) { 'Visible' } else { 'Collapsed' }) }
    if ($Text) { Set-SCMStatus $Text }
    # Tambien Windows/Estado: cambiar de contexto (WinMode) con un job de fondo
    # en marcha haria que su OnDone guardara en la carpeta equivocada.
    foreach ($b in @($script:UI.BtnScan, $script:UI.BtnSync, $script:UI.BtnDoctor, $script:UI.BtnWindows, $script:UI.BtnImport)) {
        if ($b) { $b.IsEnabled = -not $On }
    }
}
function Set-SCMStatus { param([string]$Text) if ($script:UI.Status) { $script:UI.Status.Text = $Text } }

function Start-SCMJob {
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [scriptblock]$OnDone,
        [scriptblock]$OnProgress,
        [hashtable]$Sync,
        [string]$Status = 'Trabajando...',
        [hashtable]$Vars
    )
    if (Get-Command Write-SCMTrace -ErrorAction SilentlyContinue) { Write-SCMTrace ("Start-SCMJob: '{0}'" -f $Status) }
    if ($script:Job) { if (Get-Command Write-SCMTrace -ErrorAction SilentlyContinue) { Write-SCMTrace '  Start-SCMJob ABORTA: ya hay job' }; return }
    Set-SCMBusy $true $Status

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Root', $script:Root)
    $rs.SessionStateProxy.SetVariable('ImportBlockText', $script:ImportBlockText)
    if ($Sync) { $rs.SessionStateProxy.SetVariable('Sync', $Sync) }
    if ($Vars) { foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) } }

    $psh = [powershell]::Create(); $psh.Runspace = $rs
    $null = $psh.AddScript($Work)
    $script:Job = @{ PS = $psh; RS = $rs; Handle = $psh.BeginInvoke(); OnDone = $OnDone; OnProgress = $OnProgress; Sync = $Sync }
    $script:UITimer.Start()
}

# --- Ventana de progreso (popup con barra + item actual + Cancelar) ---
$script:ProgWin = $null
$script:CancelRequested = $false

function Show-SCMProgress {
    param([string]$Title, [switch]$Indeterminate)
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Progreso" Width="480" Height="200" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow" ShowInTaskbar="False" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <StackPanel Margin="24" VerticalAlignment="Center">
    <TextBlock x:Name="pTitle" FontWeight="Bold" FontSize="15" Foreground="@ACCENT@"/>
    <TextBlock x:Name="pNow" Foreground="@MUTED@" Margin="0,10,0,10" TextTrimming="CharacterEllipsis" Text="Preparando..."/>
    <ProgressBar x:Name="pBar" Height="12" Minimum="0" Value="0" Maximum="100" Foreground="@ACCENT@" Background="@SLATE@" BorderThickness="0"/>
    <Grid Margin="0,12,0,0">
      <TextBlock x:Name="pCount" HorizontalAlignment="Left" VerticalAlignment="Center" FontFamily="Consolas" FontSize="12" Foreground="@TEXT@" Text="0 / 0"/>
      <Button x:Name="pCancel" Content="Cancelar" HorizontalAlignment="Right" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="12,6" Cursor="Hand"/>
    </Grid>
  </StackPanel>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('pTitle').Text = $Title
    $w.Topmost = $true
    $w.FindName('pCancel').Add_Click({ Stop-SCMCurrentJob }.GetNewClosure())
    $script:ProgWin = @{ Win = $w; Bar = $w.FindName('pBar'); Now = $w.FindName('pNow'); Count = $w.FindName('pCount'); Cancel = $w.FindName('pCancel') }
    if ($Indeterminate) { $script:ProgWin.Bar.IsIndeterminate = $true; $script:ProgWin.Count.Visibility = 'Collapsed' }
    $w.Show()
}

function Update-SCMProgress {
    param($Sync)
    if (-not $script:ProgWin -or -not $Sync) { return }
    try {
        if ($Sync.Total -gt 0) { $script:ProgWin.Bar.Maximum = $Sync.Total; $script:ProgWin.Bar.Value = $Sync.Done }
        $script:ProgWin.Count.Text = ("{0} / {1}" -f $Sync.Done, $Sync.Total)
        if ($Sync.Current) { $script:ProgWin.Now.Text = [string]$Sync.Current }
    } catch { }
}

function Close-SCMProgress {
    if ($script:ProgWin) { try { $script:ProgWin.Win.Close() } catch { }; $script:ProgWin = $null }
}

function Stop-SCMCurrentJob {
    if ($script:Job) {
        $script:CancelRequested = $true
        if ($script:ProgWin) { try { $script:ProgWin.Now.Text = 'Cancelando...'; $script:ProgWin.Cancel.IsEnabled = $false } catch { } }
        try { $script:Job.PS.Stop() } catch { }
    }
}

# =====================================================================
#  XAML de la ventana principal (usa DynamicResource para el tema en caliente)
# =====================================================================
$xamlMain = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScummVM Collection Manager"
        Width="1120" Height="760" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource Ink}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI" FontSize="13" TextOptions.TextFormattingMode="Ideal">
  <Window.Resources>
    <!-- Sombras (negro, independientes del tema) -->
    <DropShadowEffect x:Key="ShadowSoft" Color="#000000" BlurRadius="16" ShadowDepth="3" Direction="270" Opacity="0.34"/>
    <DropShadowEffect x:Key="ShadowCard" Color="#000000" BlurRadius="22" ShadowDepth="6" Direction="270" Opacity="0.5"/>
    <DropShadowEffect x:Key="ShadowStrong" Color="#000000" BlurRadius="28" ShadowDepth="7" Direction="270" Opacity="0.6"/>

    <!-- Scrollbar fina moderna -->
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="th" CornerRadius="5" Background="{DynamicResource Line}" Margin="2,2"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="th" Property="Background" Value="{DynamicResource Muted}"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="10"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Botones -->
    <Style x:Key="Tool" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource Raised}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="13,8"/>
      <Setter Property="Margin" Value="5,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Tool}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Effect" Value="{StaticResource ShadowSoft}"/>
    </Style>
    <Style x:Key="Seg" TargetType="Button">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Verb" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource Slate}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Margin" Value="0,0,7,7"/>
      <Setter Property="Padding" Value="8,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}" BorderThickness="1" BorderBrush="{DynamicResource Line}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="VerbGo" TargetType="Button" BasedOn="{StaticResource Verb}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>

    <!-- Barra de progreso redondeada (determinada) -->
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="Background" Value="{DynamicResource Slate}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border CornerRadius="20" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource Line}" BorderThickness="1"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="20" Background="{TemplateBinding Foreground}" Margin="1"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Tarjeta de galeria -->
    <DataTemplate x:Key="tmplCard">
      <Grid Width="150" Height="204">
        <Border CornerRadius="11" Background="{Binding CoverBrush}"/>
        <Border CornerRadius="11" ClipToBounds="True">
          <Image Source="{Binding CoverImage}" Visibility="{Binding CoverVisible}" Stretch="{Binding CoverStretch}" Margin="4,4,4,0" VerticalAlignment="Center"/>
        </Border>
        <Border Width="5" HorizontalAlignment="Left" CornerRadius="11,0,0,11" Background="{Binding StripeBrush}"/>
        <Border VerticalAlignment="Top" HorizontalAlignment="Right" Margin="8" CornerRadius="6" Padding="6,3" Background="#A608060E">
          <TextBlock Text="{Binding Engine}" FontFamily="Consolas" FontSize="10" Foreground="#EDE6D6"/>
        </Border>
        <Border VerticalAlignment="Top" HorizontalAlignment="Left" Margin="10,8,0,0" CornerRadius="5" Padding="5,2" Background="#A608060E">
          <TextBlock Text="{Binding Badges}" FontFamily="Consolas" FontSize="9.5" FontWeight="Bold" Foreground="#59C39A"/>
        </Border>
        <Border VerticalAlignment="Bottom" CornerRadius="0,0,11,11">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#0008060E" Offset="0"/><GradientStop Color="#E608060E" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock Text="{Binding Title}" TextWrapping="Wrap" MaxHeight="54" Margin="10,20,10,9"
                     FontFamily="Consolas" FontSize="11.5" FontWeight="Bold" Foreground="#F7F1E4"/>
        </Border>
      </Grid>
    </DataTemplate>

    <!-- Fila de lista -->
    <DataTemplate x:Key="tmplRow">
      <Grid Height="30">
        <Border Width="4" HorizontalAlignment="Left" CornerRadius="2" Background="{Binding StripeBrush}"/>
        <StackPanel Orientation="Horizontal" Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="{Binding EngineChip}" FontFamily="Consolas" FontSize="12" Width="92" Foreground="{DynamicResource Muted}"/>
          <TextBlock Text="{Binding Title}" FontSize="13.5" Foreground="{DynamicResource Text}"/>
        </StackPanel>
      </Grid>
    </DataTemplate>

    <ItemsPanelTemplate x:Key="panelWrap"><WrapPanel/></ItemsPanelTemplate>
    <ItemsPanelTemplate x:Key="panelStack"><StackPanel/></ItemsPanelTemplate>

    <!-- Contenedor de item (seleccion) -->
    <Style x:Key="cardItem" TargetType="ListBoxItem">
      <Setter Property="Margin" Value="7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" CornerRadius="13" BorderThickness="2" BorderBrush="Transparent" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="scl" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Line}"/>
                <Setter TargetName="bd" Property="Effect" Value="{StaticResource ShadowCard}"/>
                <Setter TargetName="bd" Property="Panel.ZIndex" Value="10"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="scl" Storyboard.TargetProperty="ScaleX" To="1.045" Duration="0:0:0.13"/>
                      <DoubleAnimation Storyboard.TargetName="scl" Storyboard.TargetProperty="ScaleY" To="1.045" Duration="0:0:0.13"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="scl" Storyboard.TargetProperty="ScaleX" To="1.0" Duration="0:0:0.13"/>
                      <DoubleAnimation Storyboard.TargetName="scl" Storyboard.TargetProperty="ScaleY" To="1.0" Duration="0:0:0.13"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="bd" Property="Effect" Value="{StaticResource ShadowStrong}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Barra de titulo -->
    <Border Grid.Row="0" Background="{DynamicResource Slate}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Padding="16,10" Effect="{StaticResource ShadowSoft}" Panel.ZIndex="5">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="logoBox" Width="36" Height="36" CornerRadius="10" Background="{DynamicResource Accent}" Effect="{StaticResource ShadowSoft}" Cursor="Hand" ToolTip="Acerca de ScummVM Collection Manager">
            <TextBlock Text="&#xE7FC;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets, Segoe UI Symbol" FontSize="18" Foreground="{DynamicResource AccentInk}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="13,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="ScummVM Collection Manager" FontFamily="Consolas" FontWeight="Bold" FontSize="15" Foreground="{DynamicResource Text}"/>
            <TextBlock x:Name="txtSub" FontFamily="Consolas" FontSize="10.5" Foreground="{DynamicResource Muted}" Margin="0,1,0,0"/>
          </StackPanel>
        </StackPanel>
        <Border Grid.Column="1" x:Name="statPill" Background="{DynamicResource Raised}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="16" Padding="13,5" Margin="0,0,10,0" VerticalAlignment="Center" Visibility="Collapsed">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="7" Height="7" Fill="{DynamicResource Ok}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="txtStat" FontFamily="Consolas" FontSize="11" Foreground="{DynamicResource Text}" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <Button Grid.Column="2" x:Name="btnTheme" Style="{StaticResource Tool}" Content="Tema"/>
      </Grid>
    </Border>

    <!-- Toolbar -->
    <Border Grid.Row="1" Background="{DynamicResource Ink}" Padding="16,13">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="{DynamicResource Raised}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="9" Padding="14,9" Margin="0,0,10,0">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="&#xE721;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets, Segoe UI Symbol" FontSize="14" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="0,0,11,0"/>
            <Grid Grid.Column="1">
              <TextBox x:Name="txtSearch" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource Text}" VerticalContentAlignment="Center" FontSize="14" CaretBrush="{DynamicResource Text}"/>
              <TextBlock x:Name="phSearch" Text="Buscar juego, engine, serie..." Foreground="{DynamicResource Muted}" IsHitTestVisible="False" VerticalAlignment="Center"/>
            </Grid>
          </Grid>
        </Border>
        <Border Grid.Column="1" Background="{DynamicResource Raised}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="9" Padding="3" Margin="0,0,10,0">
          <StackPanel Orientation="Horizontal">
            <Button x:Name="segGallery" Content="Galeria" Style="{StaticResource Seg}"/>
            <Button x:Name="segList" Content="Lista" Style="{StaticResource Seg}"/>
          </StackPanel>
        </Border>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="btnScan" Content="Rescan" Style="{StaticResource Tool}" ToolTip="Escanea la carpeta de ROMs con scummvm --detect y actualiza la base de datos"/>
          <Button x:Name="btnSync" Content="Sync Frontend" Style="{StaticResource Primary}" ToolTip="Renombra carpetas mal nombradas, crea los .scummvm y actualiza gamelist.xml (con plan previo y backup)"/>
          <Button x:Name="btnDoctor" Content="Doctor" Style="{StaticResource Tool}" ToolTip="Chequeo de salud: duplicados, carpetas sin .scummvm, media huerfana o incompleta, miniaturas sobrantes"/>
          <Button x:Name="btnImport" Content="Estado" Style="{StaticResource Tool}" ToolTip="Compara las carpetas del disco con el scan: que se detecto, que falta y por que"/>
          <Button x:Name="btnWindows" Content="Windows" Style="{StaticResource Tool}" ToolTip="Gestiona los juegos nativos/remasters (roms\windows): enlaces .lnk y su media"/>
          <Button x:Name="btnSettings" Content="Ajustes" Style="{StaticResource Tool}" ToolTip="Rutas, credenciales de scrapers, tema y apariencia"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Banner watch-folder -->
    <Border Grid.Row="2" x:Name="banner" Visibility="Collapsed" Margin="16,0,16,0" CornerRadius="10" Padding="13,11"
            Background="{DynamicResource Raised}" BorderBrush="{DynamicResource Accent}" BorderThickness="1">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Ellipse Grid.Column="0" Width="9" Height="9" Fill="{DynamicResource Accent}" VerticalAlignment="Center" Margin="0,0,11,0"/>
        <TextBlock Grid.Column="1" x:Name="bannerText" VerticalAlignment="Center" FontSize="13.5" Foreground="{DynamicResource Text}"/>
        <Button Grid.Column="2" x:Name="btnBanner" Content="Revisar y sincronizar" Style="{StaticResource Tool}" Margin="10,0,0,0"/>
      </Grid>
    </Border>

    <!-- Cuerpo: galeria/lista + detalle -->
    <Grid Grid.Row="3" Margin="16,13,16,13">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="430"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="{DynamicResource Slate}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="12" Effect="{StaticResource ShadowSoft}">
        <Grid>
          <ListBox x:Name="lstGames" Background="Transparent" BorderThickness="0" Padding="6"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   ItemContainerStyle="{StaticResource cardItem}"
                   ItemTemplate="{StaticResource tmplCard}" ItemsPanel="{StaticResource panelWrap}"/>
          <StackPanel x:Name="emptyHint" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False">
            <TextBlock Text="&#xE7FC;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets, Segoe UI Symbol" FontSize="52" Foreground="{DynamicResource Line}" HorizontalAlignment="Center"/>
            <TextBlock x:Name="emptyHint1" Text="No hay juegos que mostrar" Foreground="{DynamicResource Muted}" FontFamily="Consolas" FontSize="13.5" Margin="0,12,0,0" HorizontalAlignment="Center"/>
            <TextBlock x:Name="emptyHint2" Text="Pulsa Rescan para escanear la coleccion" Foreground="{DynamicResource Muted}" FontFamily="Consolas" FontSize="11" Margin="0,5,0,0" HorizontalAlignment="Center" Opacity="0.65"/>
          </StackPanel>
        </Grid>
      </Border>

      <Border Grid.Column="1" Background="{DynamicResource Slate}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="12" Margin="14,0,0,0" Effect="{StaticResource ShadowSoft}">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16">
          <StackPanel>
            <Border Background="{DynamicResource Raised}" CornerRadius="10" Padding="10" Effect="{StaticResource ShadowSoft}">
              <Grid MinHeight="150">
                <Image x:Name="dCoverImg" Stretch="Uniform" MaxHeight="440" HorizontalAlignment="Center"/>
                <TextBlock x:Name="dNoCover" Text="Sin caratula" Foreground="{DynamicResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" FontSize="12"/>
              </Grid>
            </Border>

            <TextBlock x:Name="dTitle" Margin="0,14,0,8" FontSize="17" FontWeight="Bold" TextWrapping="Wrap" Foreground="{DynamicResource Text}" Text="Selecciona un juego"/>
            <WrapPanel x:Name="dChips" Margin="0,0,0,12"/>
            <StackPanel x:Name="dMeta"/>

            <TextBlock Text="MEDIA" FontFamily="Consolas" FontSize="10.5" Margin="0,14,0,7" Foreground="{DynamicResource Muted}"/>
            <TextBlock x:Name="dMedia" FontFamily="Consolas" FontSize="12.5" TextWrapping="Wrap" Foreground="{DynamicResource Text}"/>

            <TextBlock Text="ACCIONES" FontFamily="Consolas" FontSize="10.5" Margin="0,16,0,8" Foreground="{DynamicResource Muted}"/>
            <WrapPanel x:Name="verbBar"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <!-- Cola de descarga + status bar -->
    <Border Grid.Row="4" Background="{DynamicResource Slate}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0">
      <StackPanel>
        <Border x:Name="queuePanel" Visibility="Collapsed" Padding="16,10" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Margin="0,0,16,0">
              <TextBlock x:Name="queueNow" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,0,0,6"/>
              <ProgressBar x:Name="queueBar" Style="{StaticResource Bar}" Minimum="0" Value="0" Maximum="100"/>
            </StackPanel>
            <TextBlock Grid.Column="1" x:Name="queueCount" FontFamily="Consolas" FontSize="12" Foreground="{DynamicResource Accent}" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <Grid Margin="16,9">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" x:Name="txtStatus" VerticalAlignment="Center" Foreground="{DynamicResource Muted}" FontSize="12.5" Text="Listo"/>
          <ProgressBar Grid.Column="1" x:Name="pbBusy" Width="150" Height="6" IsIndeterminate="True" Visibility="Collapsed" Foreground="{DynamicResource Accent}" Margin="14,0,0,0"/>
          <StackPanel Grid.Column="3" Orientation="Horizontal" x:Name="watchInd" Visibility="Collapsed">
            <Ellipse Width="7" Height="7" Fill="{DynamicResource Ok}" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Text="Vigilando carpeta" FontFamily="Consolas" FontSize="11" Foreground="{DynamicResource Ok}" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

function ConvertFrom-SCMXaml {
    param([string]$Xaml)
    foreach ($k in $script:ThemeTokens.Keys) { $Xaml = $Xaml.Replace($k, $script:ThemeTokens[$k]) }
    return [System.Windows.Markup.XamlReader]::Parse($Xaml)
}

$script:Window = ConvertFrom-SCMXaml -Xaml $xamlMain
$window = $script:Window
# Sembrar los brushes del tema ahora que la ventana existe.
Set-SCMTheme -Mode $script:ThemeMode -AccentName $script:ThemeAccent

$script:UI = @{
    Window = $window
    Sub = $window.FindName('txtSub'); BtnTheme = $window.FindName('btnTheme'); LogoBox = $window.FindName('logoBox')
    StatPill = $window.FindName('statPill'); StatText = $window.FindName('txtStat'); EmptyHint = $window.FindName('emptyHint'); EmptyHint1 = $window.FindName('emptyHint1'); EmptyHint2 = $window.FindName('emptyHint2')
    Search = $window.FindName('txtSearch'); PhSearch = $window.FindName('phSearch')
    SegGallery = $window.FindName('segGallery'); SegList = $window.FindName('segList')
    BtnScan = $window.FindName('btnScan'); BtnSync = $window.FindName('btnSync')
    BtnDoctor = $window.FindName('btnDoctor'); BtnSettings = $window.FindName('btnSettings')
    BtnImport = $window.FindName('btnImport'); BtnWindows = $window.FindName('btnWindows')
    Banner = $window.FindName('banner'); BannerText = $window.FindName('bannerText'); BtnBanner = $window.FindName('btnBanner')
    List = $window.FindName('lstGames')
    DCoverImg = $window.FindName('dCoverImg'); DNoCover = $window.FindName('dNoCover')
    DTitle = $window.FindName('dTitle'); DChips = $window.FindName('dChips'); DMeta = $window.FindName('dMeta'); DMedia = $window.FindName('dMedia')
    VerbBar = $window.FindName('verbBar')
    QueuePanel = $window.FindName('queuePanel'); QueueNow = $window.FindName('queueNow'); QueueBar = $window.FindName('queueBar'); QueueCount = $window.FindName('queueCount')
    Status = $window.FindName('txtStatus'); Progress = $window.FindName('pbBusy'); WatchInd = $window.FindName('watchInd')
}
$script:UI.Sub.Text = ("v{0} - by {1}  |  {2}" -f $script:AppVer, $script:AppAuth, $script:BuildTag)

# =====================================================================
#  Registro de errores VISIBLE. Sin esto, una excepcion en cualquier
#  handler la traga WPF en silencio y el boton "no hace nada". Todo
#  handler debe ir envuelto en Invoke-SCMSafe.
# =====================================================================
function Write-SCMGuiError {
    param([string]$Where, $ErrorObj)
    try {
        $logDir = Join-Path $script:Root 'Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $log = Join-Path $logDir 'gui_error.log'
        $exMsg = ''; $stack = ''
        try { if ($ErrorObj -is [System.Management.Automation.ErrorRecord]) { $exMsg = $ErrorObj.Exception.Message; $stack = [string]$ErrorObj.ScriptStackTrace } elseif ($ErrorObj -is [System.Exception]) { $exMsg = $ErrorObj.Message; $stack = [string]$ErrorObj.StackTrace } else { $exMsg = [string]$ErrorObj } } catch { $exMsg = [string]$ErrorObj }
        $line = ("[{0}] {1}`n  {2}`n  {3}`n---`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Where, $exMsg, ($stack -replace "`n", "`n  "))
        Add-Content -Path $log -Value $line -Encoding UTF8
        return $exMsg
    } catch { return [string]$ErrorObj }
}

function Invoke-SCMSafe {
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Name = 'accion')
    try { & $Action }
    catch {
        $m = Write-SCMGuiError -Where $Name -ErrorObj $_
        try { Set-SCMStatus ("Error en '{0}' (ver Logs\gui_error.log)" -f $Name) } catch { }
        try { [System.Windows.MessageBox]::Show(("Fallo en '{0}':`n`n{1}`n`nDetalle completo en:`nLogs\gui_error.log" -f $Name, $m), 'ScummVM Manager - error', 'OK', 'Warning') | Out-Null } catch { }
    }
}

# Rastro de ejecucion (Logs\gui_trace.log): breadcrumbs para ver por donde pasa
# el codigo al pulsar un boton, aunque no haya error. Si al pulsar NO aparece
# nada aqui, es senal de que se esta ejecutando una copia vieja del codigo.
function Write-SCMTrace {
    param([string]$Msg)
    try {
        $logDir = Join-Path $script:Root 'Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg) | Out-File -FilePath (Join-Path $logDir 'gui_trace.log') -Append -Encoding UTF8
    } catch { }
}

# Backstop: excepciones que lleguen al Dispatcher (por si algo escapa a Invoke-SCMSafe).
try {
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try { Write-SCMGuiError -Where 'Dispatcher' -ErrorObj $e.Exception | Out-Null } catch { }
        try { [System.Windows.MessageBox]::Show(("Error no controlado:`n`n{0}`n`nVer Logs\gui_error.log" -f $e.Exception.Message), 'ScummVM Manager') | Out-Null } catch { }
        $e.Handled = $true
    })
} catch { }

# Backstop de ULTIMO recurso: excepciones no controladas de CUALQUIER hilo. No
# evita el cierre (WPF puede terminar igual) pero DEJA CONSTANCIA en el log antes
# de morir, para poder diagnosticar un "peta y se cierra".
try {
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.ExceptionObject
            $msg = if ($ex -is [System.Exception]) { $ex.Message + "`n" + $ex.StackTrace } else { [string]$ex }
            $logDir = Join-Path $script:Root 'Logs'
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            ("[{0}] AppDomain UNHANDLED (la app va a cerrarse):`n{1}`n===`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) | Out-File -FilePath (Join-Path $logDir 'gui_error.log') -Append -Encoding UTF8
        } catch { }
    })
} catch { }

# --- Timer de trabajos de fondo ---
$script:UITimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UITimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:UITimer.Add_Tick({
    if ($null -eq $script:Job) { $script:UITimer.Stop(); return }
    if (-not $script:Job.Handle.IsCompleted) {
        if ($script:Job.OnProgress -and $script:Job.Sync) {
            try { & $script:Job.OnProgress $script:Job.Sync } catch { }
        }
        return
    }
    $j = $script:Job; $script:Job = $null; $script:UITimer.Stop()
    $result = $null; $err = $null
    try { $result = $j.PS.EndInvoke($j.Handle) } catch { $err = $_ }
    if (Get-Command Write-SCMTrace -ErrorAction SilentlyContinue) { Write-SCMTrace ("job de fondo TERMINADO (err={0})" -f $(if ($err) { $err.Exception.Message } else { 'ninguno' })) }
    if ($err) { try { Write-SCMGuiError -Where 'Job de fondo' -ErrorObj $err | Out-Null } catch { } }
    try { $j.PS.Dispose(); $j.RS.Close(); $j.RS.Dispose() } catch { }
    Set-SCMBusy $false
    if ($script:CancelRequested) {
        $script:CancelRequested = $false
        Close-SCMProgress
        if ($script:UI.QueuePanel) { $script:UI.QueuePanel.Visibility = 'Collapsed' }
        try { Update-SCMActive } catch { }
        Set-SCMStatus 'Operacion cancelada.'
        return
    }
    if ($j.OnDone) { try { & $j.OnDone $result $err } catch { [System.Windows.MessageBox]::Show("$_", 'Error') | Out-Null } }
})

# =====================================================================
#  Lista / galeria / detalle
# =====================================================================
$script:AllRows = @()
$script:ViewMode = 'Gallery'

function Set-SCMViewMode {
    param([string]$Mode)
    $script:ViewMode = $Mode
    if ($Mode -eq 'List') {
        $script:UI.List.ItemTemplate = $window.FindResource('tmplRow')
        $script:UI.List.ItemsPanel = $window.FindResource('panelStack')
        $script:UI.SegList.Background = $script:Window.Resources['Accent']; $script:UI.SegList.Foreground = $script:Window.Resources['AccentInk']
        $script:UI.SegGallery.Background = [System.Windows.Media.Brushes]::Transparent; $script:UI.SegGallery.Foreground = $script:Window.Resources['Muted']
    } else {
        $script:UI.List.ItemTemplate = $window.FindResource('tmplCard')
        $script:UI.List.ItemsPanel = $window.FindResource('panelWrap')
        $script:UI.SegGallery.Background = $script:Window.Resources['Accent']; $script:UI.SegGallery.Foreground = $script:Window.Resources['AccentInk']
        $script:UI.SegList.Background = [System.Windows.Media.Brushes]::Transparent; $script:UI.SegList.Foreground = $script:Window.Resources['Muted']
    }
}

function Update-SCMList {
    param([string]$Filter = '')
    $rows = $script:AllRows
    if ($Filter) {
        $f = $Filter.ToLowerInvariant()
        $rows = @($rows | Where-Object {
            ($_.Title -and $_.Title.ToLowerInvariant().Contains($f)) -or ($_.Engine -and $_.Engine.ToLowerInvariant().Contains($f))
        })
    }
    $script:UI.List.ItemsSource = @($rows)
    # Estado vacio (sin juegos o sin resultados de busqueda)
    if ($script:UI.EmptyHint) {
        if (@($rows).Count -eq 0) {
            if (@($script:AllRows).Count -eq 0) {
                if ($script:UI.EmptyHint1) { $script:UI.EmptyHint1.Text = 'No hay juegos que mostrar' }
                if ($script:UI.EmptyHint2) { $script:UI.EmptyHint2.Text = 'Pulsa Rescan para escanear la coleccion' }
            } else {
                if ($script:UI.EmptyHint1) { $script:UI.EmptyHint1.Text = 'Sin resultados' }
                if ($script:UI.EmptyHint2) { $script:UI.EmptyHint2.Text = 'Prueba con otro texto de busqueda' }
            }
            $script:UI.EmptyHint.Visibility = 'Visible'
        } else {
            $script:UI.EmptyHint.Visibility = 'Collapsed'
        }
    }
}

function Update-SCMStatusBar {
    $total = @($script:AllRows).Count
    $full = @($script:AllRows | Where-Object { $_.MediaState -eq 'Full' }).Count
    $pct = if ($total -gt 0) { [math]::Round(100.0 * $full / $total) } else { 0 }
    Set-SCMStatus ("{0} juegos   -   {1} con media completa ({2}%)" -f $total, $full, $pct)
    if ($script:UI.StatText -and $script:UI.StatPill) {
        if ($total -gt 0) {
            $script:UI.StatText.Text = ("{0} juegos  -  {1}% media" -f $total, $pct)
            $script:UI.StatPill.Visibility = 'Visible'
        } else {
            $script:UI.StatPill.Visibility = 'Collapsed'
        }
    }
}

function Update-SCMData {
    $script:AllRows = @(Get-SCMRows)
    $f = ''
    if ($script:UI.Search.Text) { $f = $script:UI.Search.Text }
    Update-SCMList -Filter $f
    Update-SCMStatusBar
}

# Refresco context-aware: si estamos en la ventana Windows, refresca su galeria;
# si no, la de ScummVM. Lo usan los OnDone de las descargas de media.
function Update-SCMActive {
    if ($script:WinMode -and (Get-Command Update-SCMWinRows -ErrorAction SilentlyContinue)) { Update-SCMWinRows }
    else { Update-SCMData }
}

function Add-SCMProp {
    param($Panel, [string]$Label, [string]$Value, [bool]$Accent = $false)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '-' }
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = '0,2,0,2'
    $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $Label; $l.Width = 90; $l.FontFamily = 'Consolas'; $l.FontSize = 11
    $l.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
    $v = New-Object System.Windows.Controls.TextBlock; $v.Text = $Value; $v.TextWrapping = 'Wrap'; $v.FontSize = 12.5
    $v.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($Accent) { 'Accent' } else { 'Text' }))
    if ($Accent) { $v.FontFamily = 'Consolas' }
    $null = $sp.Children.Add($l); $null = $sp.Children.Add($v); $null = $Panel.Children.Add($sp)
}

function Add-SCMChip {
    param($Panel, [string]$Text, [bool]$Accent = $false)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = [System.Windows.CornerRadius]::new(6); $b.Padding = '8,4'; $b.Margin = '0,0,6,6'; $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Raised')
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $(if ($Accent) { 'Accent' } else { 'Line' }))
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontFamily = 'Consolas'; $t.FontSize = 10.5
    $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($Accent) { 'Accent' } else { 'Muted' }))
    $b.Child = $t; $null = $Panel.Children.Add($b)
}

function Show-SCMDetail {
    param($Row)
    $script:UI.DChips.Children.Clear(); $script:UI.DMeta.Children.Clear()
    if ($null -eq $Row) {
        $script:UI.DTitle.Text = 'Selecciona un juego'
        $script:UI.DCoverImg.Source = $null; $script:UI.DNoCover.Visibility = 'Visible'; $script:UI.DMedia.Text = ''
        return
    }
    $g = $Row.Game
    $script:UI.DTitle.Text = $Row.Title
    $big = $null
    $cover = Find-SCMCoverPath $Row.Folder
    if ($cover) { $big = New-SCMBitmap -Path $cover -DecodeWidth 640 }
    $script:UI.DCoverImg.Source = $big
    $script:UI.DNoCover.Visibility = $(if ($big) { 'Collapsed' } else { 'Visible' })

    Add-SCMChip $script:UI.DChips $g.Engine $true
    Add-SCMChip $script:UI.DChips ([string]$g.Edition)
    Add-SCMChip $script:UI.DChips ([string]$g.Language)

    Add-SCMProp $script:UI.DMeta 'ScummVM ID' ([string]$g.GameID) $true
    Add-SCMProp $script:UI.DMeta 'Serie' ([string]$g.SeriesName)
    Add-SCMProp $script:UI.DMeta 'Plataforma' ([string]$g.Platform)
    Add-SCMProp $script:UI.DMeta 'Carpeta' ([string]$Row.Folder)

    $m = $Row.Media
    $mark = { param($b) if ($b) { '[x]' } else { '[ ]' } }
    if ($m) {
        # (Sin "Miniatura": los -thumb estan retirados; RetroBat los pintaba
        #  encima de la caratula. Mismos 6 tipos que el dialogo Descargar media.)
        $script:UI.DMedia.Text = ("{0} Caratula   {1} Fanart    {2} Video`n{3} Marquee    {4} Snap      {5} Manual" -f `
            (& $mark $m.Image), (& $mark $m.Fanart), (& $mark $m.Video), (& $mark $m.Marquee), (& $mark $m.Snap), (& $mark $m.Manual))
    } else { $script:UI.DMedia.Text = '(carpeta de ROMs no encontrada)' }
}

function Get-SCMSelectedRow {
    if ($script:WinMode -and $script:WinList) { return $script:WinList.SelectedItem }
    return $script:UI.List.SelectedItem
}

# --- Barra de verbos ---
function Add-SCMVerb {
    param([string]$Text, [scriptblock]$OnClick, [bool]$Go = $false)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Style = $window.FindResource($(if ($Go) { 'VerbGo' } else { 'Verb' }))
    $b.Width = 148
    $b.Add_Click({ Invoke-SCMSafe -Name $Text -Action $OnClick }.GetNewClosure())
    $null = $script:UI.VerbBar.Children.Add($b)
}
$script:UI.VerbBar.Children.Clear()
Add-SCMVerb 'Ver caratula' { $r = Get-SCMSelectedRow; if ($r) { $p = Find-SCMCoverPath $r.Folder; if ($p) { Start-Process $p } else { [System.Windows.MessageBox]::Show('Este juego no tiene caratula todavia.', 'Ver caratula') | Out-Null } } }
Add-SCMVerb 'Abrir carpeta' { $r = Get-SCMSelectedRow; if ($r -and (Test-Path $r.Game.FullPath)) { Start-Process explorer.exe $r.Game.FullPath } }
Add-SCMVerb 'Editar ficha' { Show-SCMGamelistEditor (Get-SCMSelectedRow) }
Add-SCMVerb 'Media Finder' { Show-SCMLinks (Get-SCMSelectedRow) }
Add-SCMVerb 'Bajar caratula' { Invoke-SCMCoverJob (Get-SCMSelectedRow) } $true
Add-SCMVerb 'Descargar media' { Show-SCMScrapeDialog } $true
Add-SCMVerb 'Buscar imagen' { $r = Get-SCMSelectedRow; if ($r) { Show-SCMImageGrab $r } } $true
Add-SCMVerb 'Bajar video 15s' { $r = Get-SCMSelectedRow; if ($r) { Show-SCMVideoGrab $r } } $true
Add-SCMVerb 'Buscar manual' { $r = Get-SCMSelectedRow; if ($r) { Show-SCMManualGrab $r } } $true

# =====================================================================
#  Dialogos
# =====================================================================
function New-SCMDialog { param([string]$Xaml) $w = ConvertFrom-SCMXaml -Xaml $Xaml; $w.Owner = $script:UI.Window; return $w }

function Show-SCMAbout {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Acerca de" Width="430" Height="310" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <StackPanel Margin="26" VerticalAlignment="Center">
    <TextBlock Text="ScummVM Collection Manager" FontFamily="Consolas" FontSize="19" FontWeight="Bold" Foreground="@ACCENT@" TextAlignment="Center"/>
    <TextBlock x:Name="tVer" TextAlignment="Center" Foreground="@MUTED@" Margin="0,6,0,0" FontFamily="Consolas"/>
    <Border Height="1" Background="@LINE@" Margin="0,18"/>
    <TextBlock TextAlignment="Center" TextWrapping="Wrap" Foreground="@TEXT@" Text="Gestor de coleccion ScummVM para frontends estilo EmulationStation / RetroBat: detecta, renombra, genera .scummvm, sincroniza gamelist.xml y descarga media."/>
    <TextBlock x:Name="tAuth" TextAlignment="Center" Margin="0,16,0,0" FontWeight="SemiBold"/>
    <Button x:Name="ok" Content="Cerrar" Width="110" HorizontalAlignment="Center" Margin="0,20,0,0" Background="@ACCENT@" Foreground="@ACCENTINK@" BorderThickness="0" Padding="8,7" Cursor="Hand"/>
  </StackPanel>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('tVer').Text = ("version {0}" -f $script:AppVer)
    $w.FindName('tAuth').Text = ("Creado por {0}" -f $script:AppAuth)
    $w.FindName('ok').Add_Click({ $w.Close() }.GetNewClosure())
    $null = $w.ShowDialog()
}

function Show-SCMLinks {
    param($Row)
    if ($null -eq $Row) { return }
    $links = Get-SCMMediaSearchLinks -Title $Row.Game.Title
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Media Finder" Width="460" Height="360" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <StackPanel Margin="20">
    <TextBlock x:Name="t" FontSize="15" FontWeight="Bold" Foreground="@ACCENT@" TextWrapping="Wrap"/>
    <TextBlock Text="Abre una busqueda en el navegador y elige tu la media:" Foreground="@MUTED@" Margin="0,4,0,14" TextWrapping="Wrap"/>
    <StackPanel x:Name="links"/>
  </StackPanel>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('t').Text = $Row.Title
    $panel = $w.FindName('links')
    foreach ($name in $links.Keys) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $name; $btn.Margin = '0,0,0,8'; $btn.Padding = '10,8'; $btn.HorizontalContentAlignment = 'Left'; $btn.Cursor = 'Hand'; $btn.BorderThickness = [System.Windows.Thickness]::new(0)
        $btn.Background = New-SCMBrush $script:ThemeTokens['@RAISED@']; $btn.Foreground = New-SCMBrush $script:ThemeTokens['@TEXT@']
        $btn.Tag = $links[$name]
        $btn.Add_Click({ Start-Process $this.Tag }.GetNewClosure())
        $null = $panel.Children.Add($btn)
    }
    $null = $w.ShowDialog()
}

function Show-SCMGamelistEditor {
    param($Row)
    if ($null -eq $Row) { return }
    $rom = Get-SCMActiveRom
    $gl = Join-Path $rom 'gamelist.xml'
    if (-not (Test-Path $gl)) { [System.Windows.MessageBox]::Show('No hay gamelist.xml todavia. Haz Sync Frontend primero.', 'Editar ficha') | Out-Null; return }
    $doc = Get-SCMGamelistDocument -Path $gl
    $entry = Find-SCMGamelistEntryByFolder -Doc $doc -FolderName $Row.Folder
    if ($null -eq $entry) { [System.Windows.MessageBox]::Show(("'{0}' no tiene ficha en gamelist.xml. Haz Sync Frontend para crearla." -f $Row.Folder), 'Editar ficha') | Out-Null; return }

    $getField = { param($node, $f) $n = $node.SelectSingleNode($f); if ($n) { return $n.InnerText } else { return '' } }
    $curName = & $getField $entry 'name'; if (-not $curName) { $curName = $Row.Title }
    $curDesc = & $getField $entry 'desc'
    $curRating = & $getField $entry 'rating'

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Editar ficha" Width="560" Height="470" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="20">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="hdr" FontWeight="Bold" FontSize="15" Foreground="@ACCENT@" TextWrapping="Wrap" Margin="0,0,0,14"/>
    <TextBlock Grid.Row="1" Text="Nombre" FontFamily="Consolas" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,4"/>
    <TextBox Grid.Row="2" x:Name="tName" Padding="7,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@" Margin="0,0,0,12"/>
    <TextBlock Grid.Row="3" Text="Descripcion" FontFamily="Consolas" FontSize="11" Foreground="@MUTED@" VerticalAlignment="Top" Margin="0,0,0,4"/>
    <TextBox Grid.Row="3" x:Name="tDesc" Margin="0,20,0,12" Padding="7,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
    <TextBlock Grid.Row="4" Text="Rating (0.0 - 1.0)" FontFamily="Consolas" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,4"/>
    <TextBox Grid.Row="5" x:Name="tRating" Width="120" HorizontalAlignment="Left" Padding="7,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@" Margin="0,0,0,14"/>
    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="bCancel" Content="Cancelar" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bSave" Content="Guardar" Width="100" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('hdr').Text = ("Ficha de: {0}" -f $Row.Folder)
    $tName = $w.FindName('tName'); $tName.Text = $curName
    $tDesc = $w.FindName('tDesc'); $tDesc.Text = $curDesc
    $tRating = $w.FindName('tRating'); $tRating.Text = $curRating
    $w.FindName('bCancel').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bSave').Add_Click({
        try {
            # (Fix 2026-07-10: el parametro es -GameNode; con -Node el binding
            #  fallaba SIEMPRE y "Editar ficha" nunca guardaba.)
            Set-SCMGamelistEntryField -GameNode $entry -Field 'name' -Value $tName.Text
            Set-SCMGamelistEntryField -GameNode $entry -Field 'desc' -Value $tDesc.Text
            if (-not [string]::IsNullOrWhiteSpace($tRating.Text)) { Set-SCMGamelistEntryField -GameNode $entry -Field 'rating' -Value $tRating.Text.Trim() }
            try { if (Get-Command Backup-SCMGamelist -ErrorAction SilentlyContinue) { Backup-SCMGamelist -Path $gl | Out-Null } } catch { }
            Save-SCMGamelistDocument -Doc $doc -Path $gl
            $w.Close()
            Set-SCMStatus ("Ficha actualizada: {0}" -f $Row.Folder)
        } catch { [System.Windows.MessageBox]::Show("$_", 'Error al guardar') | Out-Null }
    }.GetNewClosure())
    $null = $w.ShowDialog()
}

# Quita las miniaturas (-thumb) generadas y su referencia <thumbnail> del
# gamelist (con backup). RetroBat mostraba el thumbnail encima de la imagen.
function Remove-SCMThumbnails {
    param([string]$RomFolder)
    $removed = 0
    if ([string]::IsNullOrWhiteSpace($RomFolder) -or -not (Test-Path $RomFolder)) { return 0 }
    $imagesDir = Join-Path $RomFolder 'images'
    if (Test-Path $imagesDir) {
        foreach ($f in @(Get-ChildItem $imagesDir -File -Filter '*-thumb.*' -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $f.FullName -Force; $removed++ } catch { }
        }
    }
    # Quitar <thumbnail>...</thumbnail> del gamelist (regex tolerante; NO toca
    # <thumbnail_> que usa el sistema windows para otra cosa).
    $gl = Join-Path $RomFolder 'gamelist.xml'
    if (Test-Path $gl) {
        try {
            $raw = Get-Content -LiteralPath $gl -Raw -Encoding UTF8
            $new = [regex]::Replace($raw, '[ \t]*<thumbnail>.*?</thumbnail>[ \t]*\r?\n?', '', 'Singleline')
            if ($new -ne $raw) {
                try { if (Get-Command Backup-SCMGamelist -ErrorAction SilentlyContinue) { Backup-SCMGamelist -Path $gl | Out-Null } } catch { }
                # UTF-8 SIN BOM (Set-Content -Encoding UTF8 en PS 5.1 mete BOM y
                # los frontends estilo ES esperan el gamelist sin el).
                [System.IO.File]::WriteAllText($gl, $new, (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch { }
    }
    return $removed
}

function Show-SCMDoctor {
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Doctor') | Out-Null; return }
    Set-SCMStatus 'Analizando la coleccion...'
    $rep = Get-SCMDoctorReport -Games (@(Get-SCMDatabase)) -RomFolder $rom
    Update-SCMStatusBar
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("DOCTOR = chequeo de salud (informe). Los botones de abajo llevan a la solucion.")
    $null = $sb.AppendLine("'Carpetas sin .scummvm': si el juego ES de ScummVM -> Sync Frontend > Detect NEW lo crea.")
    $null = $sb.AppendLine("Si es un remaster/nativo (Another World, Broken Sword Reforged, Day of the Tentacle")
    $null = $sb.AppendLine("Remastered, Fahrenheit, Flashback...) NO puede tener .scummvm -> enlazalo desde 'Windows'.")
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("ScummVM: $(if($rep.ScummvmOk){'OK'}else{'NO ENCONTRADO'})    ROMs: $(if($rep.RomOk){'OK'}else{'NO'})")
    $null = $sb.AppendLine("Juegos en la base de datos: $($rep.GameCount)"); $null = $sb.AppendLine('')
    $null = $sb.AppendLine("Duplicados (mismo ID): $(@($rep.Duplicates).Count)")
    foreach ($d in @($rep.Duplicates)) { $null = $sb.AppendLine("   $($d.ShortID): $($d.Folders -join ', ')") }
    $null = $sb.AppendLine(''); $null = $sb.AppendLine("Carpetas sin .scummvm: $(@($rep.NoScummvm).Count)")
    foreach ($f in @($rep.NoScummvm | Select-Object -First 25)) { $null = $sb.AppendLine("   $f") }
    $null = $sb.AppendLine(''); $null = $sb.AppendLine("Entradas de gamelist sin carpeta: $(@($rep.OrphanEntries).Count)")
    foreach ($f in @($rep.OrphanEntries | Select-Object -First 25)) { $null = $sb.AppendLine("   $f") }
    $null = $sb.AppendLine(''); $null = $sb.AppendLine("Media huerfana (sin juego): $(@($rep.OrphanMedia).Count)")
    foreach ($f in @($rep.OrphanMedia | Select-Object -First 25)) { $null = $sb.AppendLine("   $f") }
    $null = $sb.AppendLine(''); $null = $sb.AppendLine("Juegos con media incompleta: $(@($rep.MissingMedia).Count)")
    foreach ($g in @($rep.MissingMedia | Select-Object -First 40)) { $null = $sb.AppendLine(("   {0}  (falta: {1})" -f $g.Title, ($g.Media.Missing -join ', '))) }
    $nThumbs = Get-SCMLeftoverThumbCount -RomFolder $script:Config.Paths.RomFolder
    try { $nThumbs += Get-SCMLeftoverThumbCount -RomFolder (Get-SCMWindowsRomFolder) } catch { }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("Miniaturas sobrantes (-thumb): $nThumbs $(if ($nThumbs -gt 0) { '-> usa el boton [Quitar miniaturas]' } else { '(limpio)' })")

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Doctor - salud de la coleccion" Width="650" Height="580" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1">
      <TextBox x:Name="body" IsReadOnly="True" Background="Transparent" Foreground="@TEXT@" BorderThickness="0" FontFamily="Consolas" FontSize="12" Padding="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    </Border>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="bThumbs" Content="Quitar miniaturas" ToolTip="Borra los *-thumb.* y su &lt;thumbnail&gt; del gamelist (ScummVM y Windows, con backup)" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="bLogs" Content="Abrir Logs" ToolTip="Abre la carpeta Logs (gui_error, gui_trace, media_debug, Scan...)" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="bUndo" Content="Deshacer Sync" ToolTip="Revierte el ultimo Sync Frontend usando su log de operaciones (renombres, .scummvm y gamelist)" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="bSync" Content="Sync Frontend" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="bWin" Content="Windows" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="ok" Content="Cerrar" Width="100" Background="@ACCENT@" Foreground="@ACCENTINK@" BorderThickness="0" Padding="8,7" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('body').Text = $sb.ToString()
    $w.FindName('ok').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bThumbs').Add_Click({ Invoke-SCMSafe -Name 'Quitar miniaturas' -Action { Invoke-SCMRemoveThumbs } }.GetNewClosure())
    $w.FindName('bLogs').Add_Click({ Invoke-SCMSafe -Name 'Abrir Logs' -Action {
        $logDir = Join-Path $script:Root 'Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Start-Process explorer.exe $logDir
    } }.GetNewClosure())
    $w.FindName('bUndo').Add_Click({ Invoke-SCMSafe -Name 'Deshacer Sync' -Action {
        $romU = $script:Config.Paths.RomFolder
        $lastLog = $null
        try { $lastLog = Get-SCMLastSyncLog } catch { }
        if (-not $lastLog) { [System.Windows.MessageBox]::Show('No hay ningun Sync que deshacer (sin log de operaciones pendiente).', 'Deshacer Sync') | Out-Null; return }
        $ans = [System.Windows.MessageBox]::Show(("Deshacer el ULTIMO Sync Frontend?`n`nSe revierten renombres de carpetas/media, los .scummvm creados y el gamelist, usando:`n{0}`n`n(Se hace backup del gamelist antes.)" -f (Split-Path $lastLog -Leaf)), 'Deshacer Sync', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
        $script:UI.Window.Cursor = 'Wait'
        try { Invoke-SCMUndoLastSync -RomFolder $romU -GamelistPath (Join-Path $romU 'gamelist.xml') -Confirm:$false }
        finally { $script:UI.Window.Cursor = 'Arrow' }
        try { Update-SCMData } catch { }
        [System.Windows.MessageBox]::Show('Undo aplicado. Revisa la galeria y refresca RetroBat.', 'Deshacer Sync') | Out-Null
    } }.GetNewClosure())
    $w.FindName('bSync').Add_Click({ $w.Close(); Invoke-SCMSafe -Name 'Sync Frontend' -Action { Show-SCMSync } }.GetNewClosure())
    $w.FindName('bWin').Add_Click({ $w.Close(); Invoke-SCMSafe -Name 'Windows' -Action { Show-SCMWindowsMedia } }.GetNewClosure())
    $null = $w.ShowDialog()
}

function Show-SCMImportStatus {
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Import Status') | Out-Null; return }
    Set-SCMStatus 'Analizando carpetas vs scan...'
    $st = Get-SCMImportStatus -Games (@(Get-SCMDatabase)) -RomFolder $rom
    Update-SCMStatusBar

    # --- Log a fichero: cada carpeta + si es valida para ScummVM (Logs\carpetas_scummvm.txt) ---
    $logPath = $null
    try {
        $logDir = Join-Path $script:Root 'Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logPath = Join-Path $logDir 'carpetas_scummvm.txt'
        $lg = New-Object System.Text.StringBuilder
        $null = $lg.AppendLine("Carpetas en: $rom")
        $null = $lg.AppendLine("Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')    Total: $($st.TotalFolders)")
        $null = $lg.AppendLine("ScummVM valido = detectado por scummvm --detect o con .scummvm.")
        $null = $lg.AppendLine(('-' * 90))
        $null = $lg.AppendLine(("{0,-45} {1,-24} {2}" -f 'CARPETA', 'SCUMMVM', 'ID / NOTA'))
        $null = $lg.AppendLine(('-' * 90))
        foreach ($f in ($st.Folders | Sort-Object State, Folder)) {
            $valido = ''; $nota = ''
            switch ($f.State) {
                'Ok'           { $valido = 'SI (detectado)';        $nota = [string]$f.ScummvmId }
                'NeedsScummvm' { $valido = 'SI (falta .scummvm)';   $nota = 'Sync Frontend crea el .scummvm' }
                'PlayableOnly' { $valido = 'SI (.scummvm)';         $nota = [string]$f.ScummvmId }
                'Missing'      {
                    if ($f.KnownGuess) { $valido = 'POSIBLE (nombre)'; $nota = "parecido a ScummVM $($f.KnownGuess) - si es remaster, va a Windows" }
                    else { $valido = 'NO (nativo/remaster)'; $nota = 'enlazar a Windows' }
                }
            }
            $null = $lg.AppendLine(("{0,-45} {1,-24} {2}" -f $f.Folder, $valido, $nota))
        }
        [System.IO.File]::WriteAllText($logPath, $lg.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    } catch { $logPath = $null }

    $sb = New-Object System.Text.StringBuilder
    if ($logPath) { $null = $sb.AppendLine("(Listado completo guardado en: Logs\carpetas_scummvm.txt)"); $null = $sb.AppendLine('') }
    $null = $sb.AppendLine("Carpetas de juego en disco: $($st.TotalFolders)"); $null = $sb.AppendLine('')
    $null = $sb.AppendLine("Detectadas + .scummvm (OK) : $(@($st.Ok).Count)")
    $null = $sb.AppendLine("Detectadas, sin .scummvm   : $(@($st.NeedsScummvm).Count)   (haz Sync Frontend)")
    $null = $sb.AppendLine("Sin detectar, con .scummvm : $(@($st.PlayableOnly).Count)   (RetroBat las lanza)")
    $null = $sb.AppendLine("Sin detectar y sin .scummvm: $(@($st.Missing).Count)   (no apareceran)")

    if (@($st.NeedsScummvm).Count -gt 0) {
        $null = $sb.AppendLine(''); $null = $sb.AppendLine('--- Detectadas pero sin .scummvm (Sync Frontend > Detect NEW) ---')
        foreach ($f in $st.NeedsScummvm) { $null = $sb.AppendLine("   $($f.Folder)") }
    }
    if (@($st.PlayableOnly).Count -gt 0) {
        $null = $sb.AppendLine(''); $null = $sb.AppendLine('--- Fuera del scan pero ya tienen .scummvm ---')
        foreach ($f in $st.PlayableOnly) { $null = $sb.AppendLine(("   {0}  ({1})" -f $f.Folder, $f.ScummvmId)) }
    }
    if (@($st.Missing).Count -gt 0) {
        $null = $sb.AppendLine(''); $null = $sb.AppendLine('--- No importadas y sin .scummvm ---')
        foreach ($f in $st.Missing) {
            if ($null -ne $f.KnownGuess) { $null = $sb.AppendLine(("   {0}   [ID conocido {1} -> Sync Frontend lo crea]" -f $f.Folder, $f.KnownGuess)) }
            else { $null = $sb.AppendLine(("   {0}   (sin ID: juego no-ScummVM -> usa Windows)" -f $f.Folder)) }
        }
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Import Status - carpetas vs scan" Width="640" Height="560" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1">
      <TextBox x:Name="body" IsReadOnly="True" Background="Transparent" Foreground="@TEXT@" BorderThickness="0" FontFamily="Consolas" FontSize="12" Padding="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    </Border>
    <Button Grid.Row="1" x:Name="ok" Content="Cerrar" Width="110" HorizontalAlignment="Right" Margin="0,12,0,0" Background="@ACCENT@" Foreground="@ACCENTINK@" BorderThickness="0" Padding="8,7" Cursor="Hand"/>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('body').Text = $sb.ToString()
    $w.FindName('ok').Add_Click({ $w.Close() }.GetNewClosure())
    $null = $w.ShowDialog()
}

# =====================================================================
#  Pestana Windows: gestor de media para juegos nativos (roms\windows)
# =====================================================================

# Lee el gamelist.xml de roms\windows y devuelve juegos {Key;Name;ImageRel},
# deduplicados por Key (clave de media = carpeta/base del <path>). Tolerante a
# XML mal formado (regex de respaldo).
function Get-SCMWinGamesFromGamelist {
    param([string]$RomFolder)
    $out = @()
    $glPath = Join-Path $RomFolder 'gamelist.xml'
    if (-not (Test-Path $glPath)) { return $out }
    $raw = ''
    try { $raw = Get-Content -LiteralPath $glPath -Raw -Encoding UTF8 } catch { return $out }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $out }

    $entries = @()
    try {
        [xml]$doc = $raw
        foreach ($g in $doc.SelectNodes('/gameList/game')) {
            $pn = $g.SelectSingleNode('path'); if ($null -eq $pn) { continue }
            $nn = $g.SelectSingleNode('name')
            $img = $g.SelectSingleNode('image'); if ($null -eq $img) { $img = $g.SelectSingleNode('thumbnail') }
            $entries += @{ Path = $pn.InnerText; Name = $(if ($nn) { [string]$nn.InnerText } else { '' }); Image = $(if ($img) { [string]$img.InnerText } else { '' }) }
        }
    } catch {
        foreach ($bm in [regex]::Matches($raw, '<game\b[^>]*>(?<b>.*?)</game>', 'Singleline')) {
            $b = $bm.Groups['b'].Value
            $pm = [regex]::Match($b, '<path>(?<v>.*?)</path>', 'Singleline'); if (-not $pm.Success) { continue }
            $nm = [regex]::Match($b, '<name>(?<v>.*?)</name>', 'Singleline')
            $im = [regex]::Match($b, '<image>(?<v>.*?)</image>', 'Singleline'); if (-not $im.Success) { $im = [regex]::Match($b, '<thumbnail>(?<v>.*?)</thumbnail>', 'Singleline') }
            $entries += @{ Path = $pm.Groups['v'].Value; Name = $(if ($nm.Success) { $nm.Groups['v'].Value } else { '' }); Image = $(if ($im.Success) { $im.Groups['v'].Value } else { '' }) }
        }
    }

    $byKey = [ordered]@{}
    foreach ($e in $entries) {
        $key = Get-SCMFolderFromGamelistPath $e.Path
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $good = ($e.Name -and $e.Name -ne 'data')
        if (-not $byKey.Contains($key)) {
            $byKey[$key] = @{ Key = $key; Name = $(if ($good) { $e.Name } else { $key }); Image = $e.Image; Good = $good }
        } else {
            # preferir la entrada con nombre real y/o con imagen
            if ($good -and -not $byKey[$key].Good) { $byKey[$key].Name = $e.Name; $byKey[$key].Good = $true }
            if (-not $byKey[$key].Image -and $e.Image) { $byKey[$key].Image = $e.Image }
        }
    }
    foreach ($k in $byKey.Keys) { $out += [PSCustomObject]$byKey[$k] }
    return @($out)
}

function Get-SCMWinRows {
    $rom = Get-SCMWindowsRomFolder
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $rom)) { return $rows }
    $idx = Get-SCMMediaIndex -RomFolder $rom
    $imgFiles = Get-SCMImagesFiles -RomFolder $rom
    $stretch = [System.Windows.Media.Stretch]::Uniform
    try { if ([string]$script:Config.Preferences.UI.CoverFit -eq 'Fill') { $stretch = [System.Windows.Media.Stretch]::UniformToFill } } catch { }

    foreach ($g in (Get-SCMWinGamesFromGamelist -RomFolder $rom)) {
        $key = $g.Key
        $st = Get-SCMMediaStatus -Index $idx -FolderName $key
        $state = 'None'
        if ($st) { if ($st.HasCore) { $state = 'Full' } elseif ($st.AnyMedia) { $state = 'Partial' } }
        $badges = ''
        if ($st) { if ($st.Video) { $badges += 'V ' }; if ($st.Manual) { $badges += 'M ' }; if ($st.Snap) { $badges += 'S ' }; if ($st.Marquee) { $badges += 'Q ' } }

        # portada: primero la del gamelist (<image>/<thumbnail>), si no images\<key>-*
        $cover = $null
        if ($g.Image) {
            $abs = ([string]$g.Image).Trim() -replace '^\.[\\/]', '' -replace '/', '\'
            $full = if ([System.IO.Path]::IsPathRooted($abs)) { $abs } else { Join-Path $rom $abs }
            if (Test-Path -LiteralPath $full) { $cover = $full }
        }
        if (-not $cover) { $cover = Find-SCMCoverPath -Folder $key -Files $imgFiles }
        $img = if ($cover) { New-SCMBitmap -Path $cover -DecodeWidth 220 } else { $null }

        $r = New-Object SCMRow
        $r.Title = [string]$g.Name
        $r.Engine = 'win'; $r.EngineChip = '[win]'
        $r.MediaState = $state
        $r.StripeBrush = $script:Sem[$state]
        $r.CoverBrush = (New-SCMCoverBrush ($g.Name + '|' + $key))
        $r.CoverImage = $img
        $r.CoverVisible = $(if ($img) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
        $r.CoverStretch = $stretch
        $r.Badges = $badges.Trim()
        $r.Folder = $key
        # game sintetico: su FullPath-leaf = key -> el scraper nombra la media por key
        $r.Game = [PSCustomObject]@{ FullPath = (Join-Path $rom $key); Title = [string]$g.Name; DisplayTitle = [string]$g.Name; Engine = 'windows'; GameID = ''; SeriesName = ''; Platform = 'Windows'; Edition = ''; Language = '' }
        $r.Media = $st
        $rows.Add($r)
    }
    return $rows
}

function Update-SCMWinRows {
    $script:WinRows = @(Get-SCMWinRows)
    if ($script:WinList) {
        $sel = $script:WinList.SelectedIndex
        $script:WinList.ItemsSource = $script:WinRows
        if ($script:WinUI -and $script:WinUI.Count) {
            $tot = @($script:WinRows).Count
            $full = @($script:WinRows | Where-Object { $_.MediaState -eq 'Full' }).Count
            if ($script:WinUI.Status) { $script:WinUI.Status.Text = ("{0} juegos Windows   -   {1} con media completa" -f $tot, $full) }
        }
    }
}

function Update-SCMWinDetail {
    param($Row)
    if (-not $script:WinUI -or -not $script:WinUI.Count) { return }
    if ($null -eq $Row) { $script:WinUI.Title.Text = 'Selecciona un juego'; $script:WinUI.Cover.Source = $null; $script:WinUI.Media.Text = ''; return }
    $script:WinUI.Title.Text = [string]$Row.Title
    $big = $null
    $cover = Find-SCMCoverPath -Folder $Row.Folder -RomFolder (Get-SCMWindowsRomFolder)
    if (-not $cover -and $Row.CoverImage) { $script:WinUI.Cover.Source = $Row.CoverImage } else { if ($cover) { $big = New-SCMBitmap -Path $cover -DecodeWidth 480 }; $script:WinUI.Cover.Source = $big }
    $m = $Row.Media
    $mk = { param($b) if ($b) { '[x]' } else { '[ ]' } }
    if ($m) {
        # Mismos 6 tipos que el detalle ScummVM y el dialogo Descargar media.
        $script:WinUI.Media.Text = ("{0} Caratula   {1} Fanart    {2} Video`n{3} Marquee    {4} Snap      {5} Manual" -f (& $mk $m.Image), (& $mk $m.Fanart), (& $mk $m.Video), (& $mk $m.Marquee), (& $mk $m.Snap), (& $mk $m.Manual))
    } else { $script:WinUI.Media.Text = '(carpeta windows no encontrada)' }
}

function Show-SCMWindowsMedia {
    $rom = Get-SCMWindowsRomFolder
    if (-not (Test-Path $rom)) {
        [System.Windows.MessageBox]::Show(("Carpeta de juegos Windows no encontrada:`n{0}`n`nConfigura 'WindowsRomFolder' en config.json o crea la carpeta." -f $rom), 'Windows') | Out-Null
        return
    }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows - media" Width="1080" Height="720" MinWidth="880" MinHeight="560" WindowStartupLocation="CenterOwner"
        Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI" FontSize="13">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="@SLATE@" BorderBrush="@LINE@" BorderThickness="0,0,0,1" Padding="16,10">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="Juegos de Windows" FontFamily="Consolas" FontWeight="Bold" FontSize="15" Foreground="@ACCENT@" VerticalAlignment="Center"/>
        <TextBlock Text="  media desde las mismas fuentes que ScummVM" FontFamily="Consolas" FontSize="11" Foreground="@MUTED@" VerticalAlignment="Center" Margin="10,0,0,0"/>
      </StackPanel>
    </Border>
    <Grid Grid.Row="1" Margin="16,13,16,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="380"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="@SLATE@" BorderBrush="@LINE@" BorderThickness="1" CornerRadius="12">
        <Grid>
          <ListBox x:Name="winList" Background="Transparent" BorderThickness="0" Padding="6" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          <StackPanel x:Name="winEmpty" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False" Margin="20">
            <TextBlock Text="Aun no hay juegos de Windows enlazados." Foreground="@TEXT@" FontFamily="Consolas" FontSize="14" HorizontalAlignment="Center"/>
            <TextBlock Text="Pulsa 'Crear enlaces .lnk' (abajo) para anadir tus juegos nativos/remasters" Foreground="@MUTED@" FontFamily="Consolas" FontSize="12" HorizontalAlignment="Center" Margin="0,8,0,0" TextWrapping="Wrap" TextAlignment="Center"/>
            <TextBlock Text="(los que instalaste en la carpeta de ScummVM y no son juegos ScummVM)." Foreground="@MUTED@" FontFamily="Consolas" FontSize="12" HorizontalAlignment="Center" Margin="0,2,0,0" TextWrapping="Wrap" TextAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Border>
      <Border Grid.Column="1" Background="@SLATE@" BorderBrush="@LINE@" BorderThickness="1" CornerRadius="12" Margin="14,0,0,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16">
          <StackPanel>
            <Border Background="@RAISED@" CornerRadius="10" Padding="10">
              <Grid MinHeight="150"><Image x:Name="winCover" Stretch="Uniform" MaxHeight="360" HorizontalAlignment="Center"/></Grid>
            </Border>
            <TextBlock x:Name="winTitle" Margin="0,14,0,8" FontSize="16" FontWeight="Bold" TextWrapping="Wrap" Foreground="@TEXT@" Text="Selecciona un juego"/>
            <TextBlock Text="MEDIA" FontFamily="Consolas" FontSize="10.5" Margin="0,6,0,6" Foreground="@MUTED@"/>
            <TextBlock x:Name="winMedia" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" Foreground="@TEXT@"/>
            <TextBlock Text="ACCIONES" FontFamily="Consolas" FontSize="10.5" Margin="0,16,0,8" Foreground="@MUTED@"/>
            <WrapPanel x:Name="winVerbs"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>
    <Border Grid.Row="2" Background="@SLATE@" BorderBrush="@LINE@" BorderThickness="0,1,0,0" Padding="16,9">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="winStatus" VerticalAlignment="Center" Foreground="@MUTED@" FontSize="12.5" Text="..."/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="winLink" Content="Crear enlaces .lnk" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="12,7" Margin="0,0,8,0" Cursor="Hand"/>
          <Button x:Name="winRefresh" Content="Refrescar" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="12,7" Margin="0,0,8,0" Cursor="Hand"/>
          <Button x:Name="winClose" Content="Cerrar" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="12,7" Cursor="Hand"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $lst = $w.FindName('winList')
    # Reusa la plantilla de tarjeta / estilo de la ventana principal (mismos recursos).
    try {
        $lst.ItemTemplate = $window.FindResource('tmplCard')
        $lst.ItemsPanel = $window.FindResource('panelWrap')
        $lst.ItemContainerStyle = $window.FindResource('cardItem')
    } catch { }

    $script:WinUI = @{ Cover = $w.FindName('winCover'); Title = $w.FindName('winTitle'); Media = $w.FindName('winMedia'); Status = $w.FindName('winStatus'); Empty = $w.FindName('winEmpty') }

    # Barra de verbos (reusa las acciones context-aware: operan sobre el juego
    # Windows seleccionado y sobre roms\windows automaticamente).
    $verbs = @(
        @{ Text = 'Descargar media'; Go = $true;  Act = { Show-SCMScrapeDialog } },
        @{ Text = 'Buscar imagen';   Go = $true;  Act = { $r = Get-SCMSelectedRow; if ($r) { Show-SCMImageGrab $r } } },
        @{ Text = 'Bajar caratula';  Go = $false; Act = { Invoke-SCMCoverJob (Get-SCMSelectedRow) } },
        @{ Text = 'Bajar video 15s'; Go = $false; Act = { $r = Get-SCMSelectedRow; if ($r) { Show-SCMVideoGrab $r } } },
        @{ Text = 'Buscar manual';   Go = $false; Act = { $r = Get-SCMSelectedRow; if ($r) { Show-SCMManualGrab $r } } },
        @{ Text = 'Abrir carpeta';   Go = $false; Act = { $r = Get-SCMSelectedRow; if ($r -and (Test-Path (Get-SCMWindowsRomFolder))) { Start-Process explorer.exe (Get-SCMWindowsRomFolder) } } }
    )
    $panel = $w.FindName('winVerbs')
    foreach ($v in $verbs) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $v.Text
        try { $b.Style = $window.FindResource($(if ($v.Go) { 'VerbGo' } else { 'Verb' })) } catch { }
        $b.Width = 150
        $vt = $v.Text; $va = $v.Act
        $b.Add_Click({ Invoke-SCMSafe -Name $vt -Action $va }.GetNewClosure())
        [void]$panel.Children.Add($b)
    }

    $lst.Add_SelectionChanged({ Invoke-SCMSafe -Name 'Seleccionar (win)' -Action { Update-SCMWinDetail (Get-SCMSelectedRow) } })
    $w.FindName('winRefresh').Add_Click({ Invoke-SCMSafe -Name 'Refrescar (win)' -Action { Update-SCMWinRows } }.GetNewClosure())
    $w.FindName('winClose').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('winLink').Add_Click({ Invoke-SCMSafe -Name 'Crear enlaces' -Action {
        $prev = $script:WinMode; $script:WinMode = $false
        try { Show-SCMWindowsLinker } finally { $script:WinMode = $prev }
        Update-SCMWinRows
    } }.GetNewClosure())

    # Refresca badges al recuperar el foco (p. ej. tras una descarga).
    $w.Add_Activated({ if ($script:WinMode) { try { Update-SCMWinRows } catch { } } })

    # Activar contexto Windows y poblar.
    $script:WinMode = $true
    $script:WinList = $lst
    Update-SCMWinRows
    if (@($script:WinRows).Count -eq 0) { $script:WinUI.Empty.Visibility = 'Visible' }
    Update-SCMWinDetail $null

    $null = $w.ShowDialog()

    # Restaurar contexto ScummVM.
    $script:WinMode = $false
    $script:WinList = $null
    $script:WinUI = @{}
    try { Update-SCMData } catch { }
}

function Show-SCMWindowsLinker {
    # Busca en la carpeta de ScummVM las carpetas que NO son juegos ScummVM
    # gestionados y las ofrece para enlazar a roms\windows.
    $scummRom = $script:Config.Paths.RomFolder
    if (-not (Test-Path $scummRom)) { [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$scummRom", 'Windows Linker') | Out-Null; return }

    $winFolder = Get-SCMWindowsRomFolder
    Set-SCMStatus 'Buscando carpetas sin gestionar...'
    $db = @(); try { $db = @(Get-SCMDatabase) } catch { }
    $cands = @(Get-SCMWindowsCandidates -Games $db -RomFolder $scummRom)

    if ($cands.Count -eq 0) {
        [System.Windows.MessageBox]::Show(("No hay carpetas sin gestionar en:`n{0}`n`n(Todas son juegos ScummVM detectados o ya tienen .scummvm.)" -f $scummRom), 'Windows Linker') | Out-Null
        return
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Linker - juegos no-ScummVM" Width="640" Height="560" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Crea un acceso directo .lnk en roms\windows apuntando al .exe (sin mover datos)." Foreground="@MUTED@" FontSize="12" TextWrapping="Wrap"/>
    <TextBlock Grid.Row="1" x:Name="lblDest" Foreground="@ACCENT@" FontSize="12" Margin="0,6,0,10"/>
    <Border Grid.Row="2" Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1">
      <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="12"><StackPanel x:Name="list"/></ScrollViewer>
    </Border>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="bCancel" Content="Cancelar" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bCreate" Content="Crear .lnk" Width="120" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('lblDest').Text = ("Destino: {0}" -f $winFolder)
    $panel = $w.FindName('list')
    $textBrush = New-SCMBrush ($script:ThemeTokens['@TEXT@'])
    $mutedBrush = New-SCMBrush ($script:ThemeTokens['@MUTED@'])

    $map = @()
    foreach ($c in $cands) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = '0,4'
        $hint = ''
        try { if (($c.PSObject.Properties.Name -contains 'Guess') -and $c.Guess) { $hint = ("   [nombre parecido a ScummVM {0}, pero se enlaza como Windows]" -f $c.Guess) } } catch { }
        if ($null -ne $c.Exe) {
            $cb.Content = ("{0}    ->    {1}{2}" -f $c.Folder, (Split-Path $c.Exe -Leaf), $hint)
            $cb.IsChecked = $true
            $cb.Foreground = $textBrush
        }
        else {
            $cb.Content = ("{0}    (sin .exe localizable - se omite)" -f $c.Folder)
            $cb.IsChecked = $false
            $cb.IsEnabled = $false
            $cb.Foreground = $mutedBrush
        }
        [void]$panel.Children.Add($cb)
        $map += [PSCustomObject]@{ Cb = $cb; Cand = $c }
    }

    $w.FindName('bCancel').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bCreate').Add_Click({
        $chosen = @($map | Where-Object { $_.Cb.IsChecked -and ($null -ne $_.Cand.Exe) })
        if ($chosen.Count -eq 0) { [System.Windows.MessageBox]::Show('Marca al menos un juego con .exe.', 'Windows Linker') | Out-Null; return }

        if (-not (Test-Path $winFolder)) { New-Item -ItemType Directory -Path $winFolder -Force | Out-Null }
        $gamelistPath = Join-Path $winFolder 'gamelist.xml'
        if (Test-Path $gamelistPath) { Backup-SCMGamelist -Path $gamelistPath | Out-Null }
        $doc = Get-SCMGamelistDocument -Path $gamelistPath

        $ok = 0; $fail = 0
        foreach ($m in $chosen) {
            $c = $m.Cand
            try {
                $lnk = Join-Path $winFolder ("{0}.lnk" -f $c.Folder)
                New-SCMShortcut -LnkPath $lnk -TargetPath $c.Exe
                $rel = "./{0}.lnk" -f $c.Folder
                $dup = $null
                foreach ($g in $doc.SelectNodes('/gameList/game')) {
                    $pn = $g.SelectSingleNode('path')
                    if ($null -ne $pn -and (ConvertTo-SCMComparablePath $pn.InnerText) -eq (ConvertTo-SCMComparablePath $rel)) { $dup = $g; break }
                }
                if ($null -eq $dup) { New-SCMGamelistEntry -Doc $doc -Fields ([ordered]@{ path = $rel; name = $c.Folder }) | Out-Null }
                $ok++
            }
            catch { $fail++ }
        }
        try { Save-SCMGamelistDocument -Doc $doc -Path $gamelistPath } catch { }
        $w.Close()
        [System.Windows.MessageBox]::Show(("Creados {0} acceso(s) directo(s) .lnk en:`n{1}`n`nFallos: {2}`n`nRefresca el sistema 'windows' en RetroBat para verlos." -f $ok, $winFolder, $fail), 'Windows Linker') | Out-Null
        Set-SCMStatus ("Windows Linker: {0} enlace(s) creado(s)." -f $ok)
    }.GetNewClosure())
    $null = $w.ShowDialog()
}

function Show-SCMSync {
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Sync Frontend') | Out-Null; return }
    Set-SCMStatus 'Calculando el plan de sincronizacion...'
    # Igual que la consola: expandir con KnownGames.json (fallback por nombre)
    # para que "Aplicar NUEVOS" tambien cree los juegos que --detect no
    # reconocio pero cuyo nombre de carpeta casa con un ID conocido.
    $syncGames = @(Get-SCMDatabase)
    try {
        if (Get-Command Expand-SCMGamesWithFallback -ErrorAction SilentlyContinue) {
            $exp = Expand-SCMGamesWithFallback -Games $syncGames -RomFolder $rom
            if ($exp -and $exp.Games) { $syncGames = @($exp.Games) }
        }
    } catch { Write-SCMGuiError -Where 'Sync fallback KnownGames' -ErrorObj $_ | Out-Null }
    $plan = @(Get-SCMFrontendPlan -Games $syncGames -RomFolder $rom -Mode All)
    Update-SCMStatusBar
    $planRows = @($plan | ForEach-Object { [PSCustomObject]@{ Action = $_.Action; Old = $_.OldFolderName; New = $_.NewFolderName; Gamelist = $_.GamelistAction; Warn = ($_.Warnings -join '; ') } })
    $nC = @($plan | Where-Object { $_.Action -eq 'Create' }).Count
    $nR = @($plan | Where-Object { $_.Action -eq 'Rename' }).Count
    $nN = @($plan | Where-Object { $_.Action -eq 'NoChange' }).Count
    $nS = @($plan | Where-Object { $_.Action -eq 'Skip' }).Count

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sync Frontend - plan (dry-run)" Width="840" Height="600" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="summary" Grid.Row="0" Margin="0,0,0,10" FontSize="13" Foreground="@TEXT@"/>
    <Border Grid.Row="1" Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1">
      <ListView x:Name="grid" Background="Transparent" BorderThickness="0" Foreground="@TEXT@" Margin="4">
        <ListView.View>
          <GridView>
            <GridViewColumn Header="Accion" Width="80" DisplayMemberBinding="{Binding Action}"/>
            <GridViewColumn Header="Carpeta actual" Width="235" DisplayMemberBinding="{Binding Old}"/>
            <GridViewColumn Header="Nueva" Width="235" DisplayMemberBinding="{Binding New}"/>
            <GridViewColumn Header="Gamelist" Width="90" DisplayMemberBinding="{Binding Gamelist}"/>
            <GridViewColumn Header="Aviso" Width="150" DisplayMemberBinding="{Binding Warn}"/>
          </GridView>
        </ListView.View>
      </ListView>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="bClose" Content="Cerrar (dry-run)" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bNew" Content="Aplicar NUEVOS" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bFix" Content="Aplicar RENOMBRES" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="10,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bAll" Content="Aplicar TODO" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="10,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('summary').Text = ("Crear: {0}    Renombrar: {1}    Sin cambios: {2}    Omitidos: {3}" -f $nC, $nR, $nN, $nS)
    $w.FindName('grid').ItemsSource = $planRows
    $gl = Join-Path $rom 'gamelist.xml'
    # Todo el cuerpo envuelto en try/catch: si algo (incluido el refresco final)
    # falla, se registra y se avisa, pero NUNCA cierra la app.
    $apply = {
        param($items, [string]$label)
        try {
            $items = @($items)
            if ($items.Count -eq 0) { [System.Windows.MessageBox]::Show('No hay elementos que aplicar en esta categoria.', 'Sync') | Out-Null; return }
            $r = [System.Windows.MessageBox]::Show(("Se van a aplicar {0} cambios ({1}).`nSe hace copia de seguridad de gamelist.xml antes.`n`nContinuar?" -f $items.Count, $label), 'Confirmar cambios', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            $script:UI.Window.Cursor = 'Wait'
            try { Invoke-SCMFrontendSync -Plan $items -RomFolder $rom -GamelistPath $gl -Confirm:$false }
            finally { $script:UI.Window.Cursor = 'Arrow' }
            $w.Close()
            try { Update-SCMData } catch { Write-SCMGuiError -Where 'Sync refresh' -ErrorObj $_ | Out-Null }
            Set-SCMStatus ("Sync aplicado: {0}" -f $label)
        } catch {
            $m = Write-SCMGuiError -Where "Sync aplicar ($label)" -ErrorObj $_
            [System.Windows.MessageBox]::Show(("Fallo al aplicar Sync:`n`n{0}`n`n(Detalle en Logs\gui_error.log)" -f $m), 'Error en Sync') | Out-Null
        }
    }
    $w.FindName('bClose').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bNew').Add_Click({ try { & $apply (@($plan | Where-Object { $_.Action -eq 'Create' })) 'nuevos' } catch { Write-SCMGuiError -Where 'bNew' -ErrorObj $_ | Out-Null } }.GetNewClosure())
    $w.FindName('bFix').Add_Click({ try { & $apply (@($plan | Where-Object { $_.Action -eq 'Rename' })) 'renombres' } catch { Write-SCMGuiError -Where 'bFix' -ErrorObj $_ | Out-Null } }.GetNewClosure())
    $w.FindName('bAll').Add_Click({ try { & $apply (@($plan | Where-Object { $_.Action -in 'Create', 'Rename' })) 'todo' } catch { Write-SCMGuiError -Where 'bAll' -ErrorObj $_ | Out-Null } }.GetNewClosure())
    $null = $w.ShowDialog()
}

function Show-SCMSettings {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ajustes" Width="660" Height="640" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <DockPanel Margin="20">
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="bCancel" Content="Cancelar" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bSave" Content="Guardar" Width="100" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="0,0,10,0">
        <TextBlock Text="RUTAS" FontFamily="Consolas" FontSize="11" Foreground="@ACCENT@" Margin="0,0,0,8"/>
        <TextBlock Text="Ejecutable ScummVM" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <Grid Margin="0,0,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox Grid.Column="0" x:Name="tScummvm" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          <Button Grid.Column="1" x:Name="bScummvm" Content="..." Width="36" Margin="6,0,0,0" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Cursor="Hand"/></Grid>
        <TextBlock Text="Carpeta de ROMs" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <Grid Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox Grid.Column="0" x:Name="tRom" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          <Button Grid.Column="1" x:Name="bRom" Content="..." Width="36" Margin="6,0,0,0" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Cursor="Hand"/></Grid>

        <TextBlock Text="SCRAPERS DE MEDIA" FontFamily="Consolas" FontSize="11" Foreground="@ACCENT@" Margin="0,0,0,8"/>
        <TextBlock Text="SteamGridDB key (caratula / fanart / marquee)" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <TextBox x:Name="tKey" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
        <TextBlock x:Name="tKeyHint" FontSize="11" Foreground="@MUTED@" Margin="0,3,0,12" TextWrapping="Wrap"/>

        <TextBlock Text="ScreenScraper.fr  -  la unica con VIDEO, SNAP y MANUAL" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3" TextWrapping="Wrap"/>
        <Grid Margin="0,0,0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Margin="0,0,5,0">
            <TextBlock Text="Dev ID" FontSize="10" Foreground="@MUTED@"/>
            <TextBox x:Name="tSsDevId" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="5,0,0,0">
            <TextBlock Text="Dev Password" FontSize="10" Foreground="@MUTED@"/>
            <TextBox x:Name="tSsDevPass" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          </StackPanel></Grid>
        <Grid Margin="0,0,0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Margin="0,0,5,0">
            <TextBlock Text="Usuario" FontSize="10" Foreground="@MUTED@"/>
            <TextBox x:Name="tSsUser" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="5,0,0,0">
            <TextBlock Text="Password" FontSize="10" Foreground="@MUTED@"/>
            <TextBox x:Name="tSsPass" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          </StackPanel></Grid>
        <TextBlock Text="Cuenta gratuita en screenscraper.fr (el Dev ID/Password se pide en su foro)." FontSize="11" Foreground="@MUTED@" Margin="0,0,0,12" TextWrapping="Wrap"/>

        <TextBlock Text="TheGamesDB API key (fallback de artwork/snap)" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <TextBox x:Name="tTgdb" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
        <TextBlock Text="Key publica gratuita (thegamesdb.net). Libretro se usa siempre, sin credenciales." FontSize="11" Foreground="@MUTED@" Margin="0,3,0,16" TextWrapping="Wrap"/>

        <TextBlock Text="MobyGames API key (portada/captura de aventuras clasicas)" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <TextBox x:Name="tMoby" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
        <TextBlock Text="Key gratuita en mobygames.com/info/api - la mejor cobertura para aventuras (limite 1 peticion/seg)." FontSize="11" Foreground="@MUTED@" Margin="0,3,0,16" TextWrapping="Wrap"/>

        <TextBlock Text="GiantBomb API key (NO usable: su API esta tras Cloudflare)" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <TextBox x:Name="tGb" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
        <TextBlock Text="Cloudflare bloquea la API de GiantBomb desde clientes que no son navegador (403). Se guarda la key pero no se usa." FontSize="11" Foreground="@MUTED@" Margin="0,3,0,16" TextWrapping="Wrap"/>

        <TextBlock Text="IGDB - Client ID + Client Secret (portada/screenshot/artwork)" FontSize="11" Foreground="@MUTED@" Margin="0,0,0,3"/>
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBox Grid.Column="0" x:Name="tIgdbId" Margin="0,0,4,0" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
          <TextBox Grid.Column="1" x:Name="tIgdbSecret" Margin="4,0,0,0" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
        </Grid>
        <TextBlock Text="Crea una app gratis en dev.twitch.tv/console/apps (IGDB usa OAuth de Twitch). Sin Cloudflare." FontSize="11" Foreground="@MUTED@" Margin="0,3,0,16" TextWrapping="Wrap"/>

        <TextBlock Text="APARIENCIA" FontFamily="Consolas" FontSize="11" Foreground="@ACCENT@" Margin="0,0,0,8"/>
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Margin="0,0,5,0">
            <TextBlock Text="Tema" FontSize="11" Foreground="@MUTED@"/>
            <ComboBox x:Name="cTheme" Padding="6,4"><ComboBoxItem>Dark</ComboBoxItem><ComboBoxItem>Light</ComboBoxItem></ComboBox>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="5,0,0,0">
            <TextBlock Text="Acento" FontSize="11" Foreground="@MUTED@"/>
            <ComboBox x:Name="cAccent" Padding="6,4"><ComboBoxItem>Gold</ComboBoxItem><ComboBoxItem>Cyan</ComboBoxItem><ComboBoxItem>Green</ComboBoxItem><ComboBoxItem>Magenta</ComboBoxItem><ComboBoxItem>Blue</ComboBoxItem></ComboBox>
          </StackPanel></Grid>
        <TextBlock Text="Caratulas en galeria" FontSize="11" Foreground="@MUTED@" Margin="0,12,0,0"/>
        <ComboBox x:Name="cCoverFit" Padding="6,4" HorizontalAlignment="Left" Width="240">
          <ComboBoxItem Content="Entera (sin recortar)" Tag="Fit"/>
          <ComboBoxItem Content="Rellenar marco (recorta)" Tag="Fill"/>
        </ComboBox>
        <CheckBox x:Name="chkUnicode" Content="Cajas Unicode en la consola (TUI)" Foreground="@TEXT@" Margin="0,12,0,0"/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $tScummvm = $w.FindName('tScummvm'); $tScummvm.Text = [string]$script:Config.Paths.ScummVM
    $tRom = $w.FindName('tRom'); $tRom.Text = [string]$script:Config.Paths.RomFolder
    $tKey = $w.FindName('tKey')
    $hasKey = $false
    try { if ($script:Config.Preferences.PSObject.Properties.Name -contains 'ApiKeys' -and $script:Config.Preferences.ApiKeys.PSObject.Properties.Name -contains 'SteamGridDB' -and -not [string]::IsNullOrWhiteSpace($script:Config.Preferences.ApiKeys.SteamGridDB)) { $hasKey = $true } } catch { }
    $w.FindName('tKeyHint').Text = if ($hasKey) { 'Ya hay una key guardada. Dejalo vacio para conservarla; escribe una nueva para cambiarla.' } else { 'Registrate gratis en steamgriddb.com para auto-descargar caratulas.' }

    # Scrapers: prefill desde config (creds locales del usuario).
    $ssGet = { param($n) try { if ($script:Config.Preferences.Scrapers.ScreenScraper.PSObject.Properties.Name -contains $n) { [string]$script:Config.Preferences.Scrapers.ScreenScraper.$n } else { '' } } catch { '' } }
    $w.FindName('tSsDevId').Text = & $ssGet 'DevId'
    $w.FindName('tSsDevPass').Text = & $ssGet 'DevPassword'
    $w.FindName('tSsUser').Text = & $ssGet 'User'
    $w.FindName('tSsPass').Text = & $ssGet 'Password'
    try { $w.FindName('tTgdb').Text = [string]$script:Config.Preferences.Scrapers.TheGamesDB.ApiKey } catch { $w.FindName('tTgdb').Text = '' }
    try { $w.FindName('tMoby').Text = [string]$script:Config.Preferences.Scrapers.MobyGames.ApiKey } catch { $w.FindName('tMoby').Text = '' }
    try { $w.FindName('tGb').Text = [string]$script:Config.Preferences.Scrapers.GiantBomb.ApiKey } catch { $w.FindName('tGb').Text = '' }
    try { $w.FindName('tIgdbId').Text = [string]$script:Config.Preferences.Scrapers.IGDB.ClientId } catch { $w.FindName('tIgdbId').Text = '' }
    try { $w.FindName('tIgdbSecret').Text = [string]$script:Config.Preferences.Scrapers.IGDB.ClientSecret } catch { $w.FindName('tIgdbSecret').Text = '' }

    $cTheme = $w.FindName('cTheme'); $cAccent = $w.FindName('cAccent')
    for ($i = 0; $i -lt $cTheme.Items.Count; $i++) { if ([string]$cTheme.Items[$i].Content -eq $script:ThemeMode) { $cTheme.SelectedIndex = $i } }
    for ($i = 0; $i -lt $cAccent.Items.Count; $i++) { if ([string]$cAccent.Items[$i].Content -eq $script:ThemeAccent) { $cAccent.SelectedIndex = $i } }
    if ($cTheme.SelectedIndex -lt 0) { $cTheme.SelectedIndex = 0 }
    if ($cAccent.SelectedIndex -lt 0) { $cAccent.SelectedIndex = 0 }

    $chkUnicode = $w.FindName('chkUnicode')
    $uni = $true; try { if ($script:Config.Preferences.UI.PSObject.Properties.Name -contains 'Unicode') { $uni = [bool]$script:Config.Preferences.UI.Unicode } } catch { }
    $chkUnicode.IsChecked = $uni

    $cCoverFit = $w.FindName('cCoverFit')
    $cf = 'Fit'; try { if ([string]$script:Config.Preferences.UI.CoverFit -eq 'Fill') { $cf = 'Fill' } } catch { }
    for ($i = 0; $i -lt $cCoverFit.Items.Count; $i++) { if ([string]$cCoverFit.Items[$i].Tag -eq $cf) { $cCoverFit.SelectedIndex = $i } }
    if ($cCoverFit.SelectedIndex -lt 0) { $cCoverFit.SelectedIndex = 0 }

    $w.FindName('bScummvm').Add_Click({ $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = 'scummvm.exe|scummvm.exe|Ejecutables (*.exe)|*.exe'; if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tScummvm.Text = $dlg.FileName } }.GetNewClosure())
    $w.FindName('bRom').Add_Click({ $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tRom.Text = $dlg.SelectedPath } }.GetNewClosure())
    $w.FindName('bCancel').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bSave').Add_Click({
        try {
            Update-SCMConfigPath -Name 'ScummVM' -Value $tScummvm.Text
            Update-SCMConfigPath -Name 'RomFolder' -Value $tRom.Text
            $cfg = Get-SCMConfig
            if ($cfg.Preferences.PSObject.Properties.Name -notcontains 'UI') { $cfg.Preferences | Add-Member -NotePropertyName 'UI' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            $ui = $cfg.Preferences.UI
            foreach ($pn in @('Unicode', 'Accent', 'Theme', 'GuiAccent', 'CoverFit')) { if ($ui.PSObject.Properties.Name -notcontains $pn) { $ui | Add-Member -NotePropertyName $pn -NotePropertyValue '' -Force } }
            $ui.Unicode = [bool]$chkUnicode.IsChecked
            $ui.Theme = [string]$cTheme.SelectedItem.Content
            $ui.GuiAccent = [string]$cAccent.SelectedItem.Content
            $ui.CoverFit = [string]$cCoverFit.SelectedItem.Tag
            if (-not $ui.Accent) { $ui.Accent = 'Cyan' }
            $newKey = $tKey.Text
            if (-not [string]::IsNullOrWhiteSpace($newKey)) {
                if ($cfg.Preferences.PSObject.Properties.Name -notcontains 'ApiKeys') { $cfg.Preferences | Add-Member -NotePropertyName 'ApiKeys' -NotePropertyValue ([PSCustomObject]@{ SteamGridDB = '' }) -Force }
                $cfg.Preferences.ApiKeys.SteamGridDB = $newKey.Trim()
            }
            # Scrapers (ScreenScraper + TheGamesDB)
            if ($cfg.Preferences.PSObject.Properties.Name -notcontains 'Scrapers') { $cfg.Preferences | Add-Member -NotePropertyName 'Scrapers' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            $scr = $cfg.Preferences.Scrapers
            if ($scr.PSObject.Properties.Name -notcontains 'ScreenScraper') { $scr | Add-Member -NotePropertyName 'ScreenScraper' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            if ($scr.PSObject.Properties.Name -notcontains 'TheGamesDB') { $scr | Add-Member -NotePropertyName 'TheGamesDB' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            $ssO = $scr.ScreenScraper
            foreach ($pn in @('DevId', 'DevPassword', 'User', 'Password')) { if ($ssO.PSObject.Properties.Name -notcontains $pn) { $ssO | Add-Member -NotePropertyName $pn -NotePropertyValue '' -Force } }
            $ssO.DevId = $w.FindName('tSsDevId').Text.Trim()
            $ssO.DevPassword = $w.FindName('tSsDevPass').Text.Trim()
            $ssO.User = $w.FindName('tSsUser').Text.Trim()
            $ssO.Password = $w.FindName('tSsPass').Text.Trim()
            if ($scr.TheGamesDB.PSObject.Properties.Name -notcontains 'ApiKey') { $scr.TheGamesDB | Add-Member -NotePropertyName 'ApiKey' -NotePropertyValue '' -Force }
            $scr.TheGamesDB.ApiKey = $w.FindName('tTgdb').Text.Trim()
            if ($scr.PSObject.Properties.Name -notcontains 'MobyGames') { $scr | Add-Member -NotePropertyName 'MobyGames' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            if ($scr.MobyGames.PSObject.Properties.Name -notcontains 'ApiKey') { $scr.MobyGames | Add-Member -NotePropertyName 'ApiKey' -NotePropertyValue '' -Force }
            $scr.MobyGames.ApiKey = $w.FindName('tMoby').Text.Trim()
            if ($scr.PSObject.Properties.Name -notcontains 'GiantBomb') { $scr | Add-Member -NotePropertyName 'GiantBomb' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            if ($scr.GiantBomb.PSObject.Properties.Name -notcontains 'ApiKey') { $scr.GiantBomb | Add-Member -NotePropertyName 'ApiKey' -NotePropertyValue '' -Force }
            $scr.GiantBomb.ApiKey = $w.FindName('tGb').Text.Trim()
            if ($scr.PSObject.Properties.Name -notcontains 'IGDB') { $scr | Add-Member -NotePropertyName 'IGDB' -NotePropertyValue ([PSCustomObject]@{}) -Force }
            foreach ($pn in @('ClientId', 'ClientSecret')) { if ($scr.IGDB.PSObject.Properties.Name -notcontains $pn) { $scr.IGDB | Add-Member -NotePropertyName $pn -NotePropertyValue '' -Force } }
            $scr.IGDB.ClientId = $w.FindName('tIgdbId').Text.Trim()
            $scr.IGDB.ClientSecret = $w.FindName('tIgdbSecret').Text.Trim()
            Set-SCMConfig -Config $cfg
            $script:Config = Get-SCMConfig
            Set-SCMTheme -Mode ([string]$cTheme.SelectedItem.Content) -AccentName ([string]$cAccent.SelectedItem.Content)
            Set-SCMViewMode $script:ViewMode
            $w.Close()
            Update-SCMData
            Start-SCMWatcher
            Set-SCMStatus 'Ajustes guardados.'
        } catch { [System.Windows.MessageBox]::Show("$_", 'Error al guardar') | Out-Null }
    }.GetNewClosure())
    $null = $w.ShowDialog()
}

function Show-SCMScrapeDialog {
    Write-SCMTrace 'Show-SCMScrapeDialog: ENTRA'
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { Write-SCMTrace "  return: RomFolder no existe ($rom)"; [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Descargar media') | Out-Null; return }
    if (@(Get-SCMActiveRows).Count -eq 0) { Write-SCMTrace '  return: filas vacias'; [System.Windows.MessageBox]::Show('No hay juegos que mostrar. Escanea/abre la coleccion primero.', 'Descargar media') | Out-Null; return }

    # Fuentes activas (para informar al usuario).
    $sgdb = -not [string]::IsNullOrWhiteSpace((Get-SCMApiKey))
    $ss = ($null -ne (Get-SCMScreenScraperCreds))
    $tgdb = -not [string]::IsNullOrWhiteSpace((Get-SCMTgdbKey))
    $moby = -not [string]::IsNullOrWhiteSpace((Get-SCMMobyKey))
    $gb = -not [string]::IsNullOrWhiteSpace((Get-SCMGiantBombKey))
    $igdb = ($null -ne (Get-SCMIgdbCreds))
    $active = @()
    if ($sgdb) { $active += 'SteamGridDB' }
    if ($ss) { $active += 'ScreenScraper' }
    if ($igdb) { $active += 'IGDB' }
    if ($moby) { $active += 'MobyGames' }
    if ($tgdb) { $active += 'TheGamesDB' }
    $active += 'Libretro'
    $active += 'archive.org (manuales)'
    $active += 'DuckDuckGo (fallback)'
    $inactive = @()
    if (-not $ss) { $inactive += 'ScreenScraper (video/snap/manual)' }
    if (-not $igdb) { $inactive += 'IGDB (portada/snap/artwork)' }
    if (-not $moby) { $inactive += 'MobyGames (portada/snap de aventuras)' }
    if (-not $tgdb) { $inactive += 'TheGamesDB' }
    # GiantBomb esta bloqueado por Cloudflare: no es usable desde la app.
    if ($gb) { $inactive += 'GiantBomb (key puesta, pero bloqueado por Cloudflare)' }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Descargar media" Width="520" Height="520" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI" ResizeMode="NoResize">
  <StackPanel Margin="22">
    <TextBlock Text="Que media descargar" FontWeight="Bold" FontSize="15" Foreground="@ACCENT@"/>
    <TextBlock Text="Se prueba cada fuente en orden; si una no lo tiene, pasa a la siguiente." Foreground="@MUTED@" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,12"/>
    <UniformGrid Columns="2">
      <CheckBox x:Name="cbImage" Content="Caratula" Foreground="@TEXT@" Margin="0,4"/>
      <CheckBox x:Name="cbFanart" Content="Fanart" Foreground="@TEXT@" Margin="0,4"/>
      <CheckBox x:Name="cbVideo" Content="Video" Foreground="@TEXT@" Margin="0,4"/>
      <CheckBox x:Name="cbMarquee" Content="Marquee" Foreground="@TEXT@" Margin="0,4"/>
      <CheckBox x:Name="cbSnap" Content="Snap" Foreground="@TEXT@" Margin="0,4"/>
      <CheckBox x:Name="cbManual" Content="Manual" Foreground="@TEXT@" Margin="0,4"/>
    </UniformGrid>
    <TextBlock Text="La miniatura se genera automaticamente de la caratula." Foreground="@MUTED@" FontSize="11" Margin="0,6,0,0"/>
    <Border Height="1" Background="@LINE@" Margin="0,14"/>
    <CheckBox x:Name="chkOnly" Content="Solo lo que falta (no re-descargar lo que ya hay)" Foreground="@TEXT@" IsChecked="True" Margin="0,0,0,10"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
      <RadioButton x:Name="rbAll" GroupName="scope" Content="Todos los juegos" Foreground="@TEXT@" IsChecked="True" Margin="0,0,20,0"/>
      <RadioButton x:Name="rbSel" GroupName="scope" Content="Solo el seleccionado" Foreground="@TEXT@"/>
    </StackPanel>
    <Border Background="@SLATE@" CornerRadius="8" Padding="12" Margin="0,10,0,0">
      <StackPanel>
        <TextBlock x:Name="tActive" FontSize="12" Foreground="@TEXT@" TextWrapping="Wrap"/>
        <TextBlock x:Name="tInactive" FontSize="11" Foreground="@MUTED@" TextWrapping="Wrap" Margin="0,6,0,0"/>
      </StackPanel>
    </Border>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="bCancel" Content="Cancelar" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bGo" Content="Descargar" Width="120" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('tActive').Text = ("Fuentes activas: {0}" -f ($active -join ', '))
    $w.FindName('tInactive').Text = if ($inactive.Count -gt 0) { ("Anade credenciales en Ajustes para activar: {0}" -f ($inactive -join ', ')) } else { 'Todas las fuentes configuradas.' }

    # Estado compartido por REFERENCIA (hashtable): un closure GetNewClosure corre
    # en su propio scope, asi que "$script:X = ..." dentro del handler NO llega al
    # exterior. Mutar un hashtable capturado SI es visible (mismo objeto).
    $dlg = @{ Go = $false; Games = @(); Types = @(); Only = $true }

    # Premarcado inteligente: refleja lo que le FALTA al juego seleccionado.
    # "Todos los juegos" -> marca todos los tipos (luego solo baja lo que falte).
    $selRow = Get-SCMSelectedRow
    $applyChecks = {
        param([bool]$All)
        $m = $null; if ($selRow) { $m = $selRow.Media }
        $map = @{ cbImage = 'Image'; cbFanart = 'Fanart'; cbVideo = 'Video'; cbMarquee = 'Marquee'; cbSnap = 'Snap'; cbManual = 'Manual' }
        foreach ($cb in $map.Keys) {
            if ($All -or -not $m) { $w.FindName($cb).IsChecked = $true }
            else { $p = $map[$cb]; $w.FindName($cb).IsChecked = (-not [bool]$m.$p) }
        }
    }
    if ($selRow) { $w.FindName('rbSel').IsChecked = $true; & $applyChecks $false }
    else { $w.FindName('rbAll').IsChecked = $true; & $applyChecks $true }
    $w.FindName('rbAll').Add_Checked({ & $applyChecks $true }.GetNewClosure())
    $w.FindName('rbSel').Add_Checked({ & $applyChecks $false }.GetNewClosure())

    $w.FindName('bCancel').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bGo').Add_Click({ Invoke-SCMSafe -Name 'Descargar media (aceptar)' -Action {
        Write-SCMTrace 'bGo: click Descargar'
        $types = @()
        if ($w.FindName('cbImage').IsChecked) { $types += 'image' }
        if ($w.FindName('cbSnap').IsChecked) { $types += 'snap' }
        if ($w.FindName('cbVideo').IsChecked) { $types += 'video' }
        if ($w.FindName('cbMarquee').IsChecked) { $types += 'marquee' }
        if ($w.FindName('cbFanart').IsChecked) { $types += 'fanart' }
        if ($w.FindName('cbManual').IsChecked) { $types += 'manual' }
        if ($types.Count -eq 0) { [System.Windows.MessageBox]::Show('Marca al menos un tipo de media.', 'Descargar media') | Out-Null; return }

        if ($w.FindName('rbSel').IsChecked) {
            $sel = Get-SCMSelectedRow
            if ($null -eq $sel) { [System.Windows.MessageBox]::Show('No hay ningun juego seleccionado.', 'Descargar media') | Out-Null; return }
            $dlg.Games = @($sel.Game)
        } else {
            $dlg.Games = @(Get-SCMActiveRows | ForEach-Object { $_.Game })
        }
        $dlg.Types = $types
        $dlg.Only = [bool]$w.FindName('chkOnly').IsChecked
        $dlg.Go = $true
        Write-SCMTrace ("bGo: Go={0} types=[{1}] juegos={2} soloFalta={3}" -f $dlg.Go, ($types -join ','), @($dlg.Games).Count, $dlg.Only)
        $w.Close()
    } }.GetNewClosure())
    $null = $w.ShowDialog()

    Write-SCMTrace ("Show-SCMScrapeDialog: dialog cerrado, Go={0}" -f $dlg.Go)
    if ($dlg.Go) { Invoke-SCMScrapeMediaJob -Games $dlg.Games -Types $dlg.Types -OnlyMissing $dlg.Only }
}

# =====================================================================
#  Buscar media a mano (DuckDuckGo Images + yt-dlp) y colocarla
# =====================================================================

# Coloca una imagen (por URL) como media del juego. Funcion con NOMBRE a
# proposito: los handlers de clic la llaman directamente en vez de invocar un
# scriptblock capturado (& $sb desde un closure anidado pierde la captura y da
# "la expresion que sigue a '&' produjo un objeto no valido").
function Invoke-SCMPlaceGrabbedImage {
    param([string]$Url, [string]$Type, [string]$Folder, [string]$Rom, $Status, $Win)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    try { if ($Win) { $Win.Cursor = 'Wait' } } catch { }
    $res = $null
    try { $res = Save-SCMGrabbedImage -Url $Url -Type $Type -FolderName $Folder -RomFolder $Rom } catch { Write-SCMGuiError -Where 'Colocar imagen' -ErrorObj $_ | Out-Null }
    try { if ($Win) { $Win.Cursor = 'Arrow' } } catch { }
    if ($res -and $res.Ok) {
        if ($Status) { $Status.Text = ("Colocada: {0}   (gamelist actualizado)" -f (Split-Path $res.Dest -Leaf)) }
        try { Update-SCMActive } catch { }
    } else {
        if ($Status) { $Status.Text = 'No se pudo descargar esa imagen. Prueba con otra o pega una URL directa.' }
    }
}

function Show-SCMImageGrab {
    param($Row)
    if ($null -eq $Row) { return }
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Buscar imagen') | Out-Null; return }
    $folder = [string]$Row.Folder
    $title = [string]$Row.Title

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Buscar imagen" Width="760" Height="650" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="dGame" FontSize="15" FontWeight="Bold" Foreground="@ACCENT@" TextWrapping="Wrap"/>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,10">
      <TextBlock Text="Tipo:" VerticalAlignment="Center" Foreground="@MUTED@" Margin="0,0,6,0"/>
      <ComboBox x:Name="cType" Width="130" Padding="6,3"><ComboBoxItem>Portada</ComboBoxItem><ComboBoxItem>Fanart</ComboBoxItem><ComboBoxItem>Snap</ComboBoxItem><ComboBoxItem>Marquee</ComboBoxItem></ComboBox>
      <TextBox x:Name="tQuery" Width="360" Margin="10,0,6,0" Padding="6,4" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
      <Button x:Name="bSearch" Content="Buscar" Width="90" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
    </StackPanel>
    <Border Grid.Row="2" Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1">
      <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="8"><WrapPanel x:Name="grid"/></ScrollViewer>
    </Border>
    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,10,0,0">
      <TextBlock Text="o pega URL de imagen:" VerticalAlignment="Center" Foreground="@MUTED@" Margin="0,0,6,0"/>
      <TextBox x:Name="tUrl" Width="470" Padding="6,4" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
      <Button x:Name="bUse" Content="Usar" Width="80" Margin="6,0,0,0" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
    </StackPanel>
    <DockPanel Grid.Row="4" Margin="0,12,0,0">
      <Button x:Name="bClose" Content="Cerrar" DockPanel.Dock="Right" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
      <TextBlock x:Name="tStatus" VerticalAlignment="Center" Foreground="@MUTED@" TextWrapping="Wrap"/>
    </DockPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('dGame').Text = $title
    $cType = $w.FindName('cType'); $cType.SelectedIndex = 0
    $tQuery = $w.FindName('tQuery')
    $grid = $w.FindName('grid')
    $tStatus = $w.FindName('tStatus')
    $typeMap = @{ 'Portada' = 'image'; 'Fanart' = 'fanart'; 'Snap' = 'snap'; 'Marquee' = 'marquee' }

    # Handler de clic en imagen SIN captura: lee TODO el contexto de $snd.Tag.
    # (Crear un handler anidado que capture variables da error de closure:
    #  "la expresion que sigue a '&' produjo un objeto no valido" / matriz nula.)
    $imgClick = {
        param($snd, $e)
        try {
            $c = $snd.Tag
            $tt = $c.TypeMap[[string]$c.CType.SelectedItem.Content]
            Invoke-SCMPlaceGrabbedImage -Url ([string]$c.Url) -Type $tt -Folder ([string]$c.Folder) -Rom ([string]$c.Rom) -Status $c.Status -Win $c.Win
        } catch { Write-SCMGuiError -Where 'Colocar imagen (clic)' -ErrorObj $_ | Out-Null }
    }

    $setQuery = {
        $sel = [string]$cType.SelectedItem.Content
        $slot = Get-SCMMediaSlot -Type $typeMap[$sel]
        $tQuery.Text = ("{0} {1}" -f $title, $slot.Hint)
    }.GetNewClosure()
    & $setQuery
    $cType.Add_SelectionChanged($setQuery)

    $w.FindName('bSearch').Add_Click({
        $q = $tQuery.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($q)) { return }
        $grid.Children.Clear(); $tStatus.Text = 'Buscando en DuckDuckGo...'; $w.Cursor = 'Wait'
        $imgs = @(Search-SCMDdgImages -Query $q -Max 24)
        $w.Cursor = 'Arrow'
        foreach ($img in $imgs) {
            try {
                $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                $bi.BeginInit(); $bi.UriSource = [uri]$img.Thumb; $bi.EndInit()
                $ic = New-Object System.Windows.Controls.Image
                $ic.Source = $bi; $ic.Width = 150; $ic.Height = 150; $ic.Stretch = 'Uniform'; $ic.Margin = '6'; $ic.Cursor = 'Hand'
                $ic.ToolTip = ("{0}x{1}" -f $img.Width, $img.Height)
                # Todo el contexto en Tag -> el handler no necesita capturar nada.
                $ic.Tag = @{ Url = [string]$img.Image; Folder = $folder; Rom = $rom; Status = $tStatus; Win = $w; CType = $cType; TypeMap = $typeMap }
                $ic.Add_MouseLeftButtonUp($imgClick)
                [void]$grid.Children.Add($ic)
            }
            catch { }
        }
        $tStatus.Text = if ($grid.Children.Count -gt 0) { ("{0} resultados. Haz clic en la imagen que quieras." -f $grid.Children.Count) } else { 'Sin resultados. Afina el texto o pega una URL directa.' }
    }.GetNewClosure())

    $w.FindName('bUse').Add_Click({ try { $tt = $typeMap[[string]$cType.SelectedItem.Content]; Invoke-SCMPlaceGrabbedImage -Url ($w.FindName('tUrl').Text.Trim()) -Type $tt -Folder $folder -Rom $rom -Status $tStatus -Win $w } catch { Write-SCMGuiError -Where 'Usar URL imagen' -ErrorObj $_ | Out-Null } }.GetNewClosure())
    $w.FindName('bClose').Add_Click({ $w.Close() }.GetNewClosure())
    $null = $w.ShowDialog()
}

function Show-SCMVideoGrab {
    param($Row)
    Write-SCMTrace 'Show-SCMVideoGrab: ENTRA'
    if ($null -eq $Row) { Write-SCMTrace '  return: Row null'; return }
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { Write-SCMTrace '  return: RomFolder no existe'; [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Bajar video') | Out-Null; return }
    if ($script:Job) { Write-SCMTrace '  return: ya hay job'; [System.Windows.MessageBox]::Show('Ya hay una tarea en curso. Espera a que termine.', 'Bajar video') | Out-Null; return }
    $hasYt = $false; try { $hasYt = [bool](Test-SCMYtDlp) } catch { Write-SCMTrace "  Test-SCMYtDlp EXCEPCION: $($_.Exception.Message)" }
    if (-not $hasYt) { Write-SCMTrace '  return: yt-dlp no encontrado'; [System.Windows.MessageBox]::Show('yt-dlp no esta en el PATH. Instalalo para poder bajar videos.', 'Bajar video') | Out-Null; return }
    $hasFf = $false; try { $hasFf = [bool](Test-SCMFfmpeg) } catch { Write-SCMTrace "  Test-SCMFfmpeg EXCEPCION: $($_.Exception.Message)" }
    if (-not $hasFf) { Write-SCMTrace '  return: ffmpeg no encontrado'; [System.Windows.MessageBox]::Show('ffmpeg no esta en el PATH (necesario para recortar el clip).', 'Bajar video') | Out-Null; return }
    $folder = [string]$Row.Folder
    $title = [string]$Row.Title

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Bajar video (clip corto)" Width="560" Height="330" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI" ResizeMode="NoResize">
  <StackPanel Margin="20">
    <TextBlock x:Name="dGame" FontSize="15" FontWeight="Bold" Foreground="@ACCENT@" TextWrapping="Wrap"/>
    <TextBlock Text="Busca en YouTube por texto, o pega una URL de YouTube. Se descarga y recorta un clip corto." Foreground="@MUTED@" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,12"/>
    <TextBlock Text="Busqueda o URL de YouTube" Foreground="@MUTED@" FontSize="11" Margin="0,0,0,3"/>
    <TextBox x:Name="tQuery" Padding="6,6" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
      <TextBlock Text="Segundos:" VerticalAlignment="Center" Foreground="@MUTED@" Margin="0,0,6,0"/>
      <TextBox x:Name="tSecs" Width="60" Text="15" Padding="6,4" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
      <TextBlock Text="(maximo 30)" VerticalAlignment="Center" Foreground="@MUTED@" FontSize="11" Margin="8,0,0,0"/>
    </StackPanel>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="bCancel" Content="Cancelar" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bGo" Content="Descargar clip" Width="140" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('dGame').Text = $title
    $w.FindName('tQuery').Text = ("{0} gameplay" -f $title)
    # Estado por referencia (ver nota en Show-SCMScrapeDialog): GetNewClosure +
    # "$script:X = ..." no llega al exterior; un hashtable mutado si.
    $vid = @{ Go = $false; Source = ''; Secs = 15 }
    $w.FindName('bCancel').Add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('bGo').Add_Click({ Invoke-SCMSafe -Name 'Bajar video (aceptar)' -Action {
        Write-SCMTrace 'video bGo: click Descargar clip'
        $q = $w.FindName('tQuery').Text.Trim()
        if ([string]::IsNullOrWhiteSpace($q)) { Write-SCMTrace '  bGo: query vacia'; return }
        $secs = 15; [int]::TryParse($w.FindName('tSecs').Text.Trim(), [ref]$secs) | Out-Null
        if ($secs -lt 1) { $secs = 15 }; if ($secs -gt 30) { $secs = 30 }
        $vid.Source = $q; $vid.Secs = $secs; $vid.Go = $true
        Write-SCMTrace ("  bGo: Go={0} source='{1}' secs={2}" -f $vid.Go, $q, $secs)
        $w.Close()
    } }.GetNewClosure())
    $null = $w.ShowDialog()

    Write-SCMTrace ("Show-SCMVideoGrab: dialog cerrado, Go={0}" -f $vid.Go)
    if (-not $vid.Go) { return }
    Write-SCMTrace '  -> Show-SCMProgress + Start-SCMJob (video)'
    Show-SCMProgress -Title 'Descargando clip de video (yt-dlp)...' -Indeterminate
    Start-SCMJob -Status 'Descargando clip de video (yt-dlp)...' -Vars @{ Source = $vid.Source; Folder = $folder; Rom = $rom; Secs = $vid.Secs } -Work {
        . ([scriptblock]::Create($ImportBlockText))
        Save-SCMVideoClip -Source $Source -FolderName $Folder -RomFolder $Rom -MaxSeconds $Secs
    } -OnDone {
        param($r, $e)
        Close-SCMProgress
        if ($e) { [System.Windows.MessageBox]::Show("$e", 'Error al bajar video') | Out-Null; return }
        if ($r -and $r.Ok) {
            Update-SCMActive
            [System.Windows.MessageBox]::Show(("Video colocado: {0}`n`ngamelist.xml actualizado." -f (Split-Path $r.Dest -Leaf)), 'Bajar video') | Out-Null
            Set-SCMStatus 'Video descargado y colocado.'
        }
        else {
            $tail = if ($r -and $r.Log) { ($r.Log -split "`n" | Where-Object { $_ -notmatch 'googlevideo' } | Select-Object -Last 4) -join "`n" } else { '' }
            [System.Windows.MessageBox]::Show(("No se pudo bajar el video.`n`n{0}" -f $tail), 'Bajar video') | Out-Null
            Set-SCMStatus 'No se pudo bajar el video.'
        }
    }
}

function Show-SCMManualGrab {
    param($Row)
    if ($null -eq $Row) { return }
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Buscar manual') | Out-Null; return }
    $folder = [string]$Row.Folder
    $title = [string]$Row.Title

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Buscar manual (PDF)" Width="640" Height="560" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI">
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="dGame" FontSize="15" FontWeight="Bold" Foreground="@ACCENT@" TextWrapping="Wrap"/>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,10">
      <TextBox x:Name="tQuery" Width="430" Padding="6,5" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
      <Button x:Name="bSearch" Content="Buscar en archive.org" Width="150" Margin="8,0,0,0" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
    </StackPanel>
    <Border Grid.Row="2" Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1">
      <ListBox x:Name="lst" Background="Transparent" Foreground="@TEXT@" BorderThickness="0" Margin="4" DisplayMemberPath="Title"/>
    </Border>
    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,10,0,0">
      <TextBlock Text="o pega URL de PDF:" VerticalAlignment="Center" Foreground="@MUTED@" Margin="0,0,6,0"/>
      <TextBox x:Name="tUrl" Width="440" Padding="6,4" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="1" BorderBrush="@LINE@"/>
      <Button x:Name="bUse" Content="Usar" Width="80" Margin="6,0,0,0" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
    </StackPanel>
    <DockPanel Grid.Row="4" Margin="0,12,0,0">
      <Button x:Name="bClose" Content="Cerrar" DockPanel.Dock="Right" Width="100" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
      <Button x:Name="bDl" Content="Descargar seleccionado" DockPanel.Dock="Right" Width="180" Margin="6,0,0,0" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,6" Cursor="Hand"/>
      <TextBlock x:Name="tStatus" VerticalAlignment="Center" Foreground="@MUTED@" TextWrapping="Wrap"/>
    </DockPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('dGame').Text = ("Manual: {0}" -f $title)
    $w.FindName('tQuery').Text = $title
    $lst = $w.FindName('lst')
    $tStatus = $w.FindName('tStatus')

    $downloadUrl = {
        param($url)
        if ([string]::IsNullOrWhiteSpace($url)) { return }
        $tStatus.Text = 'Descargando manual...'; $w.Cursor = 'Wait'
        $res = Save-SCMGrabbedManual -Url $url -FolderName $folder -RomFolder $rom
        $w.Cursor = 'Arrow'
        if ($res.Ok) { $tStatus.Text = ("Manual guardado: {0}   (gamelist actualizado)" -f (Split-Path $res.Dest -Leaf)); Update-SCMActive }
        else { $tStatus.Text = 'No se pudo descargar ese manual. Prueba otro o pega una URL de PDF.' }
    }.GetNewClosure()

    $w.FindName('bSearch').Add_Click({
        $q = $w.FindName('tQuery').Text.Trim()
        if ([string]::IsNullOrWhiteSpace($q)) { return }
        $tStatus.Text = 'Buscando en archive.org (puede tardar unos segundos)...'; $w.Cursor = 'Wait'
        $lst.ItemsSource = $null
        $results = @(Search-SCMArchiveManuals -Query $q -Max 8)
        $w.Cursor = 'Arrow'
        $lst.ItemsSource = $results
        $tStatus.Text = if ($results.Count -gt 0) { ("{0} manual(es) con PDF. Elige uno y pulsa Descargar." -f $results.Count) } else { 'Sin resultados con PDF. Prueba otro texto o pega una URL de PDF.' }
    }.GetNewClosure())

    $w.FindName('bDl').Add_Click({
        $sel = $lst.SelectedItem
        if ($null -eq $sel) { $tStatus.Text = 'Selecciona un manual de la lista.'; return }
        & $downloadUrl ([string]$sel.PdfUrl)
    }.GetNewClosure())
    $w.FindName('bUse').Add_Click({ & $downloadUrl ($w.FindName('tUrl').Text.Trim()) }.GetNewClosure())
    $w.FindName('bClose').Add_Click({ $w.Close() }.GetNewClosure())
    $null = $w.ShowDialog()
}

# =====================================================================
#  Trabajos de fondo (scan, portada, scrapeo masivo)
# =====================================================================
function Get-SCMApiKey {
    try { if ($script:Config.Preferences.PSObject.Properties.Name -contains 'ApiKeys' -and $script:Config.Preferences.ApiKeys.PSObject.Properties.Name -contains 'SteamGridDB') { return [string]$script:Config.Preferences.ApiKeys.SteamGridDB } } catch { }
    return ''
}

function Invoke-SCMScanJob {
    if (-not (Test-Path $script:Config.Paths.ScummVM)) { [System.Windows.MessageBox]::Show("No encuentro scummvm.exe en:`n$($script:Config.Paths.ScummVM)`n`nConfigura la ruta en Ajustes.", 'Rescan') | Out-Null; return }
    Start-SCMJob -Status 'Escaneando la coleccion con ScummVM...' -Work {
        . ([scriptblock]::Create($ImportBlockText)); Invoke-SCMScan | Out-Null; 'done'
    } -OnDone { param($r, $e) if ($e) { [System.Windows.MessageBox]::Show("$e", 'Error en el scan') | Out-Null } Update-SCMData; Set-SCMStatus 'Scan completado.' }
}

# Dialogo de comparacion: caratula actual (fichero) vs nueva (URL). Devuelve
# $true si el usuario quiere usar la nueva.
function Show-SCMCoverCompare {
    param([string]$Title, [string]$CurrentPath, [string]$NewUrl)
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Cambiar caratula" Width="720" Height="560" WindowStartupLocation="CenterOwner" Background="@INK@" Foreground="@TEXT@" FontFamily="Segoe UI" ResizeMode="NoResize">
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="t" FontSize="15" FontWeight="Bold" Foreground="@ACCENT@" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0" Margin="0,0,8,0">
        <TextBlock x:Name="lblCur" Text="Actual" Foreground="@MUTED@" FontFamily="Consolas" FontSize="12" HorizontalAlignment="Center" Margin="0,0,0,6"/>
        <Border Background="@SLATE@" CornerRadius="10" BorderBrush="@LINE@" BorderThickness="1" Height="380">
          <Grid>
            <Image x:Name="imgCur" Stretch="Uniform" Margin="8"/>
            <TextBlock x:Name="noCur" Text="(sin caratula)" Foreground="@MUTED@" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas"/>
          </Grid>
        </Border>
      </StackPanel>
      <StackPanel Grid.Column="1" Margin="8,0,0,0">
        <TextBlock Text="Nueva (SteamGridDB)" Foreground="@ACCENT@" FontFamily="Consolas" FontSize="12" HorizontalAlignment="Center" Margin="0,0,0,6"/>
        <Border Background="@SLATE@" CornerRadius="10" BorderBrush="@ACCENT@" BorderThickness="1" Height="380">
          <Grid>
            <Image x:Name="imgNew" Stretch="Uniform" Margin="8"/>
            <TextBlock x:Name="noNew" Text="(no se pudo cargar)" Foreground="@MUTED@" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" Visibility="Collapsed"/>
          </Grid>
        </Border>
      </StackPanel>
    </Grid>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="bNo" Content="Mantener la actual" Width="160" Background="@RAISED@" Foreground="@TEXT@" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
      <Button x:Name="bYes" Content="Usar la nueva" Width="140" Background="@ACCENT@" Foreground="@ACCENTINK@" FontWeight="Bold" BorderThickness="0" Padding="8,7" Margin="6,0,0,0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = New-SCMDialog -Xaml $xaml
    $w.FindName('t').Text = $Title
    if ($CurrentPath -and (Test-Path $CurrentPath)) {
        $cur = New-SCMBitmap -Path $CurrentPath -DecodeWidth 340
        if ($cur) { $w.FindName('imgCur').Source = $cur; $w.FindName('noCur').Visibility = 'Collapsed' }
    } else {
        $w.FindName('lblCur').Text = '(no hay caratula actual)'
        $w.FindName('bNo').Content = 'Cancelar'
        $w.FindName('bYes').Content = 'Usar esta'
    }
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.UriSource = [uri]$NewUrl; $bi.EndInit()
        $w.FindName('imgNew').Source = $bi
    } catch { $w.FindName('noNew').Visibility = 'Visible' }
    $res = @{ Use = $false }
    $w.FindName('bYes').Add_Click({ $res.Use = $true; $w.Close() }.GetNewClosure())
    $w.FindName('bNo').Add_Click({ $res.Use = $false; $w.Close() }.GetNewClosure())
    $null = $w.ShowDialog()
    return $res.Use
}

function Invoke-SCMCoverJob {
    param($Row)
    if ($null -eq $Row) { return }
    $key = Get-SCMApiKey
    if ([string]::IsNullOrWhiteSpace($key)) { [System.Windows.MessageBox]::Show('No hay API key de SteamGridDB. Configurala en Ajustes.', 'Bajar caratula') | Out-Null; return }
    $single = @($Row.Game)
    # El job SOLO busca la URL (no coloca nada todavia); la colocacion se decide
    # tras previsualizar en Show-SCMCoverCompare.
    Start-SCMJob -Status ("Buscando caratula de {0}..." -f $Row.Title) -Vars @{ Games = $single; Key = $key } -Work {
        . ([scriptblock]::Create($ImportBlockText))
        $g = $Games[0]
        $folder = Split-Path ([string]$g.FullPath) -Leaf
        $id = Find-SCMSteamGridGameId -Term $g.Title -Key $Key
        if (-not $id) { return [PSCustomObject]@{ Found = $false; Folder = $folder; Title = [string]$g.DisplayTitle } }
        $url = Get-SCMSteamGridCoverUrl -GameId $id -Key $Key
        if (-not $url) { return [PSCustomObject]@{ Found = $false; Folder = $folder; Title = [string]$g.DisplayTitle } }
        [PSCustomObject]@{ Found = $true; Url = [string]$url; Folder = $folder; Title = [string]$g.DisplayTitle }
    } -OnDone {
        param($r, $e)
        if ($e) { [System.Windows.MessageBox]::Show("$e", 'Error al buscar caratula') | Out-Null; return }
        if (-not $r -or -not $r.Found) { Set-SCMStatus 'No se encontro caratula en SteamGridDB.'; [System.Windows.MessageBox]::Show('No se encontro caratula en SteamGridDB para este juego.', 'Bajar caratula') | Out-Null; return }
        # Carpeta ACTIVA (ScummVM o Windows): si el juego es de la ventana
        # Windows, la caratula debe ir a roms\windows, no a roms\scummvm.
        $rom2 = Get-SCMActiveRom
        $existing = Find-SCMCoverPath $r.Folder
        $use = Show-SCMCoverCompare -Title $r.Title -CurrentPath $existing -NewUrl $r.Url
        if (-not $use) { Set-SCMStatus 'Caratula sin cambios.'; return }
        $res = $null
        try { $res = Save-SCMGrabbedImage -Url $r.Url -Type 'image' -FolderName $r.Folder -RomFolder $rom2 } catch { Write-SCMGuiError -Where 'Colocar caratula' -ErrorObj $_ | Out-Null }
        if ($res -and $res.Ok) { Update-SCMActive; Set-SCMStatus 'Caratula actualizada.' }
        else { Set-SCMStatus 'No se pudo colocar la caratula.'; [System.Windows.MessageBox]::Show('No se pudo descargar/colocar la caratula.', 'Bajar caratula') | Out-Null }
    }
}

function Invoke-SCMScrapeMediaJob {
    param($Games, [string[]]$Types, [bool]$OnlyMissing)
    Write-SCMTrace ("Invoke-SCMScrapeMediaJob: ENTRA juegos={0}" -f @($Games).Count)
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { Write-SCMTrace '  return: RomFolder no existe'; [System.Windows.MessageBox]::Show("Carpeta de ROMs no encontrada:`n$rom", 'Descargar media') | Out-Null; return }
    if ($script:Job) { Write-SCMTrace '  return: ya hay job en curso'; [System.Windows.MessageBox]::Show('Ya hay una tarea en curso. Espera a que termine antes de descargar.', 'Descargar media') | Out-Null; return }
    if (@($Games).Count -eq 0) { Write-SCMTrace '  return: 0 juegos'; [System.Windows.MessageBox]::Show('No hay juegos para descargar media.', 'Descargar media') | Out-Null; return }
    $sync = [hashtable]::Synchronized(@{ Done = 0; Total = 0; Current = '' })
    Write-SCMTrace '  -> Show-SCMProgress'
    Show-SCMProgress -Title 'Descargando media (multi-fuente)'
    Write-SCMTrace '  -> Start-SCMJob'
    Set-SCMStatus 'Descargando media...'
    Start-SCMJob -Status 'Descargando media (multi-fuente)...' -Sync $sync -Vars @{ Games = $Games; Rom = $rom; Types = $Types; OnlyMissing = $OnlyMissing } -Work {
        try {
            . ([scriptblock]::Create($ImportBlockText))
            $all = @(Invoke-SCMScrapeMedia -Games $Games -RomFolder $Rom -Types $Types -OnlyMissing $OnlyMissing -Sync $Sync)
            $res = $all | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'Total') } | Select-Object -Last 1
            if ($null -eq $res) { $res = [PSCustomObject]@{ Downloaded = 0; Failed = 0; Total = 0; Sources = ''; FailedTasks = @() } }
            $res
        } catch {
            [PSCustomObject]@{ Downloaded = 0; Failed = 0; Total = 0; Sources = ''; FailedTasks = @(); Error = ("{0} | {1}" -f $_.Exception.Message, $_.ScriptStackTrace) }
        }
    } -OnProgress {
        param($s)
        Update-SCMProgress $s
    } -OnDone {
        param($r, $e)
        Close-SCMProgress
        $script:UI.QueuePanel.Visibility = 'Collapsed'
        if ($e) { [System.Windows.MessageBox]::Show("$e", 'Error en la descarga') | Out-Null; return }
        if ($r -and ($r.PSObject.Properties.Name -contains 'Error') -and $r.Error) {
            [System.Windows.MessageBox]::Show(("La descarga de todos fallo:`n`n{0}`n`n(Detalle en Logs\media_debug.log)" -f $r.Error), 'Descargar media - error') | Out-Null
            Set-SCMStatus 'Descarga: error (ver dialogo).'
            return
        }
        Update-SCMActive
        if ($r) {
            $msg =
                if ($r.Total -eq 0) {
                    "No habia media pendiente: todo lo que marcaste ya existe.`n`n(Desmarca 'Solo lo que falta' para re-descargar.)"
                }
                elseif ($r.Downloaded -eq 0) {
                    $srcNote = if ($null -eq (Get-SCMScreenScraperCreds)) {
                        "`n`nNOTA: ScreenScraper esta INACTIVO (falta Dev ID/Password en Ajustes). Es la unica fuente con video/snap/manual y la que mejor cubre aventuras clasicas. Con solo SteamGridDB + Libretro muchas no aparecen."
                    } else { "`n`nProbadas todas las fuentes configuradas sin resultado para estos titulos." }
                    ("No se encontro media.`n`nIntentos: {0}   Sin resultado: {1}{2}" -f $r.Total, $r.Failed, $srcNote)
                }
                else {
                    $srcLine = if ($r.Sources) { "`n`nFuentes: {0}" -f $r.Sources } else { '' }
                    "Media descargada: {0} de {1}.`nFallos (no encontrada): {2}.{3}" -f $r.Downloaded, $r.Total, $r.Failed, $srcLine
                }
            [System.Windows.MessageBox]::Show($msg, 'Descargar media') | Out-Null
            Set-SCMStatus ("Media: {0}/{1} descargada (fallos {2})." -f $r.Downloaded, $r.Total, $r.Failed)
            # Reintentar solo los que fallaron (vuelve a probar todas las fuentes).
            if ($r.Failed -gt 0 -and @($r.FailedTasks).Count -gt 0) {
                $ans = [System.Windows.MessageBox]::Show(("Reintentar los {0} que fallaron?" -f @($r.FailedTasks).Count), 'Reintentar', 'YesNo', 'Question')
                if ($ans -eq 'Yes') { Invoke-SCMRetryFailedJob -Tasks $r.FailedTasks }
            }
        }
        else {
            [System.Windows.MessageBox]::Show("La descarga termino sin resultado (posible corte de red o antivirus).`n`nRevisa el log:`nLogs\media_debug.log", 'Descargar media') | Out-Null
            Set-SCMStatus 'Descarga: sin resultado (revisa Logs\media_debug.log).'
        }
    }
}

function Invoke-SCMRetryFailedJob {
    param([array]$Tasks)
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { return }
    if ($script:Job) { [System.Windows.MessageBox]::Show('Ya hay una tarea en curso.', 'Reintentar') | Out-Null; return }
    $sync = [hashtable]::Synchronized(@{ Done = 0; Total = 0; Current = '' })
    Show-SCMProgress -Title 'Reintentando descargas fallidas'
    Start-SCMJob -Status 'Reintentando fallidas...' -Sync $sync -Vars @{ Tasks = $Tasks; Rom = $rom } -Work {
        . ([scriptblock]::Create($ImportBlockText))
        Invoke-SCMScrapeMedia -Games @($Tasks | ForEach-Object { $_.Game }) -RomFolder $Rom -RetryTasks $Tasks -Sync $Sync
    } -OnProgress { param($s) Update-SCMProgress $s } -OnDone {
        param($r, $e)
        Close-SCMProgress
        if ($e) { [System.Windows.MessageBox]::Show("$e", 'Reintentar') | Out-Null; return }
        Update-SCMActive
        if ($r) {
            $srcLine = if ($r.Sources) { "`n`nFuentes: {0}" -f $r.Sources } else { '' }
            [System.Windows.MessageBox]::Show(("Reintento: {0} de {1} recuperadas.`nSiguen sin encontrarse: {2}.{3}" -f $r.Downloaded, $r.Total, $r.Failed, $srcLine), 'Reintentar') | Out-Null
            Set-SCMStatus ("Reintento: {0}/{1} recuperadas." -f $r.Downloaded, $r.Total)
        }
    }
}

# =====================================================================
#  Watch-folder (FileSystemWatcher)
# =====================================================================
$script:Watcher = $null
$script:PendingNew = @{}
$script:BannerMode = 'sync'   # 'sync' (carpetas nuevas) | 'thumbs' (miniaturas sobrantes)

function Show-SCMBanner {
    $n = @($script:PendingNew.Keys).Count
    if ($n -le 0) { $script:UI.Banner.Visibility = 'Collapsed'; return }
    $script:BannerMode = 'sync'
    $script:UI.BtnBanner.Content = 'Revisar y sincronizar'
    $script:UI.BannerText.Text = ("{0} carpeta(s) nueva(s) detectada(s) en la carpeta de ROMs - revisa y sincroniza" -f $n)
    $script:UI.Banner.Visibility = 'Visible'
}

# Cuenta las miniaturas (-thumb) sobrantes en images\ de una carpeta de ROMs.
function Get-SCMLeftoverThumbCount {
    param([string]$RomFolder)
    if ([string]::IsNullOrWhiteSpace($RomFolder)) { return 0 }
    $dir = Join-Path $RomFolder 'images'
    if (-not (Test-Path $dir)) { return 0 }
    return @(Get-ChildItem $dir -File -Filter '*-thumb.*' -ErrorAction SilentlyContinue).Count
}

# Al arrancar: si quedan miniaturas de builds antiguos (RetroBat las pinta
# encima de la caratula), ofrece quitarlas desde el banner en un clic.
function Test-SCMThumbBanner {
    $n = Get-SCMLeftoverThumbCount -RomFolder $script:Config.Paths.RomFolder
    try { $n += Get-SCMLeftoverThumbCount -RomFolder (Get-SCMWindowsRomFolder) } catch { }
    if ($n -le 0) { return }
    $script:BannerMode = 'thumbs'
    $script:UI.BtnBanner.Content = 'Quitar miniaturas'
    $script:UI.BannerText.Text = ("{0} miniatura(s) antigua(s) (-thumb) detectada(s): RetroBat las muestra encima de la caratula" -f $n)
    $script:UI.Banner.Visibility = 'Visible'
}

# Limpieza de miniaturas ScummVM + Windows con confirmacion (la usan el banner
# y el boton de Doctor).
function Invoke-SCMRemoveThumbs {
    $ans = [System.Windows.MessageBox]::Show("Quitar TODAS las miniaturas (-thumb) de ScummVM y Windows?`n`nRetroBat las mostraba encima de la imagen. Se borran los ficheros *-thumb.* y su <thumbnail> del gamelist (con backup). Las portadas NO se tocan.", 'Quitar miniaturas', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $n = 0
    $n += Remove-SCMThumbnails -RomFolder $script:Config.Paths.RomFolder
    try { $n += Remove-SCMThumbnails -RomFolder (Get-SCMWindowsRomFolder) } catch { }
    Update-SCMActive
    [System.Windows.MessageBox]::Show(("Quitadas {0} miniatura(s). Refresca RetroBat para verlo." -f $n), 'Quitar miniaturas') | Out-Null
}

function Stop-SCMWatcher {
    if ($script:Watcher) { try { $script:Watcher.EnableRaisingEvents = $false; $script:Watcher.Dispose() } catch { } $script:Watcher = $null }
    $script:UI.WatchInd.Visibility = 'Collapsed'
}

function Start-SCMWatcher {
    Stop-SCMWatcher
    $rom = Get-SCMActiveRom
    if (-not (Test-Path $rom)) { return }
    $w = New-Object System.IO.FileSystemWatcher $rom
    $w.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName
    $w.IncludeSubdirectories = $false
    $handler = {
        param($src, $e)
        try {
            $name = $e.Name
            if ($script:MediaFolderNames -contains $name) { return }
            $script:PendingNew[$name] = $true
            $script:UI.Window.Dispatcher.Invoke([System.Action] { Show-SCMBanner })
        } catch { }
    }
    $w.add_Created($handler); $w.add_Renamed($handler)
    $w.EnableRaisingEvents = $true
    $script:Watcher = $w
    $script:UI.WatchInd.Visibility = 'Visible'
}

# =====================================================================
#  Eventos
# =====================================================================
$script:UI.Search.Add_TextChanged({
    $t = $script:UI.Search.Text
    $script:UI.PhSearch.Visibility = $(if ([string]::IsNullOrEmpty($t)) { 'Visible' } else { 'Collapsed' })
    Update-SCMList -Filter $t
})
$script:UI.List.Add_SelectionChanged({ Invoke-SCMSafe -Name 'Seleccionar juego' -Action { Show-SCMDetail (Get-SCMSelectedRow) } })
$script:UI.SegGallery.Add_Click({ Invoke-SCMSafe -Name 'Vista galeria' -Action { Set-SCMViewMode 'Gallery' } })
$script:UI.SegList.Add_Click({ Invoke-SCMSafe -Name 'Vista lista' -Action { Set-SCMViewMode 'List' } })
$script:UI.BtnScan.Add_Click({ Invoke-SCMSafe -Name 'Rescan' -Action { Invoke-SCMScanJob } })
$script:UI.BtnSync.Add_Click({ Invoke-SCMSafe -Name 'Sync Frontend' -Action { Show-SCMSync } })
$script:UI.BtnDoctor.Add_Click({ Invoke-SCMSafe -Name 'Doctor' -Action { Show-SCMDoctor } })
$script:UI.BtnImport.Add_Click({ Invoke-SCMSafe -Name 'Estado' -Action { Show-SCMImportStatus } })
$script:UI.BtnWindows.Add_Click({ Invoke-SCMSafe -Name 'Windows' -Action { Show-SCMWindowsMedia } })
$script:UI.BtnSettings.Add_Click({ Invoke-SCMSafe -Name 'Ajustes' -Action { Show-SCMSettings } })
$script:UI.BtnBanner.Add_Click({ Invoke-SCMSafe -Name 'Banner' -Action {
    if ($script:BannerMode -eq 'thumbs') {
        Invoke-SCMRemoveThumbs
        $script:UI.Banner.Visibility = 'Collapsed'
        $script:BannerMode = 'sync'; $script:UI.BtnBanner.Content = 'Revisar y sincronizar'
    } else {
        $script:PendingNew = @{}; Show-SCMBanner; Show-SCMSync
    }
} })
$script:UI.BtnTheme.Add_Click({
    $newMode = if ($script:ThemeMode -eq 'Dark') { 'Light' } else { 'Dark' }
    Set-SCMTheme -Mode $newMode -AccentName $script:ThemeAccent
    Set-SCMViewMode $script:ViewMode
    Update-SCMData
    try {
        $cfg = Get-SCMConfig
        if ($cfg.Preferences.PSObject.Properties.Name -notcontains 'UI') { $cfg.Preferences | Add-Member -NotePropertyName 'UI' -NotePropertyValue ([PSCustomObject]@{}) -Force }
        if ($cfg.Preferences.UI.PSObject.Properties.Name -notcontains 'Theme') { $cfg.Preferences.UI | Add-Member -NotePropertyName 'Theme' -NotePropertyValue '' -Force }
        if ($cfg.Preferences.UI.PSObject.Properties.Name -notcontains 'GuiAccent') { $cfg.Preferences.UI | Add-Member -NotePropertyName 'GuiAccent' -NotePropertyValue '' -Force }
        if ($cfg.Preferences.UI.PSObject.Properties.Name -notcontains 'Accent') { $cfg.Preferences.UI | Add-Member -NotePropertyName 'Accent' -NotePropertyValue 'Cyan' -Force }
        if ($cfg.Preferences.UI.PSObject.Properties.Name -notcontains 'Unicode') { $cfg.Preferences.UI | Add-Member -NotePropertyName 'Unicode' -NotePropertyValue $true -Force }
        $cfg.Preferences.UI.Theme = $newMode; $cfg.Preferences.UI.GuiAccent = $script:ThemeAccent
        Set-SCMConfig -Config $cfg; $script:Config = Get-SCMConfig
    } catch { }
})
if ($script:UI.LogoBox) { $script:UI.LogoBox.Add_MouseLeftButtonUp({ Invoke-SCMSafe -Name 'Acerca de' -Action { Show-SCMAbout } }) }
$window.Add_Closed({ try { if ($script:UITimer) { $script:UITimer.Stop() } } catch { } Stop-SCMWatcher })

# =====================================================================
#  Arranque
# =====================================================================
try {
    Set-SCMViewMode 'Gallery'
    Update-SCMData
    Start-SCMWatcher
    Test-SCMThumbBanner
    if (@($script:AllRows).Count -eq 0) { Set-SCMStatus 'Base de datos vacia. Configura las rutas en Ajustes y pulsa Rescan.' }
} catch {
    Write-SCMGuiError -Where 'Arranque' -ErrorObj $_ | Out-Null
    try { [System.Windows.MessageBox]::Show(("Error al arrancar:`n`n{0}`n`nVer Logs\gui_error.log" -f $_.Exception.Message), 'ScummVM Manager') | Out-Null } catch { }
}

if (-not $NoShow) { $null = $window.ShowDialog() }

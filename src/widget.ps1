param(
  [switch]$Preview,
  [switch]$HitTest,
  [string]$PreviewPath,
  [switch]$Collect
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# 高分屏下按 per-monitor v2 渲染，避免 200% 缩放时发虚
if (-not ('DpiFix' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class DpiFix {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
  public static void Enable() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch {}
    try { SetProcessDpiAwareness(2); } catch {}
  }
}
'@
}
[DpiFix]::Enable()

# 单实例：重复双击只保留一个小球（预览/命中测试不占锁）
if (-not $Preview -and -not $HitTest) {
  $script:instMutex = New-Object System.Threading.Mutex($false, 'Local\DshUsageBall')
  if (-not $script:instMutex.WaitOne(0)) { exit }
}

$here = $PSScriptRoot
$statePath = Join-Path $here 'state.json'
$posPath = Join-Path $here 'pos.json'
$logPath = Join-Path $here 'widget.log'
$configPath = Join-Path $here 'config.json'

function Write-Log([string]$msg) {
  try { Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

# ---------------- Win32：找到 DSH 主窗口、贴在它的客户区里 ----------------
if (-not ('DshWin' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class DshWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  // 找 DeepSeek Harness 的可见主窗口（Electron 的 Chrome_WidgetWin_1）
  public static IntPtr Find() {
    IntPtr found = IntPtr.Zero; long best = 0;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      if (!cls.ToString().StartsWith("Chrome_WidgetWin_1")) return true;
      var txt = new StringBuilder(512); GetWindowText(h, txt, 512);
      if (!txt.ToString().EndsWith("DeepSeek Harness")) return true;
      RECT r; GetWindowRect(h, out r);
      long area = (long)(r.R - r.L) * (r.B - r.T);
      if (area > best) { best = area; found = h; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
}

# ---------------- 数据采集 ----------------
$config = @{ refreshSeconds = 20; collectSeconds = 90; nodePath = '' }
if (Test-Path $configPath) {
  try {
    $raw = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $raw.PSObject.Properties) { $config[$p.Name] = $p.Value }
  } catch { Write-Log "config parse failed: $_" }
}

function Resolve-Node {
  if ($config.nodePath -and (Test-Path $config.nodePath)) { return $config.nodePath }
  if ($env:DSH_DESKTOP_NODE_EXECUTABLE -and (Test-Path $env:DSH_DESKTOP_NODE_EXECUTABLE)) { return $env:DSH_DESKTOP_NODE_EXECUTABLE }
  # 从运行中的 DSH 进程反推安装目录（不同用户名/安装盘都适用）
  if ($script:dsh -ne [IntPtr]::Zero) {
    try {
      $procId = 0
      [void][DshWin]::GetWindowThreadProcessId($script:dsh, [ref]$procId)
      if ($procId -gt 0) {
        $exe = (Get-Process -Id $procId -ErrorAction Stop).Path
        if ($exe) {
          $guess = Join-Path (Split-Path $exe) 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
          if (Test-Path $guess) { return $guess }
        }
      }
    } catch {}
  }
  foreach ($root in @("$env:LOCALAPPDATA\Programs", $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $cand = Join-Path $root 'DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
    if (Test-Path $cand) { return $cand }
  }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}
$script:node = $null
$script:collecting = $false

function Invoke-Collect {
  if ($script:collecting) { return }
  $script:collecting = $true
  try {
    if (-not $script:node) { $script:node = Resolve-Node }
    if (-not $script:node) { Write-Log 'node runtime not found'; return }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:node
    $psi.Arguments = '"' + (Join-Path $here 'collect.mjs') + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch {}; Write-Log 'collector timeout' }
    elseif ($p.ExitCode -ne 0) { Write-Log ("collector exit {0}: {1}" -f $p.ExitCode, $err.Trim()) }
  } catch {
    Write-Log "collector failed: $_"
  } finally {
    $script:collecting = $false
  }
}

function Read-State {
  if (-not (Test-Path $statePath)) { Invoke-Collect }
  try { return Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Write-Log "state read failed: $_"; return $null }
}

function Format-Tokens([double]$n) {
  if ($n -ge 1e9) { return ('{0:0.0}B' -f ($n / 1e9)) }
  if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
  if ($n -ge 1e3) { return ('{0:0.0}K' -f ($n / 1e3)) }
  return [string][int]$n
}
function Format-Money([double]$v, [int]$digits = 2) {
  return ('¥{0:N' + $digits + '}') -f $v
}
function Format-Ball([double]$v) {
  if ($v -ge 1000) { return ('¥{0:0}' -f $v) }
  if ($v -ge 100) { return ('¥{0:0}' -f $v) }
  if ($v -ge 10) { return ('¥{0:0.0}' -f $v) }
  return ('¥{0:0.00}' -f $v)
}

# ---------------- 界面 ----------------
$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid.Resources>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="Margin" Value="2,0,0,0"/>
      <Setter Property="Foreground" Value="#7D879E"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="6" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1FFFFFFF"/>
                <Setter Property="Foreground" Value="#E6ECF8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Grid.Resources>

  <!-- 小球（收起态） -->
  <Border Name="Ball" Width="64" Height="64" CornerRadius="32" Visibility="Collapsed"
          BorderThickness="1" BorderBrush="#3DFFFFFF" Cursor="Hand">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#4C8DFF" Offset="0"/>
        <GradientStop Color="#7B5CFF" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Name="BallCost" Text="¥0.0" Foreground="#FFFFFF" FontSize="15.5" FontWeight="SemiBold"
                 HorizontalAlignment="Center" FontFamily="Segoe UI Semibold"/>
      <TextBlock Name="BallLabel" Text="今日" Foreground="#D9E4FF" FontSize="8.5" HorizontalAlignment="Center" Margin="0,1,0,0"/>
    </StackPanel>
  </Border>

  <!-- 详情卡片（展开态） -->
  <Border Name="Card" Width="380" Height="252" CornerRadius="18" BorderThickness="1" BorderBrush="#22FFFFFF"
          Visibility="Collapsed">
    <Border.LayoutTransform>
      <ScaleTransform ScaleX="1" ScaleY="1"/>
    </Border.LayoutTransform>
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#F21A1F2B" Offset="0"/>
        <GradientStop Color="#F20F1219" Offset="0.55"/>
        <GradientStop Color="#F2141822" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid>
      <Grid Margin="18,14,18,12">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Name="Header" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse Width="7" Height="7" Fill="#5AD1FF" Margin="0,0,8,0"/>
          <TextBlock Text="DSH 用量" Foreground="#A7B0C4" FontSize="12" FontWeight="SemiBold"/>
          <TextBlock Name="RangeText" Text="近 7 天" Foreground="#5E6779" FontSize="10.5" Margin="8,1,0,0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button Name="OfficialBtn" Content="↗" Style="{StaticResource IconBtn}" ToolTip="打开 DeepSeek 官方用量页"/><Button Name="RefreshBtn" Content="↻" Style="{StaticResource IconBtn}"/>
          <Button Name="CollapseBtn" Content="●" Style="{StaticResource IconBtn}" ToolTip="收成小球"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="0,8,0,0">
        <StackPanel HorizontalAlignment="Left">
          <TextBlock Text="今日花费" Foreground="#78819A" FontSize="11"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock Name="TodayCost" Text="¥0.00" Foreground="#FFFFFF" FontSize="31" FontWeight="SemiBold" FontFamily="Segoe UI Semibold"/>
            <StackPanel Margin="12,7,0,0">
              <TextBlock Name="TodayTokens" Text="— tok" Foreground="#B8C0D4" FontSize="12"/>
              <TextBlock Name="TodayCalls" Text="— 次调用" Foreground="#5E6779" FontSize="10.5"/>
            </StackPanel>
          </StackPanel>
        </StackPanel>
        <StackPanel HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,2,4">
          <Border Name="PeakPill" CornerRadius="7" Background="#1FF0B35B" Padding="9,3,9,3" HorizontalAlignment="Right">
            <TextBlock Name="PeakText" Text="峰值时段" Foreground="#F0B35B" FontSize="10"/>
          </Border>
          <TextBlock Name="PeakHint" Text="09:00-12:00 · 14:00-18:00" Foreground="#4E5668" FontSize="9.5" HorizontalAlignment="Right" Margin="0,3,0,0"/>
        </StackPanel>
      </Grid>

      <StackPanel Name="ChartHost" Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,8,0,0" VerticalAlignment="Bottom"/>

      <Grid Grid.Row="3" Margin="0,9,22,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="1"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Background="#12FFFFFF" Height="1"/>
        <Grid Grid.Row="1" Margin="0,8,0,0">
          <TextBlock Name="MonthText" Text="本月 ¥0.00 · 累计 ¥0.00" Foreground="#848DA4" FontSize="10.5"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><TextBlock Name="StampText" Text="—" Foreground="#4A5264" FontSize="9.5" VerticalAlignment="Center"/><TextBlock Name="OfficialLink" Text="官方 ↗" Foreground="#7FB0FF" FontSize="9.5" Margin="6,0,0,0" Cursor="Hand" ToolTip="打开 DeepSeek 官方用量页"/></StackPanel>
        </Grid>
      </Grid>
      </Grid>

      <!-- 四边 + 四角的透明缩放热区：靠近时鼠标自动变成双向箭头 -->
      <Border Tag="n" Height="8" HorizontalAlignment="Stretch" VerticalAlignment="Top" Margin="12,0,12,0" Background="Transparent" Cursor="SizeNS"/>
      <Border Tag="s" Height="8" HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Margin="12,0,12,0" Background="Transparent" Cursor="SizeNS"/>
      <Border Tag="w" Width="8" VerticalAlignment="Stretch" HorizontalAlignment="Left" Margin="0,12,0,12" Background="Transparent" Cursor="SizeWE"/>
      <Border Tag="e" Width="8" VerticalAlignment="Stretch" HorizontalAlignment="Right" Margin="0,12,0,12" Background="Transparent" Cursor="SizeWE"/>
      <Border Tag="nw" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="2,2,0,0" Background="Transparent" Cursor="SizeNWSE"/>
      <Border Tag="ne" Width="18" Height="18" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,2,0" Background="Transparent" Cursor="SizeNESW"/>
      <Border Tag="sw" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="2,0,0,2" Background="Transparent" Cursor="SizeNESW"/>
      <Border Tag="se" Width="18" Height="18" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,2,2" Background="Transparent" Cursor="SizeNWSE"/>    </Grid>
  </Border>
</Grid>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$root = [System.Windows.Markup.XamlReader]::Load($reader)

$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $false
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.ResizeMode = 'NoResize'
$win.WindowStartupLocation = 'Manual'
$win.Content = $root

$card = $root.FindName('Card')
$ballEl = $root.FindName('Ball')
$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.BlurRadius = 30
$shadow.ShadowDepth = 8
$shadow.Direction = 270
$shadow.Color = [System.Windows.Media.Color]::FromRgb(0, 0, 0)
$shadow.Opacity = 0.55
$card.Effect = $shadow


$chartHost = $root.FindName('ChartHost')
$cardScale = [System.Windows.Media.ScaleTransform]$card.LayoutTransform

$BASE_W = 380.0
$BASE_H = 252.0
$script:ballSize = 64.0
$MARGIN = 10.0

$script:zoom = 1.0
$script:mode = 'ball'          # ball | card
$script:dpiScale = 1.0
$script:clientX = 0
$script:clientY = 0
$script:clientW = 1200
$script:clientH = 800
$script:relX = 16
$script:relY = 16              # 相对 DSH 客户区左上角（DIP）
$script:dsh = [IntPtr]::Zero
$script:ownerSet = $false
$script:ownerHwnd = [IntPtr]::Zero

if (Test-Path $posPath) {
  try {
    $p = Get-Content $posPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $p.zoom) { $script:zoom = [double]$p.zoom }
    if ($null -ne $p.relX) { $script:relX = [double]$p.relX }
    if ($null -ne $p.relY) { $script:relY = [double]$p.relY }
    if ($p.mode -eq 'card') { $script:mode = 'card' }
  } catch {}
}
if ($script:zoom -lt 0.8) { $script:zoom = 0.8 }
if ($script:zoom -gt 1.8) { $script:zoom = 1.8 }

function Save-Position {
  try {
    $json = @{ relX = [int]$script:relX; relY = [int]$script:relY; zoom = [math]::Round($script:zoom, 2); mode = $script:mode } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($posPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Current-Size {
  if ($script:mode -eq 'card') { return @([math]::Round($BASE_W * $script:zoom), [math]::Round($BASE_H * $script:zoom)) }
  return @($script:ballSize, $script:ballSize)
}

function Apply-Mode {
  $size = Current-Size
  if ($script:mode -eq 'card') {
    $card.Visibility = 'Visible'
    $ballEl.Visibility = 'Collapsed'
    $cardScale.ScaleX = $script:zoom
    $cardScale.ScaleY = $script:zoom
  } else {
    $card.Visibility = 'Collapsed'
    $ballEl.Visibility = 'Visible'
  }
  $win.Width = $size[0]
  $win.Height = $size[1]
  Place-Window
}

function Clamp-Rel {
  $size = Current-Size
  $maxX = [math]::Max(0, $script:clientW - $size[0])
  $maxY = [math]::Max(0, $script:clientH - $size[1])
  if ($script:relX -lt $MARGIN) { $script:relX = $MARGIN }
  if ($script:relY -lt $MARGIN) { $script:relY = $MARGIN }
  if ($script:relX -gt $maxX - $MARGIN) { $script:relX = [math]::Max($MARGIN, $maxX - $MARGIN) }
  if ($script:relY -gt $maxY - $MARGIN) { $script:relY = [math]::Max($MARGIN, $maxY - $MARGIN) }
}

function Place-Window {
  Clamp-Rel
  $nl = $script:clientX + $script:relX
  $nt = $script:clientY + $script:relY
  if ([math]::Abs($win.Left - $nl) -gt 0.5 -or [math]::Abs($win.Top - $nt) -gt 0.5) {
    Write-Log ("move {0:0.0},{1:0.0} -> {2:0.0},{3:0.0} rel={4:0.0},{5:0.0} pix={6:0.00} size={7}x{8}" -f $win.Left, $win.Top, $nl, $nt, $script:relX, $script:relY, [System.Windows.Media.VisualTreeHelper]::GetDpi($win).PixelsPerDip, $win.Width, $win.Height)
  }
  if ([math]::Abs($win.Left - $nl) -gt 0.4 -or [math]::Abs($win.Top - $nt) -gt 0.4) {
    $win.Left = $nl
    $win.Top = $nt
  }
}

function Measure-Dsh {
  $h = $script:dsh
  if ($h -eq [IntPtr]::Zero -or -not [DshWin]::IsWindow($h)) {
    $h = [DshWin]::Find()
    if ($h -eq [IntPtr]::Zero) { return $false }
    $script:dsh = $h
  }
  if (-not [DshWin]::IsWindowVisible($h) -or [DshWin]::IsIconic($h)) { return $false }

  $rc = New-Object DshWin+RECT
  if (-not [DshWin]::GetClientRect($h, [ref]$rc)) { return $false }
  $pt = New-Object DshWin+POINT
  $pt.X = 0; $pt.Y = 0
  if (-not [DshWin]::ClientToScreen($h, [ref]$pt)) { return $false }

  $dpi = [DshWin]::GetDpiForWindow($h)
  if ($dpi -le 0) { $dpi = 96 }
  $script:dpiScale = $dpi / 96.0
  $script:clientX = $pt.X / $script:dpiScale
  $script:clientY = $pt.Y / $script:dpiScale
  $script:clientW = $rc.R / $script:dpiScale
  $script:clientH = $rc.B / $script:dpiScale
  return $true
}

function Toggle-Mode {
  $size = Current-Size
  $old = $size
  if ($script:mode -eq 'ball') {
    $script:mode = 'card'
    $newW = [math]::Round($BASE_W * $script:zoom)
    $newH = [math]::Round($BASE_H * $script:zoom)
    $script:relX = $script:relX + $old[0] - $newW
    $script:relY = $script:relY + $old[1] - $newH
  } else {
    $script:mode = 'ball'
    $script:relX = $script:relX + $old[0] - $script:ballSize
    $script:relY = $script:relY + $old[1] - $script:ballSize
  }
  Apply-Mode
  Save-Position
}

function Set-Zoom([double]$z) {
  if ($z -lt 0.8) { $z = 0.8 }
  if ($z -gt 1.8) { $z = 1.8 }
  if ([math]::Abs($z - $script:zoom) -lt 0.01) { return }
  $old = Current-Size
  $script:zoom = $z
  $new = @([math]::Round($BASE_W * $script:zoom), [math]::Round($BASE_H * $script:zoom))
  $script:relX = $script:relX + $old[0] - $new[0]
  $script:relY = $script:relY + $old[1] - $new[1]
  Apply-Mode
  Save-Position
}

# ---------------- 更新数据 ----------------
function Render-Bars($state) {
  $chartHost.Children.Clear()
  $days = @($state.days)
  if ($days.Count -eq 0) { return }
  $days = @($days | Select-Object -Last 7)
  $max = ($days | Measure-Object -Property cost -Maximum).Maximum
  if (-not $max -or $max -le 0) { $max = 1 }
  $count = @($days).Count
  $colWidth = [Math]::Floor((344 - ($count * 4)) / [Math]::Max($count, 1))
  $todayKey = (Get-Date).ToString('yyyy-MM-dd')
  for ($i = 0; $i -lt $count; $i++) {
    $d = $days[$i]
    $col = New-Object System.Windows.Controls.StackPanel
    $col.Width = $colWidth
    $col.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
    $col.HorizontalAlignment = 'Center'

    $cost = [double]$d.cost
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = if ($cost -ge 10) { '¥{0:0.#}' -f $cost } elseif ($cost -ge 0.1) { '¥{0:0.0}' -f $cost } elseif ($cost -gt 0) { '¥{0:0.00}' -f $cost } else { '—' }
    $label.FontSize = 9.5
    $label.HorizontalAlignment = 'Center'
    $label.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString('#8C95AB'))
    $col.Children.Add($label) | Out-Null

    $barBox = New-Object System.Windows.Controls.Border
    $barBox.Height = 50
    $barBox.VerticalAlignment = 'Bottom'
    $barBox.Background = [System.Windows.Media.Brushes]::Transparent
    $bar = New-Object System.Windows.Controls.Border
    $bar.CornerRadius = New-Object System.Windows.CornerRadius(5, 5, 2, 2)
    $h = [Math]::Max(3, [Math]::Round(44 * ($cost / $max)))
    $bar.Height = $h
    $bar.VerticalAlignment = 'Bottom'
    $bar.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = New-Object System.Windows.Point(0, 0)
    $grad.EndPoint = New-Object System.Windows.Point(0, 1)
    if ($d.date -eq $todayKey) {
      $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString('#5AD1FF'), 0)))
      $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'), 1)))
    } else {
      $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString('#4C6EF5'), 0)))
      $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString('#2B3A8F'), 1)))
    }
    $bar.Background = $grad
    $barBox.Child = $bar
    $col.Children.Add($barBox) | Out-Null

    $dayLabel = New-Object System.Windows.Controls.TextBlock
    $dt = [datetime]::ParseExact($d.date, 'yyyy-MM-dd', $null)
    $dayLabel.Text = if ($d.date -eq $todayKey) { '今天' } else { $dt.ToString('MM/dd') }
    $dayLabel.FontSize = 9.5
    $dayLabel.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $dayLabel.HorizontalAlignment = 'Center'
    $dayLabel.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($d.date -eq $todayKey) { '#9FD8FF' } else { '#5E6779' })))
    $col.Children.Add($dayLabel) | Out-Null

    $chartHost.Children.Add($col) | Out-Null
  }
}

function Update-View {
  $state = Read-State
  if (-not $state) { return }
  $root.FindName('TodayCost').Text = Format-Money ([double]$state.today.cost)
  $root.FindName('TodayTokens').Text = ('{0} tok' -f (Format-Tokens ([double]$state.today.tokens)))
  $root.FindName('TodayCalls').Text = ('{0:N0} 次调用' -f [double]$state.today.calls)
  $root.FindName('MonthText').Text = ('本月 {0} · 累计 {1}' -f (Format-Money ([double]$state.month.cost)), (Format-Money ([double]$state.all.cost)))
  $root.FindName('StampText').Text = ('{0:HH:mm} 更新' -f (Get-Date))
  $root.FindName('BallCost').Text = Format-Ball ([double]$state.today.cost)

  $now = Get-Date
  $peak = ($now.DayOfWeek -ne 'Saturday' -and $now.DayOfWeek -ne 'Sunday') -and (($now.Hour -ge 9 -and $now.Hour -lt 12) -or ($now.Hour -ge 14 -and $now.Hour -lt 18))
  $root.FindName('PeakText').Text = if ($peak) { '峰值时段' } else { '空闲时段' }
  $root.FindName('PeakText').Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($peak) { '#F0B35B' } else { '#6EE7B7' })))
  Render-Bars $state
}

# 小球的右键菜单
$cm = New-Object System.Windows.Controls.ContextMenu
$miRefresh = New-Object System.Windows.Controls.MenuItem
$miRefresh.Header = '立即刷新'
$miRefresh.Add_Click({ Invoke-Collect; Update-View })
$miQuit = New-Object System.Windows.Controls.MenuItem
$miQuit.Header = '退出悬浮窗'
$miQuit.Add_Click({ Save-Position; $win.Close() })
$cm.Items.Add($miRefresh) | Out-Null
$cm.Items.Add($miQuit) | Out-Null
[System.Windows.Controls.ContextMenuService]::SetContextMenu($ballEl, $cm)

# ---------------- 交互 ----------------
$script:p0 = $null
$script:moved = $false
$script:dragging = $false

$ballEl.Add_MouseLeftButtonDown({
  $script:p0 = [System.Windows.Forms.Cursor]::Position
  $script:moved = $false
})
$ballEl.Add_MouseMove({
  if ($script:dragging) { return }
  if ($script:p0 -and [System.Windows.Input.Mouse]::LeftButton -eq 'Pressed') {
    $p = [System.Windows.Forms.Cursor]::Position
    if (-not $script:moved -and ([math]::Abs($p.X - $script:p0.X) -gt 3 -or [math]::Abs($p.Y - $script:p0.Y) -gt 3)) {
      $script:moved = $true
      $script:dragging = $true
      try { $win.DragMove() } finally { $script:dragging = $false }
      if ($script:clientW -gt 0) {
        $script:relX = $win.Left - $script:clientX
        $script:relY = $win.Top - $script:clientY
        Clamp-Rel
        Place-Window
        Save-Position
      }
    }
  }
})
$ballEl.Add_MouseLeftButtonUp({
  if (-not $script:moved) { Toggle-Mode }
  $script:p0 = $null
})

# 卡片任意位置都能拖动（按钮、缩放热区会自己把事件处理掉，不会触发拖动）
$card.Add_MouseLeftButtonDown({
  param($s, $e)
  $script:dragging = $true
  try { $win.DragMove() } finally { $script:dragging = $false }
  if ($script:clientW -gt 0) {
    $script:relX = $win.Left - $script:clientX
    $script:relY = $win.Top - $script:clientY
    Clamp-Rel
    Place-Window
    Save-Position
  }
})
$root.FindName('CollapseBtn').Add_Click({ Toggle-Mode })
$root.FindName('OfficialBtn').Add_Click({ Start-Process 'https://platform.deepseek.com/usage' })
$link = $root.FindName('OfficialLink')
$link.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$link.Add_MouseLeftButtonUp({ Start-Process 'https://platform.deepseek.com/usage' })
$link.Add_MouseEnter({ param($s, $e) $s.TextDecorations = [System.Windows.TextDecorations]::Underline })
$link.Add_MouseLeave({ param($s, $e) $s.TextDecorations = $null })
$root.FindName('RefreshBtn').Add_Click({ Invoke-Collect; Update-View })

# 四边 + 四角缩放：靠近边缘时鼠标自动变成双向箭头
$script:resizing = $false
$script:corner = 'se'
$script:resizeStart = $null
$script:resizeZoom = 1.0
$script:resizeLeft = 0.0
$script:resizeTop = 0.0
$script:resizeW = 380.0
$script:resizeH = 252.0

$gripDown = {
  param($s, $e)
  if ($script:mode -ne 'card') { return }
  if (-not $s.Tag) { return }
  $script:resizing = $true
  $script:corner = [string]$s.Tag
  $script:resizeStart = [System.Windows.Forms.Cursor]::Position
  $script:resizeZoom = $script:zoom
  $script:resizeLeft = $win.Left
  $script:resizeTop = $win.Top
  $script:resizeW = $win.Width
  $script:resizeH = $win.Height
  $s.CaptureMouse() | Out-Null
  $e.Handled = $true
}
$gripMove = {
  param($s, $e)
  if (-not $script:resizing) { return }
  $p = [System.Windows.Forms.Cursor]::Position
  $dx = ($p.X - $script:resizeStart.X) / $script:dpiScale
  $dy = ($p.Y - $script:resizeStart.Y) / $script:dpiScale
  $dir = $script:corner
  $east = @('e', 'ne', 'se') -contains $dir
  $west = @('w', 'nw', 'sw') -contains $dir
  $south = @('s', 'se', 'sw') -contains $dir
  $north = @('n', 'ne', 'nw') -contains $dir
  $dw = 0.0; $dh = 0.0
  if ($east) { $dw = $dx } elseif ($west) { $dw = -$dx }
  if ($south) { $dh = $dy } elseif ($north) { $dh = -$dy }
  $fx = 1.0
  $fy = 1.0
  if ($east -or $west) { $fx = ($script:resizeW + $dw) / $script:resizeW }
  if ($south -or $north) { $fy = ($script:resizeH + $dh) / $script:resizeH }
  $factor = [math]::Max($fx, $fy)
  $z = $script:resizeZoom * $factor
  if ($z -lt 0.8) { $z = 0.8 }
  if ($z -gt 1.8) { $z = 1.8 }
  if ([math]::Abs($z - $script:zoom) -lt 0.004) { return }
  $script:zoom = $z
  $newW = [math]::Round($BASE_W * $z)
  $newH = [math]::Round($BASE_H * $z)
  $cardScale.ScaleX = $z
  $cardScale.ScaleY = $z
  $win.Width = $newW
  $win.Height = $newH
  $startR = $script:resizeLeft + $script:resizeW
  $startB = $script:resizeTop + $script:resizeH
  if ($west) { $l = $startR - $newW } else { $l = $script:resizeLeft }
  if ($north) { $t = $startB - $newH } else { $t = $script:resizeTop }
  $l = [math]::Max($script:clientX + $MARGIN, [math]::Min($l, $script:clientX + $script:clientW - $newW - $MARGIN))
  $t = [math]::Max($script:clientY + $MARGIN, [math]::Min($t, $script:clientY + $script:clientH - $newH - $MARGIN))
  $win.Left = $l
  $win.Top = $t
  $e.Handled = $true
}
$gripUp = {
  param($s, $e)
  if ($script:resizing) {
    $script:resizing = $false
    try { $s.ReleaseMouseCapture() } catch {}
    $script:relX = $win.Left - $script:clientX
    $script:relY = $win.Top - $script:clientY
    Clamp-Rel
    Place-Window
    Save-Position
  }
}
foreach ($zone in @($card.Child.Children)) {
  if ($zone -is [System.Windows.Controls.Border] -and $zone.Tag) {
    $zone.Add_MouseLeftButtonDown($gripDown)
    $zone.Add_MouseMove($gripMove)
    $zone.Add_MouseLeftButtonUp($gripUp)
  }
}
# ---------------- 命中测试（离屏，不显示窗口） ----------------
if ($HitTest) {
  $card.Visibility = 'Visible'
  $ballEl.Visibility = 'Collapsed'
  $cardScale.ScaleX = 1
  $cardScale.ScaleY = 1
  $card.Measure([System.Windows.Size]::new(380, 252))
  $card.Arrange([System.Windows.Rect]::new(0, 0, 380, 252))
  $card.UpdateLayout()
  $points = @(
    @(190, 3, 'top'), @(190, 249, 'bottom'), @(3, 126, 'left'), @(377, 126, 'right'),
    @(6, 6, 'nw'), @(374, 6, 'ne'), @(6, 246, 'sw'), @(374, 246, 'se'), @(190, 126, 'center')
  )
  foreach ($pt in $points) {
    $res = [System.Windows.Media.VisualTreeHelper]::HitTest($card, [System.Windows.Point]::new($pt[0], $pt[1]))
    $hit = if ($res) { $res.VisualHit } else { $null }
    $tag = ''
    $node = $hit
    while ($null -ne $node) {
      if ($node -is [System.Windows.FrameworkElement] -and $node.Tag) { $tag = [string]$node.Tag; break }
      $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    $type = if ($hit) { $hit.GetType().Name } else { 'null' }
    Write-Output ("point {0},{1} ({2}) -> {3} tag={4}" -f $pt[0], $pt[1], $pt[2], $type, $tag)
  }
  return
}
# ---------------- 预览 ----------------
if ($Preview) {
  Invoke-Collect
  Update-View

  function Render-Element($element, [int]$w, [int]$h, [double]$scale) {
    $element.Visibility = 'Visible'
    $element.Measure([System.Windows.Size]::new($w, $h))
    $element.Arrange([System.Windows.Rect]::new(0, 0, $w, $h))
    $element.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($element)
    return $rtb
  }

  $card.Visibility = 'Visible'
  $cardScale.ScaleX = 1; $cardScale.ScaleY = 1
  $cardImg = Render-Element $card 380 252 1
  $card.Visibility = 'Collapsed'
  $ballImg = Render-Element $ballEl 64 64 1

  $pad = 24
  $w = 380 + 64 + $pad * 3
  $h = 252 + $pad * 2
  $bg = New-Object System.Windows.Media.DrawingVisual
  $dc = $bg.RenderOpen()
  $brush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(11, 13, 18))
  $dc.DrawRectangle($brush, $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
  $dc.DrawImage($ballImg, (New-Object System.Windows.Rect($pad, $pad, 64, 64)))
  $dc.DrawImage($cardImg, (New-Object System.Windows.Rect(($pad * 2 + 64), $pad, 380, 252)))
  $dc.Close()

  $final = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $final.Render($bg)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($final))
  $out = if ($PreviewPath) { $PreviewPath } else { Join-Path $here 'preview.png' }
  $fs = [System.IO.File]::Create($out)
  $enc.Save($fs)
  $fs.Close()
  Write-Output "preview -> $out"
  return
}

# ---------------- 常驻 ----------------
if ($Collect) { Invoke-Collect }
Update-View

# 先找到 DSH 窗口，设成 owner，再定位显示
$found = Measure-Dsh
if ($found) {
  $size = Current-Size
  if ($script:relX -eq 16 -and $script:relY -eq 16) {
    $script:relX = [math]::Max($MARGIN, $script:clientW - $size[0] - 18)
    $script:relY = [math]::Max($MARGIN, $script:clientH - $size[1] - 18)
  }
  $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
  $helper.Owner = $script:dsh
  $script:ownerSet = $true
  $script:ownerHwnd = $script:dsh
}
Apply-Mode
Write-Log ('startup dpiScale={0} client=({1},{2}) {3}x{4} mode={5} zoom={6} rel=({7},{8})' -f $script:dpiScale, $script:clientX, $script:clientY, $script:clientW, $script:clientH, $script:mode, $script:zoom, $script:relX, $script:relY)
if ($found) {
  $win.Opacity = 0
  $win.Show() | Out-Null
  $null = Measure-Dsh
  Apply-Mode
  $win.Opacity = 1
} else { Write-Log 'DSH window not found; waiting' }

# 跟随 DSH 窗口：移动/缩放/最小化都跟着
$follow = New-Object System.Windows.Threading.DispatcherTimer
$follow.Interval = [TimeSpan]::FromMilliseconds(400)
$follow.Add_Tick({
  if ($script:resizing -or $script:dragging) { return }
  $ok = Measure-Dsh
  if (-not $ok) { if ($win.IsVisible) { $win.Hide() }; return }
  if ((-not $script:ownerSet) -or ($script:ownerHwnd -ne $script:dsh)) {
    try {
      $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
      $helper.Owner = $script:dsh
      $script:ownerSet = $true
      $script:ownerHwnd = $script:dsh
    } catch {}
  }
  if (-not $win.IsVisible) { $win.Show() | Out-Null }
  Place-Window
})
$follow.Start()

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([int]$config.refreshSeconds)
$timer.Add_Tick({ Update-View })
$timer.Start()

$collectTimer = New-Object System.Windows.Threading.DispatcherTimer
$collectTimer.Interval = [TimeSpan]::FromSeconds([int]$config.collectSeconds)
$collectTimer.Add_Tick({ Invoke-Collect })
$collectTimer.Start()

$win.Add_Closing({ $timer.Stop(); $collectTimer.Stop(); $follow.Stop(); Save-Position })
$win.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
[System.Windows.Threading.Dispatcher]::Run()

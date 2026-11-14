# ui.ps1 - ventana del buscador (la carga finder.ps1; usa sus funciones y variables)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Identidad propia en la barra de tareas (si no, se agrupa con PowerShell y muestra su ícono)
try {
    Add-Type -Name AppId -Namespace L4dShell -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);'
    [void][L4dShell.AppId]::SetCurrentProcessExplicitAppUserModelID('L4D2.BuscadorDeVersus')
} catch {}
# Una sola app abierta por PC. Con dos abiertas, cada una avisaba algo distinto al grupo y se pisaban (el
# grupo "parpadeaba" cada 9 min y sonaba en todas las apps), y las dos le mandaban órdenes al juego.
# Si ya hay una abierta, se la trae adelante y esta se cierra. Al reiniciar por una actualización, la
# nueva espera a que la vieja termine de cerrarse.
if (-not $Screenshot -and -not $env:L4D2_TEST_NOGROUP) {
    $script:instanceMutex = New-Object Threading.Mutex($false, 'Local\L4D2.BuscadorDeVersus')
    $owned = $false
    $waitMs = if ($env:L4D2_RESTART) { 20000 } else { 0 }
    Remove-Item Env:\L4D2_RESTART -ErrorAction SilentlyContinue
    try { $owned = $script:instanceMutex.WaitOne($waitMs) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        try {
            Add-Type -Name Front -Namespace L4dShell -MemberDefinition ('[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);' +
                '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);' +
                '[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);')
            $other = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -like 'Buscador de versus*' } | Select-Object -First 1
            if ($other) {
                if ([L4dShell.Front]::IsIconic($other.MainWindowHandle)) { [void][L4dShell.Front]::ShowWindow($other.MainWindowHandle, 9) }
                [void][L4dShell.Front]::SetForegroundWindow($other.MainWindowHandle)
            }
        } catch {}
        [Environment]::Exit(0)
    }
}
if (-not ('L4dShell.Redraw' -as [type])) {
    Add-Type -Name Redraw -Namespace L4dShell -MemberDefinition ('[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);' +
        '[DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr rgn, uint flags);' +
        '[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);' +
        '[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);')
}
. (Join-Path $here 'vpk.ps1')
[Windows.Forms.Application]::EnableVisualStyles()

$settings = Get-Settings
$mapDir = Join-Path $here 'mapas'
New-Item -ItemType Directory -Force $mapDir | Out-Null
# Mapas custom: lo aprendido (campaña/mapa -> Workshop) se guarda en mapas\custom.json
$customFile = Join-Path $mapDir 'custom.json'
$script:customIx = Get-CustomIndex $customFile
$script:wsPending = @{}   # portadas que faltan bajar
$script:wsTried = @{}     # ya intentadas en esta sesion (para no reintentar en bucle)

# Registro de eventos (eventos.log, al lado de la app): que vio, que decidio y que ordenes le mando al juego.
# Sirve para entender bugs que pasan jugando (p. ej. "me saco del server"). Se recorta solo al pasar 1 MB.
$logFile = Join-Path $here 'eventos.log'
function Write-AppLog([string]$msg) {
    if ($Screenshot) { return }
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile (Join-Path $here 'eventos.anterior.log') -Force }
        [IO.File]::AppendAllText($logFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
Write-AppLog "=== App abierta (v$AppVersion). Seguir=$([bool]$settings.SteamFollow) a $($settings.FollowSteamId); compartir=$([bool]$settings.Share)"

# ---------------- trabajo en segundo plano ----------------
# Todo lo que espera a internet o lee archivos grandes corre en otro hilo, asi la ventana
# nunca queda "No responde". Cuando termina, el resultado se procesa en la ventana.
$iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in 'Get-Topic', 'Get-SidHash', 'Send-SteamBroadcast', 'Receive-SteamBroadcasts', 'Get-SteamStatus',
    'Get-LocalFriends', 'Get-ApiKey', 'Find-L4D2Path', 'Read-VpkIndex', 'Read-VpkFile', 'Export-MapImages', 'Export-Spinner', 'Export-UiArt', 'Get-LobbyJson',
    'Receive-NtfyMessages', 'Send-FollowSignal', 'Get-GroupHashes', 'Get-SteamAvatars', 'Get-WorkshopImages', 'Get-InstalledAddonMaps',
    'Install-Update', 'Get-MySteamId', 'Start-LobbyHelper', 'Receive-LobbyHelper') {
    $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($fn, (Get-Item "function:$fn").Definition)))
}
foreach ($v in 'presenceTopic', 'followTopic', 'keyFile') {
    $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry($v, (Get-Variable $v -ValueOnly), '')))
}
$pool = [RunspaceFactory]::CreateRunspacePool(1, 4, $iss, $Host)
$pool.Open()
$script:jobs = New-Object System.Collections.ArrayList
$script:busy = @{}

# Lectores de "una línea por evento" (la salida del vigía de Steam, la conexión abierta con ntfy.sh): leen
# en otro hilo y entregan cada línea a la ventana apenas llega, así la app reacciona a eventos en vez de
# preguntar cada tanto.
if (-not ('L4dLines' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Threading;
using System.Windows.Forms;
public class L4dLines {
    volatile bool stop;
    WebResponse resp;
    public static L4dLines FromReader(TextReader r, Control ui, Action<string> onLine, Action<string> onEnd) {
        var x = new L4dLines();
        var t = new Thread(() => x.Loop(r, ui, onLine, onEnd));
        t.IsBackground = true; t.Start();
        return x;
    }
    // idleMs: si no llega nada (ni el "sigo acá" de ntfy, cada 45 s) en ese tiempo, la conexión se da por muerta
    public static L4dLines FromUrl(string url, int idleMs, Control ui, Action<string> onLine, Action<string> onEnd) {
        var x = new L4dLines();
        var t = new Thread(() => {
            TextReader r;
            try {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = 15000; req.ReadWriteTimeout = idleMs; req.UserAgent = "l4d2-finder";
                x.resp = req.GetResponse();
                r = new StreamReader(x.resp.GetResponseStream());
            } catch (Exception e) { if (!x.stop) Post(ui, onEnd, e.Message); return; }
            x.Loop(r, ui, onLine, onEnd);
        });
        t.IsBackground = true; t.Start();
        return x;
    }
    void Loop(TextReader r, Control ui, Action<string> onLine, Action<string> onEnd) {
        string err = "";
        try { string l; while (!stop && (l = r.ReadLine()) != null) { if (!Post(ui, onLine, l)) return; } }
        catch (Exception e) { err = e.Message; }
        if (!stop) Post(ui, onEnd, err);
    }
    static bool Post(Control ui, Action<string> a, string s) {
        try { if (ui.IsDisposed) return false; ui.BeginInvoke(a, s); return true; } catch { return false; }
    }
    public void Stop() { stop = true; try { if (resp != null) resp.Close(); } catch { } }
}
"@
}
[Net.ServicePointManager]::DefaultConnectionLimit = 16
# Tarjeta que, una vez armada, se pinta copiando su imagen directo a la pantalla (BitBlt): es lo más rápido
# que hay en Windows, y así al scrollear rápido (incluso maximizada) no quedan rayas.
if (-not ('L4dCard' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class L4dCard : Panel {
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    IntPtr face = IntPtr.Zero;
    public L4dCard() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true); }
    public void SetFace(Bitmap b) {
        Free();
        face = b.GetHbitmap(Color.Black);
        SetStyle(ControlStyles.Opaque, true);
        Invalidate();
    }
    protected override void OnPaintBackground(PaintEventArgs e) { if (face == IntPtr.Zero) base.OnPaintBackground(e); }
    protected override void OnPaint(PaintEventArgs e) {
        if (face == IntPtr.Zero) { base.OnPaint(e); return; }
        Rectangle r = e.ClipRectangle;
        IntPtr hdc = e.Graphics.GetHdc();
        try {
            IntPtr mem = CreateCompatibleDC(hdc);
            IntPtr old = SelectObject(mem, face);
            BitBlt(hdc, r.X, r.Y, r.Width, r.Height, mem, r.X, r.Y, 0x00CC0020);
            SelectObject(mem, old);
            DeleteDC(mem);
        } finally { e.Graphics.ReleaseHdc(hdc); }
    }
    void Free() { if (face != IntPtr.Zero) { DeleteObject(face); face = IntPtr.Zero; } }
    protected override void Dispose(bool disposing) { Free(); base.Dispose(disposing); }
}
"@
}   # la conexión abierta con ntfy no debe trabar los avisos que mandamos

# Corre $work en segundo plano (uno a la vez por nombre) y despues llama $done con (resultado, error)
function Start-Async([string]$name, [scriptblock]$work, [object[]]$argv, [scriptblock]$done) {
    if ($script:busy[$name]) { return }
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($work.ToString())
    foreach ($a in $argv) { [void]$ps.AddArgument($a) }
    $script:busy[$name] = $true
    [void]$script:jobs.Add(@{ Name = $name; PS = $ps; H = $ps.BeginInvoke(); Done = $done; Started = Get-Date })
    $pumpTimer.Start()   # solo corre mientras haya algo en segundo plano
}

function Get-First($res) {
    if ($null -eq $res -or $res.Count -eq 0) { return $null }
    $x = $res[0]
    if ($x -is [Management.Automation.PSObject] -and $x.BaseObject -is [hashtable]) { $x = $x.BaseObject }
    return $x
}

$pumpTimer = New-Object Windows.Forms.Timer
$pumpTimer.Interval = 150
$script:searchState = $null
$pumpTimer.add_Tick({
        if ($script:busy['servers'] -and $script:searchState -and $status.Text -ne $script:searchState.Msg) { $status.Text = $script:searchState.Msg }
        if ($script:busy['servers'] -and $script:searchState -and $script:searchState.Msg -ne $script:searchLogged) {
            $script:searchLogged = $script:searchState.Msg
            Write-AppLog "Búsqueda: $($script:searchLogged)"
        }
        for ($i = $script:jobs.Count - 1; $i -ge 0; $i--) {
            $j = $script:jobs[$i]
            if (-not $j.H.IsCompleted) {
                # Una búsqueda que no termina en 2 min se da por trabada: se corta y se avisa en qué paso quedó
                # (antes la ruedita quedaba girando para siempre)
                if ($j.Name -in 'servers', 'lobbies' -and ((Get-Date) - $j.Started).TotalSeconds -gt 120) {
                    $script:jobs.RemoveAt($i); $script:busy[$j.Name] = $false
                    $step = if ($j.Name -eq 'servers' -and $script:searchState) { $script:searchState.Msg } else { '' }
                    Write-AppLog "Búsqueda [$($j.Name)] trabada más de 2 min (paso: '$step'): la corto."
                    try { [void]$j.PS.BeginStop($null, $null) } catch {}
                    try { & $j.Done $null "La búsqueda se trabó ($step). Probá de nuevo; si sigue pasando, mandame eventos.log." } catch {}
                }
                continue
            }
            $script:jobs.RemoveAt($i)
            $script:busy[$j.Name] = $false
            $res = $null; $err = $null
            try {
                $res = $j.PS.EndInvoke($j.H)
                if ($j.PS.Streams.Error.Count) { $err = $j.PS.Streams.Error[0].Exception.Message }
            } catch {
                $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
                $err = $e.Message
            } finally { $j.PS.Dispose() }
            if ($err) { Write-AppLog "Error en segundo plano [$($j.Name)]: $err" }
            if ($j.Name -in 'servers', 'lobbies') { Write-AppLog ("Búsqueda [{0}] terminó en {1:N0} s: {2}" -f $j.Name, ((Get-Date) - $j.Started).TotalSeconds, $(if ($err) { 'con error' } elseif ($j.Name -eq 'servers') { "$(@($res).Count) servers" } else { 'ok' })) }
            try { & $j.Done $res $err } catch { Write-AppLog "Error [$($j.Name)]: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"; if ($Screenshot) { [IO.File]::AppendAllText("$Screenshot.error.txt", "[$($j.Name)] $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())`r`n") } }
        }
        if ($script:jobs.Count -eq 0) { $this.Stop() }
    })

# La busqueda de servers corre en la ventana, pero atiende a Windows mientras espera respuestas
$Pump = { [Windows.Forms.Application]::DoEvents() }

# ---------------- estilo ----------------
function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
# Colores al estilo del menu de L4D2: negros calidos, texto hueso y rojo sangre
$C = @{
    Bg = RGB 17 16 15; Panel = RGB 28 27 25; Card = RGB 34 33 31; CardHi = RGB 54 52 49
    Text = RGB 234 229 219; Dim = RGB 152 147 138; Input = RGB 12 12 11
    Accent = RGB 158 22 22; AccentHi = RGB 198 34 30
    Green = RGB 104 190 92; Amber = RGB 228 168 60; Gray = RGB 112 108 102; Orange = RGB 230 106 52
    Blue = RGB 122 160 214
}

# Fuentes del juego: Trade Gothic (la de los menus) y Stubble (la de los titulos). Salen de
# left4dead2\resource\*.vfont la primera vez (mapas\fuentes). Si no estan, se usa Segoe UI.
$fontDir = Join-Path $mapDir 'fuentes'
if (-not (Test-Path (Join-Path $fontDir 'tgb.ttf'))) { try { $gp = Find-L4D2Path; if ($gp) { [void](Export-GameFonts $gp $fontDir) } } catch {} }
if (-not ('L4dFontReg' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class L4dFontReg {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResourceEx(string file, uint fl, IntPtr res);
}
"@
}
# GDI+ (PrivateFontCollection) arma la fuente y GDI (AddFontResourceEx privado) la dibuja en los controles
$gameFonts = New-Object Drawing.Text.PrivateFontCollection
foreach ($n in 'tgb', 'tg', 'stubble-bold') {
    $p = Join-Path $fontDir "$n.ttf"
    if (Test-Path $p) { try { $gameFonts.AddFontFile($p); [void][L4dFontReg]::AddFontResourceEx($p, 0x10, [IntPtr]::Zero) } catch {} }
}
$fontFam = @{}
foreach ($ff in $gameFonts.Families) { $fontFam[$ff.Name] = $ff }
function New-GameFont([string]$name, [single]$size, [string]$fallback, [single]$fallbackSize) {
    if ($fontFam[$name]) { return New-Object Drawing.Font($fontFam[$name], $size, [Drawing.FontStyle]::Regular) }
    return New-Object Drawing.Font($fallback, $fallbackSize)
}
$F = @{
    Title = New-GameFont 'Stubble bold' 19 'Segoe UI Semibold' 16
    Sub   = New-GameFont 'TradeGothic' 10 'Segoe UI' 9
    H     = New-GameFont 'Trade Gothic Bold' 15 'Segoe UI Semibold' 12.5
    Body  = New-GameFont 'TradeGothic' 10.5 'Segoe UI' 9.5
    Small = New-GameFont 'TradeGothic' 10 'Segoe UI' 8.75
    Chip  = New-GameFont 'Trade Gothic Bold' 9 'Segoe UI Semibold' 8.25
    Ping  = New-GameFont 'Trade Gothic Bold' 16 'Segoe UI Semibold' 13
    Btn   = New-GameFont 'Trade Gothic Bold' 12 'Segoe UI Semibold' 10
    Slots = New-GameFont 'Trade Gothic Bold' 27 'Segoe UI Semibold' 21
    SlotsSub = New-GameFont 'Trade Gothic Bold' 10 'Segoe UI Semibold' 8.5
}
$script:gameLook = [bool]$fontFam['Trade Gothic Bold']   # con las fuentes del juego, titulos y botones en mayusculas
function Get-UiText([string]$s) { if ($script:gameLook) { return $s.ToUpper() } return $s }

# ($campaigns y Get-CampaignKey vienen de finder.ps1)

function Get-MapTitle([string]$map) {
    if ($map -match '^(c\d+)m(\d+)_' -and $campaigns.Contains($Matches[1])) {
        return "$($campaigns[$Matches[1]])  ·  Capítulo $($Matches[2])"
    }
    return $map
}

$script:imgCache = @{}
function Get-MapImage([string]$map) {
    $cands = @($map.ToLower())
    if ($map -match '^(c\d+)m') { $cands += $Matches[1].ToLower() }
    foreach ($k in $campaigns.Keys) { if ($map -like "*$($campaigns[$k])*") { $cands += $k } }   # servers que informan el nombre lindo
    foreach ($n in $cands) {
        if ($n -notmatch '^[a-z0-9_]+$') { continue }   # nombres raros (con : o []) no son archivos
        if ($script:imgCache.ContainsKey($n)) { return $script:imgCache[$n] }
        $imgFile = [IO.Path]::Combine($mapDir, "$n.png")
        if (-not [IO.File]::Exists($imgFile)) { $imgFile = [IO.Path]::Combine($mapDir, "$n.jpg") }   # portadas de la Workshop
        if ([IO.File]::Exists($imgFile)) {
            try {
                $img = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($imgFile))))
                $script:imgCache[$n] = $img
                return $img
            } catch { return $null }   # puede estar a medio escribir mientras se extraen las imagenes
        }
    }
    return $null
}

function New-Text([string]$text, $font, $color) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [Drawing.Color]::Transparent
    $l.AutoSize = $true
    return $l
}

function New-FlatButton([string]$text, $bg, $hover, [int]$w, [int]$h) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Font = $F.Btn; $b.ForeColor = $C.Text; $b.BackColor = $bg
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $hover; $b.FlatAppearance.MouseDownBackColor = $hover
    $b.Size = New-Object Drawing.Size($w, $h); $b.Cursor = 'Hand'
    return $b
}

function New-Chip([string]$text, $bg, $fg) {
    $l = New-Text $text $F.Chip $fg
    $l.BackColor = $bg
    $l.Padding = New-Object Windows.Forms.Padding(6, 2, 6, 2)
    $l.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 0)
    return $l
}

function Set-Dark($ctrl) {
    $ctrl.BackColor = $C.Input; $ctrl.ForeColor = $C.Text; $ctrl.Font = $F.Body
    if ($ctrl -is [Windows.Forms.TextBox] -or $ctrl -is [Windows.Forms.NumericUpDown]) { $ctrl.BorderStyle = 'FixedSingle' }
}

function New-Row([int]$height) {
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Top'; $p.Height = $height; $p.BackColor = $C.Panel; $p.WrapContents = $false
    $p.Padding = New-Object Windows.Forms.Padding(16, 6, 16, 0)
    return $p
}

function New-FieldLabel([string]$text) {
    $l = New-Text $text $F.Body $C.Dim
    $l.Margin = New-Object Windows.Forms.Padding(0, 6, 6, 0)
    return $l
}

# ---------------- ventana ----------------
$form = New-Object Windows.Forms.Form
$form.Text = 'Buscador de versus · L4D2'
$form.Size = New-Object Drawing.Size(1120, 780)
$form.MinimumSize = New-Object Drawing.Size(860, 520)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg; $form.ForeColor = $C.Text; $form.Font = $F.Body

# Encabezado
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 84; $header.BackColor = $C.Panel
$header.Width = $form.ClientSize.Width   # ancho real antes de anclar cosas a la derecha
$header.BackgroundImageLayout = 'None'
$title = New-Text 'BUSCADOR DE VERSUS' $F.Title $C.Text
$title.UseCompatibleTextRendering = $true   # Stubble solo se dibuja bien con GDI+
$title.Location = New-Object Drawing.Point(16, 22)
$subtitle = New-Text 'Left 4 Dead 2  ·  servers con lugar para tu grupo' $F.Sub $C.Dim
$subtitle.Location = New-Object Drawing.Point(19, 44)
$btnSearch = New-FlatButton (Get-UiText 'Buscar') $C.Accent $C.AccentHi 140 38
$btnSearch.Anchor = 'Top, Right'
$btnSearch.Location = New-Object Drawing.Point(($form.ClientSize.Width - 156), 12)
$chkAuto = New-Object Windows.Forms.CheckBox
$chkAuto.Text = 'Actualizar sola'; $chkAuto.AutoSize = $true; $chkAuto.ForeColor = $C.Dim
$chkAuto.BackColor = [Drawing.Color]::Transparent; $chkAuto.Checked = [bool]$settings.AutoRefresh
$chkAuto.Anchor = 'Top, Right'
$chkAuto.Font = $F.Small
$chkAuto.Location = New-Object Drawing.Point(($form.ClientSize.Width - 154), 52)   # debajo de Buscar
# Que buscar: partidas en curso (servers) o salas de espera (lobbies de Steam)
$btnViewServers = New-FlatButton (Get-UiText 'Partidas en curso') $C.Input $C.CardHi 176 32
$btnViewLobbies = New-FlatButton (Get-UiText 'Salas de espera') $C.Input $C.CardHi 164 32
$btnViewServers.Location = New-Object Drawing.Point(400, 20)
$btnViewLobbies.Location = New-Object Drawing.Point(576, 20)

# Fondo del encabezado con arte del juego (mapas\ui_*.png, se extraen la primera vez): una franja del
# fondo del menu oscurecida, el logo a la izquierda y el borde rasgado abajo.
function Get-UiImage([string]$name) {
    $p = Join-Path $mapDir "$name.png"
    if (-not (Test-Path $p)) { return $null }
    try { return [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($p)))) } catch { return $null }
}
function Update-HeaderArt {
    $bg = Get-UiImage 'ui_bg'; $logo = Get-UiImage 'ui_logo'; $edge = Get-UiImage 'ui_edge'
    if (-not $logo) { return }
    $W = 2560; $H = $header.Height
    $bmp = New-Object Drawing.Bitmap($W, $H)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'
    $g.Clear($C.Panel)
    if ($bg) {
        # Franja del cielo/horizonte del fondo del menu, a lo ancho
        $scale = $W / $bg.Width
        $src = New-Object Drawing.RectangleF(0, ($bg.Height * 0.36), $bg.Width, ($H / $scale))
        $g.DrawImage($bg, (New-Object Drawing.RectangleF(0, 0, $W, $H)), $src, 'Pixel')
        $shade = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Point(0, 0)), (New-Object Drawing.Point(1400, 0)), ([Drawing.Color]::FromArgb(235, $C.Panel)), ([Drawing.Color]::FromArgb(200, $C.Panel)))
        $g.FillRectangle($shade, 0, 0, $W, $H)
    }
    if ($edge) {
        # Borde rasgado (blanco en el juego) pintado del color de la fila de abajo
        $ia = New-Object Drawing.Imaging.ImageAttributes
        $cm = New-Object Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = 0; $cm.Matrix11 = 0; $cm.Matrix22 = 0
        $cm.Matrix40 = $C.Panel.R / 255; $cm.Matrix41 = $C.Panel.G / 255; $cm.Matrix42 = $C.Panel.B / 255
        $ia.SetColorMatrix($cm)
        $eh = 16
        for ($x = 0; $x -lt $W; $x += 1024) {
            $g.DrawImage($edge, (New-Object Drawing.Rectangle($x, ($H - $eh), 1024, $eh)), 0, 0, $edge.Width, $edge.Height, 'Pixel', $ia)
        }
    }
    $lh = 54; $lw = [int]($logo.Width * $lh / $logo.Height)
    $g.DrawImage($logo, 16, 9, $lw, $lh)
    $g.Dispose()
    $header.BackgroundImage = $bmp
    $title.Location = New-Object Drawing.Point((28 + $lw), [int](($H - 14 - $title.Height) / 2))   # centrado sobre el borde rasgado
    $x = [math]::Max(400, $title.Right + 30)
    $btnViewServers.Left = $x; $btnViewLobbies.Left = $x + $btnViewServers.Width
}
$btnViewServers.Tag = 'servers'; $btnViewLobbies.Tag = 'lobbies'
$tips = New-Object Windows.Forms.ToolTip
$tips.SetToolTip($chkAuto, 'Actualiza la lista al volver a esta ventana (si tiene más de 2 min) y cuando salís de una partida o sala.')
$tips.SetToolTip($btnViewServers, 'Servers con una partida ya empezada y lugar libre')
$tips.SetToolTip($btnViewLobbies, 'Salas que todavía no arrancaron, como las del buscador del juego')
$header.Controls.AddRange(@($title, $btnViewServers, $btnViewLobbies, $chkAuto, $btnSearch))
Update-HeaderArt

# Ícono de la app: el "4" rojo de L4D2 (el del spinner, sacado del juego) con una lupa blanca en la
# esquina, para que se reconozca como algo de L4D2 sin confundirse con el ícono del juego.
# Se arma una vez en varios tamaños (mapas\app.ico) y se usa en la ventana y la barra de tareas.
function New-AppIconImage([Drawing.Image]$four, [int]$size) {
    $bmp = New-Object Drawing.Bitmap($size, $size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([Drawing.Color]::Transparent)
    $g.DrawImage($four, 0, 0, ($size * 0.84), ($size * 0.84))
    # Lupa: lente blanca con borde oscuro abajo a la derecha, y el mango en diagonal
    $s = [single]$size
    $r = $s * 0.17; $cx = $s * 0.74; $cy = $s * 0.74
    $w = [math]::Max(1.5, $s * 0.075)
    $dark = New-Object Drawing.Pen([Drawing.Color]::FromArgb(230, 12, 12, 11), ($w * 2.2))
    $dark.StartCap = 'Round'; $dark.EndCap = 'Round'
    $white = New-Object Drawing.Pen([Drawing.Color]::White, $w)
    $white.StartCap = 'Round'; $white.EndCap = 'Round'
    $hx1 = $cx + $r * 0.72; $hy1 = $cy + $r * 0.72; $hx2 = $s * 0.97; $hy2 = $s * 0.97
    $g.DrawLine($dark, $hx1, $hy1, $hx2, $hy2)
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(230, 12, 12, 11))), ($cx - $r - $w), ($cy - $r - $w), (2 * ($r + $w)), (2 * ($r + $w)))
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(150, 40, 40, 38))), ($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $g.DrawEllipse($white, ($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $g.DrawLine($white, $hx1, $hy1, ($hx2 - $w * 0.3), ($hy2 - $w * 0.3))
    $g.Dispose()
    return $bmp
}
function Get-AppIcon {
    $ico = Join-Path $mapDir 'app.ico'
    if (-not (Test-Path $ico)) {
        $src = Join-Path $mapDir 'spinner_9.png'
        if (-not (Test-Path $src)) { return $null }
        try {
            $four = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($src))))
            # .ico con una imagen PNG por tamaño
            $sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
            $pngs = foreach ($sz in $sizes) {
                $im = New-AppIconImage $four $sz
                $ms = New-Object IO.MemoryStream
                if ($sz -ge 256) { $im.Save($ms, [Drawing.Imaging.ImageFormat]::Png) }
                else {
                    # Formato clásico (BMP de 32 bits + máscara), que entiende todo Windows y .NET
                    $bd = $im.LockBits((New-Object Drawing.Rectangle(0, 0, $sz, $sz)), 'ReadOnly', 'Format32bppArgb')
                    $px = New-Object byte[] ($bd.Stride * $sz)
                    [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $px, 0, $px.Length)
                    $im.UnlockBits($bd)
                    $w2 = New-Object IO.BinaryWriter($ms)
                    $w2.Write([uint32]40); $w2.Write([int32]$sz); $w2.Write([int32]($sz * 2)); $w2.Write([uint16]1); $w2.Write([uint16]32)
                    $w2.Write([uint32]0); $w2.Write([uint32]0); $w2.Write([int32]0); $w2.Write([int32]0); $w2.Write([uint32]0); $w2.Write([uint32]0)
                    for ($y = $sz - 1; $y -ge 0; $y--) { $w2.Write($px, $y * $bd.Stride, $sz * 4) }
                    $w2.Write((New-Object byte[] ([math]::Ceiling($sz / 32) * 4 * $sz)))
                    $w2.Flush()
                }
                $im.Dispose()
                , $ms.ToArray()
            }
            $out = New-Object IO.MemoryStream
            $bw = New-Object IO.BinaryWriter($out)
            $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
            $offset = 6 + 16 * $sizes.Count
            for ($i = 0; $i -lt $sizes.Count; $i++) {
                $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
                $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
                $bw.Write([uint16]1); $bw.Write([uint16]32)
                $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
                $offset += $pngs[$i].Length
            }
            foreach ($p in $pngs) { $bw.Write($p) }
            $bw.Flush()
            [IO.File]::WriteAllBytes($ico, $out.ToArray())
        } catch { Write-AppLog "No pude armar el ícono: $($_.Exception.Message)"; return $null }
    }
    try { return New-Object Drawing.Icon((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($ico)))) } catch { return $null }
}
function Update-AppIcon { $i = Get-AppIcon; if ($i) { $form.Icon = $i; Update-Shortcut } }

# Acceso directo "Buscador de versus" al lado del .bat: con el ícono de la app (a un .bat no se le puede
# cambiar el ícono), abre sin que parpadee la ventana negra y lleva la misma identidad que la ventana, así
# se puede anclar a la barra de tareas como corresponde. Se rehace si falta o si la carpeta cambió de lugar.
if (-not ('L4dShortcut' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class L4dShortcut {
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f, int n, IntPtr fd, uint fl);
        void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string s);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string s);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string s);
        void GetHotkey(out short k); void SetHotkey(short k);
        void GetShowCmd(out int c); void SetShowCmd(int c);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n, out int i);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string s, int i);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string s, uint r);
        void Resolve(IntPtr h, uint fl);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string s);
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint c); void GetAt(uint i, out PropKey k);
        void GetValue(ref PropKey k, out PropVar v); void SetValue(ref PropKey k, ref PropVar v); void Commit();
    }
    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPersistFile {
        void GetClassID(out Guid g); [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string f, uint m);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string f, bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
    }
    [StructLayout(LayoutKind.Sequential)] struct PropKey { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Sequential)] struct PropVar { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }

    public static void Save(string lnk, string target, string args, string workDir, string icon, string desc, string appId, int showCmd) {
        var link = (IShellLinkW)new ShellLink();
        link.SetPath(target); link.SetArguments(args); link.SetWorkingDirectory(workDir);
        link.SetIconLocation(icon, 0); link.SetDescription(desc); link.SetShowCmd(showCmd);
        var store = (IPropertyStore)link;
        var key = new PropKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        var v = new PropVar { vt = 31, p = Marshal.StringToCoTaskMemUni(appId) };
        try { store.SetValue(ref key, ref v); store.Commit(); } finally { Marshal.FreeCoTaskMem(v.p); }
        ((IPersistFile)link).Save(lnk, true);
        Marshal.ReleaseComObject(link);
    }
    public static string ReadArgs(string lnk) {
        var link = (IShellLinkW)new ShellLink();
        ((IPersistFile)link).Load(lnk, 0);
        var sb = new StringBuilder(2048); link.GetArguments(sb, sb.Capacity);
        Marshal.ReleaseComObject(link);
        return sb.ToString();
    }
}
"@
}
function Update-Shortcut {
    if ($Screenshot -or $env:L4D2_TEST_NOGROUP) { return }
    try {
        $lnk = Join-Path $here 'Buscador de versus.lnk'
        $ico = Join-Path $mapDir 'app.ico'
        if (-not (Test-Path $ico)) { return }
        $finderPath = Join-Path $here 'finder.ps1'
        $lnkArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$finderPath`""
        if ((Test-Path $lnk) -and ([L4dShortcut]::ReadArgs($lnk) -eq $lnkArgs)) { return }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # 7 = arranca minimizada: la consola de PowerShell no llega a verse antes de esconderse
        [L4dShortcut]::Save($lnk, $ps, $lnkArgs, $here, $ico, 'Buscador de versus para Left 4 Dead 2', 'L4D2.BuscadorDeVersus', 7)
        Write-AppLog 'Acceso directo "Buscador de versus" creado.'
    } catch { Write-AppLog "No pude crear el acceso directo: $($_.Exception.Message)" }
}
Update-AppIcon

# Filtros
$filters = New-Row 42
$numParty = New-Object Windows.Forms.NumericUpDown
$numParty.Minimum = 1; $numParty.Maximum = 4; $numParty.Width = 48
$numParty.Value = 1   # no se muestra: lo maneja el grupo (Update-Group); arranca en 1 = solo vos
# "Somos" es solo texto: el tamaño del grupo se calcula solo con quienes te siguen
$lblParty = New-Text '1  (solo vos)' $F.Body $C.Text
$lblParty.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 0)
function Update-PartyLabel {
    $n = if ($script:groupCount -gt 0) { [int]$script:groupCount } else { [int]$numParty.Value }
    $lblParty.Text = if ($n -le 1) { '1  (solo vos)' } else { "$n" }
}
$numPing = New-Object Windows.Forms.NumericUpDown
$numPing.Minimum = 20; $numPing.Maximum = 400; $numPing.Increment = 10; $numPing.Width = 64
$numPing.Value = [math]::Min(400, [math]::Max(20, [int]$settings.MaxPing)); Set-Dark $numPing
$chkBig = New-Object Windows.Forms.CheckBox
$chkBig.Text = 'Incluir servers de más de 8'; $chkBig.AutoSize = $true; $chkBig.ForeColor = $C.Text
$chkBig.Checked = $IncludeBig.IsPresent; $chkBig.Margin = New-Object Windows.Forms.Padding(24, 5, 0, 0)
# Por defecto no se muestran: oficiales sin sala publica (casi siempre "solo amigos") y mutaciones
$chkFriendsOnly = New-Object Windows.Forms.CheckBox
$chkFriendsOnly.Text = 'Incluir solo amigos'; $chkFriendsOnly.AutoSize = $true; $chkFriendsOnly.ForeColor = $C.Text
$chkFriendsOnly.Checked = [bool]$settings.IncludeFriendsOnly; $chkFriendsOnly.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
(New-Object Windows.Forms.ToolTip).SetToolTip($chkFriendsOnly, "Partidas en servers oficiales sin sala pública: casi siempre son de 'solo amigos' o privadas.`nSi entrás directo, el juego te mete igual en una partida de solo amigos.")
$chkMutation = New-Object Windows.Forms.CheckBox
$chkMutation.Text = 'Incluir mutaciones'; $chkMutation.AutoSize = $true; $chkMutation.ForeColor = $C.Text
$chkMutation.Checked = [bool]$settings.IncludeMutations; $chkMutation.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
(New-Object Windows.Forms.ToolTip).SetToolTip($chkMutation, 'Servers versus con mutaciones u otro modo (realismo, Taaannnkk!, etc.).')
# Experimental: primero los servers "ideales" (poco ping y los lugares justos para el grupo, así se llena)
$chkIdeal = New-Object Windows.Forms.CheckBox
$chkIdeal.Text = 'Primero los ideales (experimental)'; $chkIdeal.AutoSize = $true; $chkIdeal.ForeColor = $C.Text
$chkIdeal.Checked = [bool]$settings.PreferIdeal; $chkIdeal.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
(New-Object Windows.Forms.ToolTip).SetToolTip($chkIdeal, "Ordena poniendo primero los que tienen poco ping y justo los lugares que necesitan`n(al entrar ustedes se llena la partida). Los 'seguros' siguen pesando: un 'depende' baja en la lista.")
$lblPing = New-FieldLabel 'Ping máximo'
$lblPing.Margin = New-Object Windows.Forms.Padding(0, 6, 6, 0)
$filters.Controls.AddRange(@($lblPing, $numPing, (New-FieldLabel 'ms'), $chkBig, $chkFriendsOnly, $chkMutation, $chkIdeal))

# Campaña y tipo de server (filtran la ultima busqueda al instante)
$modeBar = New-Row 40
$btnCamp = New-FlatButton 'Todas  ▾' $C.Input $C.CardHi 200 26
$btnCamp.Font = $F.Body; $btnCamp.TextAlign = 'MiddleLeft'
$btnCamp.FlatAppearance.BorderSize = 1; $btnCamp.FlatAppearance.BorderColor = $C.Gray
$menuCamp = New-Object Windows.Forms.ContextMenuStrip
$menuCamp.ShowCheckMargin = $true; $menuCamp.ShowImageMargin = $false
$itemAll = New-Object Windows.Forms.ToolStripMenuItem('Todas las campañas')
[void]$menuCamp.Items.Add($itemAll)
[void]$menuCamp.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$savedCamps = @($settings.Campaigns | Where-Object { $_ })
$campItems = [ordered]@{}
foreach ($k in (@($campaigns.Keys) + 'custom')) {
    $label = if ($k -eq 'custom') { 'Mapas custom / otros' } else { $campaigns[$k] }
    $it = New-Object Windows.Forms.ToolStripMenuItem($label)
    $it.CheckOnClick = $true; $it.Tag = $k; $it.Checked = $savedCamps -contains $k
    [void]$menuCamp.Items.Add($it)
    $campItems[$k] = $it
}
# Que el menu no se cierre en cada clic, asi se pueden tildar varias
$menuCamp.add_Closing({ if ($_.CloseReason -eq 'ItemClicked') { $_.Cancel = $true } })

# Dos filtros de casillas, iguales en las dos pestañas: Modo (que se juega) y Server (quien hostea).
# Sin nada tildado = todos. El estado vive en el Tag del boton (los eventos lo leen de $this).
function New-MultiPick($options, $saved, [int]$width) {
    $btn = New-FlatButton 'Todos  ▾' $C.Input $C.CardHi $width 26
    $btn.Font = $F.Body; $btn.TextAlign = 'MiddleLeft'
    $btn.FlatAppearance.BorderSize = 1; $btn.FlatAppearance.BorderColor = $C.Gray
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $menu.ShowCheckMargin = $true; $menu.ShowImageMargin = $false
    $all = New-Object Windows.Forms.ToolStripMenuItem('Todos')
    [void]$menu.Items.Add($all)
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $items = [ordered]@{}
    foreach ($k in $options.Keys) {
        $it = New-Object Windows.Forms.ToolStripMenuItem($options[$k])
        $it.CheckOnClick = $true; $it.Tag = $k; $it.Checked = @($saved) -contains $k
        [void]$menu.Items.Add($it)
        $items[$k] = $it
    }
    $menu.add_Closing({ if ($_.CloseReason -eq 'ItemClicked') { $_.Cancel = $true } })
    $pick = [pscustomobject]@{ Button = $btn; Menu = $menu; All = $all; Items = $items; Bulk = $false }
    $btn.Tag = $pick; $menu.Tag = $pick
    return $pick
}

$modeOptions = [ordered]@{ vanilla = 'Vanilla'; competitivo = 'Competitivo'; zonemod = 'ZoneMod' }
$hostOptions = [ordered]@{ official = 'Oficiales de Valve'; dedicated = 'Dedicados'; listen = 'Host local' }
# Config vieja (un solo combo "Tipo de server") -> los dos filtros nuevos
$savedMode = @($settings.ModeFilter | Where-Object { $_ })
$savedHost = @($settings.HostFilter | Where-Object { $_ })
if ($null -eq $settings.ModeFilter -and $null -eq $settings.HostFilter) {
    switch ([string]$settings.ServerType) {
        'Solo ZoneMod' { $savedMode = @('zonemod') }
        'Solo competitivos' { $savedMode = @('competitivo', 'zonemod') }
        'Sin competitivo (vanilla)' { $savedMode = @('vanilla') }
        'Solo oficiales de Valve' { $savedHost = @('official') }
        'Solo de la comunidad (dedicados)' { $savedHost = @('dedicated') }
        'Solo hosteadas por un jugador' { $savedHost = @('listen') }
        'Sin host local (oficial o dedicado)' { $savedHost = @('official', 'dedicated') }
    }
    if (-not $savedHost.Count -and [string]$settings.LobbyType -like 'Sin host local*') { $savedHost = @('official', 'dedicated') }
    if ($HideValve) { $savedHost = @('dedicated', 'listen') }
}
$pickMode = New-MultiPick $modeOptions $savedMode 210
$pickHost = New-MultiPick $hostOptions $savedHost 220

$lblMode = New-FieldLabel 'Modo'
$lblMode.Margin = New-Object Windows.Forms.Padding(24, 6, 6, 0)
$lblHost = New-FieldLabel 'Server'
$lblHost.Margin = New-Object Windows.Forms.Padding(24, 6, 6, 0)
$modeBar.Controls.AddRange(@((New-FieldLabel 'Campañas'), $btnCamp, $lblMode, $pickMode.Button, $lblHost, $pickHost.Button))

# Opciones viejas que ya no se muestran (se guardan igual en la config)
$chkShare = New-Object Windows.Forms.CheckBox
$chkShare.Checked = [bool]$settings.Share
$btnKey = New-FlatButton 'API key' $C.CardHi (RGB 74 70 65) 190 26

# ---- Tu grupo (como en los juegos de hoy): un líder y los que lo siguen ----
# Te unís al grupo de un amigo desde "Unirse a un amigo" y la app te lleva a donde vaya el líder.
$groupBar = New-Object Windows.Forms.Panel
$groupBar.Dock = 'Top'; $groupBar.Height = 54; $groupBar.BackColor = $C.Bg
$groupBar.Padding = New-Object Windows.Forms.Padding(16, 10, 16, 8)
$groupLeft = New-Object Windows.Forms.FlowLayoutPanel
$groupLeft.Dock = 'Fill'; $groupLeft.WrapContents = $false; $groupLeft.BackColor = $C.Bg
$groupRight = New-Object Windows.Forms.FlowLayoutPanel
$groupRight.Dock = 'Right'; $groupRight.AutoSize = $true; $groupRight.WrapContents = $false; $groupRight.BackColor = $C.Bg
$groupMembers = New-Object Windows.Forms.FlowLayoutPanel
$groupMembers.AutoSize = $true; $groupMembers.WrapContents = $false; $groupMembers.BackColor = $C.Bg
$groupMembers.Margin = New-Object Windows.Forms.Padding(0)
$groupHint = New-Text '' $F.Small $C.Dim
$groupHint.Margin = New-Object Windows.Forms.Padding(10, 9, 0, 0)
$lblGroup = New-Text (Get-UiText 'Tu grupo') $F.H $C.Text
$lblGroup.Margin = New-Object Windows.Forms.Padding(0, 4, 12, 0)
$groupLeft.Controls.AddRange(@($lblGroup, $groupMembers, $groupHint))

$btnJoinFriend = New-FlatButton (Get-UiText 'Unirse a un amigo  ▾') $C.Accent $C.AccentHi 190 32
$btnJoinFriend.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0)
$tips.SetToolTip($btnJoinFriend, 'Elegí un amigo y entrás a su grupo: la app te lleva a su server o sala cada vez que se mueve.')
$menuFriends = New-Object Windows.Forms.ContextMenuStrip
$menuFriends.ShowImageMargin = $true; $menuFriends.ImageScalingSize = New-Object Drawing.Size(24, 24)
$btnPause = New-FlatButton (Get-UiText 'Pausar') $C.CardHi (RGB 74 70 65) 120 32
$btnPause.Font = $F.Chip; $btnPause.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0); $btnPause.Visible = $false
$btnFollowKey = New-FlatButton 'F5' $C.CardHi (RGB 74 70 65) 44 32
$btnFollowKey.Font = $F.Chip; $btnFollowKey.Margin = New-Object Windows.Forms.Padding(2, 0, 0, 0); $btnFollowKey.Visible = $false
$tips.SetToolTip($btnFollowKey, 'Tecla para pausar/reanudar el seguimiento, también desde el juego. Clic para cambiarla.')
$btnLeave = New-FlatButton (Get-UiText 'Salir') $C.CardHi (RGB 74 70 65) 80 32
$btnLeave.Font = $F.Chip; $btnLeave.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0); $btnLeave.Visible = $false
$groupRight.Controls.AddRange(@($btnPause, $btnFollowKey, $btnLeave, $btnJoinFriend))
$groupBar.Controls.Add($groupRight)
$groupBar.Controls.Add($groupLeft)
$groupLeft.BringToFront()   # el Fill se acomoda despues del de la derecha

# Dónde están los del grupo (se llena con el vigía de Steam; ver "dónde están" más abajo)
$wherePanel = New-Object Windows.Forms.Panel
$wherePanel.Dock = 'Top'; $wherePanel.Height = 0; $wherePanel.BackColor = $C.Panel; $wherePanel.Visible = $false

# Lista de tarjetas
$list = New-Object Windows.Forms.FlowLayoutPanel
$list.Dock = 'Fill'; $list.AutoScroll = $true; $list.FlowDirection = 'TopDown'; $list.WrapContents = $false
$list.BackColor = $C.Bg; $list.Padding = New-Object Windows.Forms.Padding(16, 14, 16, 8)
$list.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($list, $true, $null)

# Barra de estado
$statusBar = New-Object Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 30; $statusBar.BackColor = $C.Panel
$status = New-Text 'Elegí cuántos son y tocá Buscar.' $F.Small $C.Dim
$status.Location = New-Object Drawing.Point(16, 7)
$statusBar.Controls.Add($status)
$btnRestart = New-FlatButton 'Reiniciar' $C.Accent $C.AccentHi 220 24
$btnRestart.Font = $F.Small; $btnRestart.Anchor = 'Top, Right'; $btnRestart.Visible = $false
$btnRestart.Location = New-Object Drawing.Point(($form.ClientSize.Width - 236), 3)
$statusBar.Width = $form.ClientSize.Width
$statusBar.Controls.Add($btnRestart)

$form.Controls.Add($list)
$form.Controls.Add($statusBar)
$form.Controls.Add($wherePanel)
$form.Controls.Add($groupBar)
$form.Controls.Add($modeBar)
$form.Controls.Add($filters)
$form.Controls.Add($header)

# ---------------- tarjetas ----------------
function Get-CardWidth { return [math]::Max(600, $list.Width - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth - $list.Padding.Horizontal - 4) }   # haya barra o no, el mismo ancho

function Get-PingColor([int]$ms) {
    if ($ms -le 60) { return $C.Green }
    if ($ms -le 100) { return $C.Amber }
    return $C.Orange
}

# Imagen del mapa recortada al tamaño de la tarjeta, que se funde con el fondo a la derecha
$script:thumbCache = @{}
function Get-CardThumb($img, [int]$w, [int]$h, $bg = $C.Card) {
    $key = "$([Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($img))_$($w)x$($h)_$($bg.ToArgb())"
    if ($script:thumbCache.ContainsKey($key)) { return $script:thumbCache[$key] }
    $bmp = New-Object Drawing.Bitmap($w, $h)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.Clear([Drawing.Color]::Black)
    $s = [math]::Max($w / $img.Width, $h / $img.Height)   # cubrir y recortar el sobrante
    $dw = $img.Width * $s; $dh = $img.Height * $s
    $g.DrawImage($img, [single](($w - $dw) / 2), [single](($h - $dh) / 2), [single]$dw, [single]$dh)
    $fadeW = 70
    $fade = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($w - $fadeW), 0, $fadeW, $h)), ([Drawing.Color]::FromArgb(0, $bg)), $bg, 0.0)
    $g.FillRectangle($fade, ($w - $fadeW), 0, $fadeW, $h)
    $g.Dispose()
    $script:thumbCache[$key] = $bmp
    return $bmp
}

# Una marca por lugar: llenas = jugadores, vacias = lugares libres (servers de mas de 8: solo el numero)
$script:pipCache = @{}
function Get-SlotPips([int]$humans, [int]$max, $color, $bg = $C.Card) {
    $key = "$humans/$max/$($color.ToArgb())/$($bg.ToArgb())"
    if ($script:pipCache.ContainsKey($key)) { return $script:pipCache[$key] }
    $bmp = New-Object Drawing.Bitmap(120, 12)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear($bg)
    if ($max -ge 1 -and $max -le 8) {
        $pw = 11; $gap = 3   # sin separar equipos: no sabemos como estan repartidos
        $total = $max * $pw + ($max - 1) * $gap
        $x = [int]((120 - $total) / 2)
        $full = New-Object Drawing.SolidBrush($C.Text)
        $empty = New-Object Drawing.Pen($color, 2)
        for ($i = 0; $i -lt $max; $i++) {
            if ($i -lt $humans) { $g.FillRectangle($full, $x, 1, $pw, 10) }
            else { $g.DrawRectangle($empty, ($x + 1), 2, ($pw - 2), 8) }
            $x += $pw + $gap
        }
    }
    $g.Dispose()
    $script:pipCache[$key] = $bmp
    return $bmp
}

function New-Card($r) {
    $W = Get-CardWidth; $H = 120
    $statusColor = switch ($r.Estado) { 'Seguro' { $C.Green } 'Probable' { $C.Amber } default { $C.Gray } }

    $card = New-Object L4dCard
    $card.Size = New-Object Drawing.Size($W, $H); $card.BackColor = $C.Card
    $card.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10)

    $strip = New-Object Windows.Forms.Panel
    $strip.BackColor = $statusColor; $strip.Location = New-Object Drawing.Point(0, 0); $strip.Size = New-Object Drawing.Size(4, $H)

    $pic = New-Object Windows.Forms.PictureBox
    $pic.Location = New-Object Drawing.Point(4, 0); $pic.Size = New-Object Drawing.Size(240, $H)
    $pic.SizeMode = 'Normal'; $pic.BackColor = $C.Card
    $img = $null
    if ($r.Campaign -eq 'custom') {
        $id = if ($r.WorkshopId) { $r.WorkshopId } else { Get-CustomWorkshopId $script:customIx $r.Mapa }
        if ($id) { $img = Get-MapImage "ws_$id" }
        if (-not $img) { $img = Get-MapImage $r.Mapa }
        if (-not $img) { $img = Get-MapImage 'addon' }   # imagen generica de "addon" del juego, mejor que negro
    } else { $img = Get-MapImage $r.Mapa }
    if ($img) { $pic.Image = Get-CardThumb $img 240 $H }
    else {
        $noimg = New-Text $r.Mapa $F.Small $C.Dim
        $noimg.AutoSize = $false; $noimg.Dock = 'Fill'; $noimg.TextAlign = 'MiddleCenter'
        $pic.Controls.Add($noimg)
    }

    $x = 262; $rightW = 320   # botones + contador de lugares
    $isLobby = $r.Kind -eq 'lobby'
    $link = if ($r.Link) { $r.Link } else { "steam://connect/$($r.Addr)" }
    # Mapa custom: buscar su campaña de la Workshop (imagen y nombre)
    $wsId = ''; $titleText = if ($r.Title) { $r.Title } else { Get-MapTitle $r.Mapa }
    if ($r.Campaign -eq 'custom') {
        $wsId = if ($r.WorkshopId) { $r.WorkshopId } else { Get-CustomWorkshopId $script:customIx $r.Mapa }
        if ($wsId) {
            if (-not [IO.File]::Exists((Join-Path $mapDir "ws_$wsId.jpg")) -and -not $script:wsTried[$wsId]) { $script:wsPending[$wsId] = $true }
            if (-not $isLobby -and $script:customIx.Titles[$wsId]) { $titleText = "$($script:customIx.Titles[$wsId])  ·  $($r.Mapa)" }
        }
    }
    $t = New-Text (Get-UiText $titleText) $F.H $C.Text
    $t.Location = New-Object Drawing.Point($x, 12)

    $name = New-Text $r.Nombre $F.Body $C.Dim
    $name.AutoSize = $false; $name.AutoEllipsis = $true
    $name.Location = New-Object Drawing.Point($x, 42); $name.Size = New-Object Drawing.Size(($W - $x - $rightW - 10), 20)
    $name.Anchor = 'Top, Left, Right'

    $chips = New-Object Windows.Forms.FlowLayoutPanel
    $chips.BackColor = [Drawing.Color]::Transparent; $chips.WrapContents = $false
    $chips.Location = New-Object Drawing.Point($x, 68); $chips.Size = New-Object Drawing.Size(($W - $x - $rightW - 10), 22)
    $chips.Anchor = 'Top, Left, Right'
    $chips.Controls.Add((New-Chip $r.Estado.ToUpper() $statusColor $C.Bg))

    if ($chkIdeal.Checked -and ([int]$r.Max - [int]$r.Humans) -eq [math]::Max(1, [int]$numParty.Value)) { $chips.Controls.Add((New-Chip 'JUSTO PARA USTEDES' $C.Green $C.Bg)) }
    if ($r.Config) { $chips.Controls.Add((New-Chip $r.Config.ToUpper() $C.Blue $C.Bg)) }
    elseif ($r.Competitive) { $chips.Controls.Add((New-Chip 'COMPETITIVO' $C.Blue $C.Bg)) }
    if ($r.Premade) { $chips.Controls.Add((New-Chip "GRUPO ARMADO ($($r.Premade))" $C.CardHi $C.Orange)) }
    if ($isLobby) { $chips.Controls.Add((New-Chip 'SALA DE ESPERA' $C.Blue $C.Bg)) }
    if ($isLobby -and $r.Server -eq 'listen') { $chips.Controls.Add((New-Chip 'HOST LOCAL' $C.CardHi $C.Amber)) }
    if ($r.Custom -or (-not $isLobby -and $r.Campaign -eq 'custom')) { $chips.Controls.Add((New-Chip 'MAPA CUSTOM' $C.CardHi $C.Amber)) }
    if ($r.Valve -and -not $isLobby) { $chips.Controls.Add((New-Chip 'OFICIAL VALVE' $C.CardHi $C.Dim)) }
    if ($r.FriendsOnly) { $chips.Controls.Add((New-Chip 'SOLO AMIGOS?' $C.CardHi $C.Orange)) }
    if ($r.Mutation) { $chips.Controls.Add((New-Chip 'MUTACIÓN' $C.CardHi $C.Amber)) }
    if ($r.Max -gt 8) { $chips.Controls.Add((New-Chip "GRANDE ($($r.Max))" $C.CardHi $C.Amber)) }

    # La explicacion solo cuando dice algo que el contador no dice (cómo estarian repartidos)
    $hintText = if ($r.Estado -ne 'Seguro') { $r.Hint } else { '' }
    $hint = New-Text $hintText $F.Small $C.Dim
    $hint.AutoSize = $false; $hint.AutoEllipsis = $true
    $hint.Location = New-Object Drawing.Point($x, 94); $hint.Size = New-Object Drawing.Size(($W - $x - $rightW - 10), 20)
    $hint.Anchor = 'Top, Left, Right'

    # Contador de lugares, grande para leerlo de un vistazo: "6/8", una marca por lugar y cuántos quedan
    $free = [math]::Max(0, [int]$r.Max - [int]$r.Humans)
    $party = [math]::Max(1, [int]$numParty.Value)
    $freeColor = if ($free -ge $party -and $r.Estado -eq 'Seguro') { $C.Green } elseif ($free -ge $party) { $C.Amber } else { $C.Orange }
    $slotX = $W - 176 - 132
    $slots = New-Text "$($r.Humans)/$($r.Max)" $F.Slots $C.Text
    $slots.AutoSize = $false; $slots.TextAlign = 'MiddleCenter'
    $slots.Size = New-Object Drawing.Size(120, 46); $slots.Location = New-Object Drawing.Point($slotX, 12); $slots.Anchor = 'Top, Right'
    $pips = New-Object Windows.Forms.PictureBox
    $pips.Size = New-Object Drawing.Size(120, 12); $pips.Location = New-Object Drawing.Point($slotX, 62); $pips.Anchor = 'Top, Right'
    $pips.BackColor = $C.Card; $pips.Image = Get-SlotPips ([int]$r.Humans) ([int]$r.Max) $freeColor
    $freeText = switch ($free) { 0 { 'Lleno' } 1 { 'Queda 1' } default { "Quedan $free" } }
    $slotsSub = New-Text (Get-UiText $freeText) $F.SlotsSub $freeColor
    $slotsSub.AutoSize = $false; $slotsSub.TextAlign = 'MiddleCenter'
    $slotsSub.Size = New-Object Drawing.Size(120, 20); $slotsSub.Location = New-Object Drawing.Point($slotX, 80); $slotsSub.Anchor = 'Top, Right'

    # Los lobbies no tienen ping: Steam solo dice si estan en tu region o lejos
    $ping = if (-not $isLobby) { New-Text "$($r.Ping) ms" $F.Ping (Get-PingColor $r.Ping) }
    elseif ($r.Near) { New-Text 'Tu región' $F.Btn $C.Green }
    else { New-Text 'Otra región' $F.Btn $C.Orange }
    $ping.AutoSize = $false; $ping.TextAlign = 'MiddleRight'
    $ping.Size = New-Object Drawing.Size(160, 26); $ping.Location = New-Object Drawing.Point(($W - 176), 8)
    $ping.Anchor = 'Top, Right'

    $join = New-FlatButton (Get-UiText 'Unirme') $C.Accent $C.AccentHi 160 34
    $join.Location = New-Object Drawing.Point(($W - 176), 40); $join.Anchor = 'Top, Right'; $join.Tag = $link
    $join.add_Click({ Invoke-Join $this.Tag })

    $copy = New-FlatButton (Get-UiText 'Copiar link') $C.CardHi (RGB 74 70 65) 160 28
    $copy.Font = $F.Chip
    $copy.Location = New-Object Drawing.Point(($W - 176), 80); $copy.Anchor = 'Top, Right'; $copy.Tag = $link
    $copy.add_Click({ Copy-Link $this.Tag })

    $card.Controls.AddRange(@($strip, $pic, $t, $name, $chips, $hint, $slots, $pips, $slotsSub, $ping, $join, $copy))
    Convert-CardToImage $card @($join, $copy)
    return $card
}

# Una tarjeta armada con ~20 controles hace que al scrollear Windows no llegue a repintarlos y queden rayas
# "corridas". Por eso, ya armada, se "fotografía" entera en una sola imagen de fondo y solo quedan vivos los
# botones: al scrollear se mueven imágenes, que es instantáneo.
function Convert-CardToImage($card, [object[]]$keep, [scriptblock]$decorate) {
    try {
        $bmp = New-Object Drawing.Bitmap($card.Width, $card.Height)
        foreach ($k in $keep) { $k.Visible = $false }
        $card.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $card.Width, $card.Height)))
        if ($decorate) { $gd = [Drawing.Graphics]::FromImage($bmp); $gd.SmoothingMode = 'AntiAlias'; try { & $decorate $gd $card.Width $card.Height } finally { $gd.Dispose() } }
        foreach ($k in $keep) { $k.Visible = $true }
        foreach ($ctl in @($card.Controls | Where-Object { $keep -notcontains $_ })) { $card.Controls.Remove($ctl); $ctl.Dispose() }
        $card.SetFace($bmp)
        $bmp.Dispose()
    } catch { foreach ($k in $keep) { $k.Visible = $true } }   # si falla, queda la tarjeta normal
}

function Show-Message([string]$text) {
    $l = New-Text $text $F.Body $C.Dim
    $l.Margin = New-Object Windows.Forms.Padding(4, 20, 0, 0)
    $list.Controls.Add($l)
}

# Cambios grandes (otra pestaña, otros filtros) sin parpadeo. Windows dibuja cada control por separado y,
# cuando la lista se corre (al sacar o poner la fila de filtros), arrastra los píxeles viejos: por un instante
# se ven tarjetas cortadas y textos encimados. Para evitarlo se tapa la ventana con una "foto" de cómo está,
# se rearma todo abajo, se cambia la foto por una del resultado final (de un saque) y recién ahí se destapa:
# lo que queda abajo es idéntico a la foto, así que no se nota nada.
$script:freeze = 0
$cover = New-Object Windows.Forms.PictureBox
$cover.Visible = $false; $cover.SizeMode = 'Normal'; $cover.BackColor = $C.Bg
$coverOff = New-Object Windows.Forms.Timer
$coverOff.Interval = 60
$coverOff.add_Tick({
        $this.Stop()
        $cover.Visible = $false
        $img = $cover.Image; $cover.Image = $null; if ($img) { $img.Dispose() }
    })
function Get-FormPicture {
    $sz = $form.ClientSize
    $bmp = New-Object Drawing.Bitmap($sz.Width, $sz.Height)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear($C.Bg); $g.Dispose()
    # De atrás para adelante, cada bloque en su lugar (la tapa no)
    $ctls = @($form.Controls | Where-Object { $_ -ne $cover -and $_.Visible })
    [array]::Reverse($ctls)
    foreach ($ctl in $ctls) {
        if ($ctl.Width -le 0 -or $ctl.Height -le 0) { continue }
        $part = New-Object Drawing.Bitmap($ctl.Width, $ctl.Height)
        $ctl.DrawToBitmap($part, (New-Object Drawing.Rectangle(0, 0, $ctl.Width, $ctl.Height)))
        $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImageUnscaled($part, $ctl.Left, $ctl.Top); $g.Dispose()
        $part.Dispose()
    }
    return $bmp
}
function Invoke-Frozen([scriptblock]$work) {
    $outer = $script:freeze -eq 0 -and $form.IsHandleCreated -and $form.Visible -and $form.WindowState -ne 'Minimized' -and -not $Screenshot
    if ($outer) {
        try {
            $coverOff.Stop()
            if (-not $form.Controls.Contains($cover)) { $form.Controls.Add($cover) }
            $old = $cover.Image
            $cover.Image = Get-FormPicture
            if ($old) { $old.Dispose() }
            $cover.Bounds = New-Object Drawing.Rectangle(0, 0, $form.ClientSize.Width, $form.ClientSize.Height)
            $cover.BringToFront(); $cover.Visible = $true; $cover.Update()
        } catch { $outer = $false }
    }
    $script:freeze++
    try { . $work }
    finally {
        $script:freeze--
        if ($outer) {
            try {
                $form.PerformLayout(); $list.PerformLayout()
                $old = $cover.Image
                $cover.Image = Get-FormPicture   # el resultado final, de una vez
                if ($old) { $old.Dispose() }
                $cover.Update()
            } catch {}
            $coverOff.Start()                    # destapar cuando lo de abajo ya se pintó igual
        }
    }
}
function Clear-List {
    $old = @($list.Controls | Where-Object { $_ -ne $spinPanel })
    $list.Controls.Clear()
    foreach ($ctl in $old) { $ctl.Dispose() }
}

# ---------------- spinner de carga (el de L4D2) ----------------
# Los cuadros salen del juego (materials/engine/l4d_spinner.vtf -> mapas\spinner_N.png, se extraen la
# primera vez). Si no están, se dibuja uno simple mientras tanto.
function Get-SpinnerFrames {
    $files = @(0..9 | ForEach-Object { Join-Path $mapDir "spinner_$_.png" } | Where-Object { Test-Path $_ })
    if ($files.Count -eq 10) {
        return @($files | ForEach-Object { $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($_)); [Drawing.Image]::FromStream($ms) })
    }
    $frames = foreach ($k in 0..11) {
        $bmp = New-Object Drawing.Bitmap(64, 64); $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
        $pen = New-Object Drawing.Pen($C.Accent, 6); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $g.DrawArc($pen, 8, 8, 48, 48, $k * 30, 260); $g.Dispose(); $bmp
    }
    return @($frames)
}
$spinPanel = New-Object Windows.Forms.FlowLayoutPanel
$spinPanel.FlowDirection = 'TopDown'; $spinPanel.WrapContents = $false; $spinPanel.AutoSize = $true; $spinPanel.BackColor = $C.Bg
$spinPic = New-Object Windows.Forms.PictureBox
$spinPic.Size = New-Object Drawing.Size(64, 64); $spinPic.SizeMode = 'Zoom'; $spinPic.BackColor = $C.Bg
$spinText = New-Text 'Buscando...' $F.Body $C.Dim
$spinText.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
$spinPanel.Controls.AddRange(@($spinPic, $spinText))
$script:spinFrames = @(Get-SpinnerFrames); $script:spinIdx = 0
$spinTimer = New-Object Windows.Forms.Timer
$spinTimer.Interval = 80
$spinTimer.add_Tick({
        $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
        $spinPic.Image = $script:spinFrames[$script:spinIdx]
    })
function Show-Spinner([string]$text) {
    $spinText.Text = $text
    $spinPic.Image = $script:spinFrames[0]
    # Centrado en la lista
    $spinPanel.Margin = New-Object Windows.Forms.Padding([math]::Max(0, [int](($list.ClientSize.Width - 260) / 2)), [math]::Max(20, [int]($list.ClientSize.Height / 2 - 70)), 0, 0)
    $spinPic.Margin = New-Object Windows.Forms.Padding(98, 0, 0, 0)
    $spinText.AutoSize = $false; $spinText.Width = 260; $spinText.TextAlign = 'MiddleCenter'
    if (-not $list.Controls.Contains($spinPanel)) { $list.Controls.Add($spinPanel) }
    $spinTimer.Start()
}
function Hide-Spinner {
    $spinTimer.Stop()
    if ($list.Controls.Contains($spinPanel)) { $list.Controls.Remove($spinPanel) }
}

# ---------------- filtros sobre la ultima busqueda ----------------
$script:view = if ($View -in 'servers', 'lobbies') { $View } elseif ($settings.View -eq 'lobbies') { 'lobbies' } else { 'servers' }
$script:results = @{ servers = $null; lobbies = $null }   # ultima busqueda de cada vista
$script:times = @{ servers = ''; lobbies = '' }
$script:bulkCheck = $false

function Get-SelectedCampaigns { return @($campItems.Values | Where-Object { $_.Checked } | ForEach-Object { $_.Tag }) }

function Update-CampButton {
    $sel = @(Get-SelectedCampaigns)
    $itemAll.Checked = ($sel.Count -eq 0)
    $btnCamp.Text = switch ($sel.Count) {
        0 { 'Todas  ▾' }
        1 { "$($campItems[$sel[0]].Text)  ▾" }
        default { "$($sel.Count) campañas  ▾" }
    }
}

# Quien hostea: las salas lo dicen (official/dedicated/listen); en la lista de Steam solo hay servers
# dedicados, y los oficiales se reconocen por el nombre.
function Get-HostKind($r) {
    if ($r.Kind -eq 'lobby') { return [string]$r.Server }
    if ($r.Valve) { return 'official' }
    return 'dedicated'
}

# Que se juega: ZoneMod (por el nombre), competitivo (tag confogl) o vanilla. Las salas de espera son siempre vanilla.
function Get-ModeKind($r) {
    if ($r.ZoneMod) { return 'zonemod' }
    if ($r.Competitive) { return 'competitivo' }
    return 'vanilla'
}

function Get-Picked($pick) { return @($pick.Items.Values | Where-Object { $_.Checked } | ForEach-Object { $_.Tag }) }

function Update-PickButton($pick) {
    $sel = @(Get-Picked $pick)
    $pick.All.Checked = ($sel.Count -eq 0)
    $pick.Button.Text = if ($sel.Count -eq 0 -or $sel.Count -eq $pick.Items.Count) { 'Todos  ▾' }
    else { (($sel | ForEach-Object { $pick.Items[$_].Text }) -join ' + ') + '  ▾' }
}

function Test-ServerType($r, $modes, $hosts) {
    return ($modes.Count -eq 0 -or $modes -contains (Get-ModeKind $r)) -and ($hosts.Count -eq 0 -or $hosts -contains (Get-HostKind $r))
}

# Baja en segundo plano las portadas de la Workshop que faltan y redibuja al terminar
function Request-WorkshopImages {
    $ids = @($script:wsPending.Keys)
    if (-not $ids.Count -or $script:busy['wsimg']) { return }
    $script:wsPending = @{}
    foreach ($id in $ids) { $script:wsTried[$id] = $true }
    Start-Async 'wsimg' { param($ids, $dir) Get-WorkshopImages $ids $dir } @([string[]]$ids, $mapDir) {
        param($res, $err)
        $titles = Get-First $res
        if ($titles) { foreach ($k in @($titles.Keys)) { $script:customIx.Titles[$k] = $titles[$k] } }
        Save-CustomIndex $script:customIx $customFile
        $script:imgCache = @{}
        Show-Rows
    }
}

# Rehace el indice mapa -> Workshop con los addons instalados
function Update-AddonMaps($addons) {
    $script:customIx.Addons = $addons
    $maps = @{}
    foreach ($id in $addons.Keys) { foreach ($m in @($addons[$id].Maps)) { if ($m) { $maps[([string]$m).ToLower()] = $id } } }
    $script:customIx.Maps = $maps
    Save-CustomIndex $script:customIx $customFile
}

function Show-Rows {
    if ($null -eq $script:results[$script:view]) { return }
    Invoke-Frozen { Show-RowsCore }
}
# Orden "ideal" (experimental): puntaje = ping + 30 por cada lugar de más (después de entrar el grupo)
# + 60 por cada escalón de duda (Seguro / Probable / Depende). Menor es mejor. Las salas no tienen ping:
# las de tu región cuentan como 60 ms y las de otra como 200.
function Get-IdealScore($r, [int]$party) {
    $extra = [math]::Max(0, [int]$r.Max - [int]$r.Humans - $party)
    $ping = if ($r.Kind -eq 'lobby') { if ($r.Near) { 60 } else { 200 } } else { [int]$r.Ping }
    return $ping + 30 * $extra + 60 * [int]$r.Rank
}
function Get-IdealOrder($rows, [int]$party) {
    return @($rows | Sort-Object { Get-IdealScore $_ $party }, Ping)
}
function Show-RowsCore {
    $all = $script:results[$script:view]
    $lobbies = $script:view -eq 'lobbies'
    $sel = @(Get-SelectedCampaigns)
    $modes = @(Get-Picked $pickMode); $hosts = @(Get-Picked $pickHost)
    $showFriendsOnly = $chkFriendsOnly.Checked; $showMutation = $chkMutation.Checked
    $rows = @($all | Where-Object {
            ($sel.Count -eq 0 -or $sel -contains $_.Campaign) -and (Test-ServerType $_ $modes $hosts) -and
            ($showFriendsOnly -or -not $_.FriendsOnly) -and ($showMutation -or -not $_.Mutation) })
    if ($chkIdeal.Checked) { $rows = @(Get-IdealOrder $rows ([int]$numParty.Value)) }
    Clear-List
    $list.SuspendLayout()
    $script:cardsWidth = Get-CardWidth
    foreach ($r in $rows) { $list.Controls.Add((New-Card $r)) }
    $list.ResumeLayout()
    Request-WorkshopImages
    if ($all.Count -eq 0) {
        Show-Message $(if ($lobbies) { 'No hay salas de espera de versus con lugar para ustedes ahora. Probá de nuevo en un rato.' }
            else { 'No hay servers con lugar. Probá subir el ping máximo o buscar de nuevo en un rato.' })
    } elseif ($rows.Count -eq 0) {
        $onlyComp = $modes.Count -and $modes -notcontains 'vanilla'
        $wantsRare = ($sel -contains 'custom') -or $onlyComp
        if ($lobbies -and $onlyComp) {
            Show-Message 'Las salas de espera son partidas comunes del juego: no hay ZoneMod ni competitivos. Para eso mirá "Partidas en curso".'
        } elseif (-not $lobbies -and $hosts.Count -eq 1 -and $hosts[0] -eq 'listen') {
            Show-Message 'Las partidas en curso de la lista de Steam son todas de servers dedicados. Las que hostea un jugador aparecen en "Salas de espera".'
        } elseif (-not $lobbies -and $wantsRare -and $numPing.Value -lt 200) {
            Show-Message 'Nada con estos filtros. Casi todos los servers ZoneMod y de mapas custom están en EE.UU. (150-190 ms): subí el ping máximo a 200 y tocá Buscar.'
        } else { Show-Message 'Nada coincide con estos filtros ahora. Probá con otra campaña, modo o tipo de server.' }
    }
    $seguros = @($rows | Where-Object { $_.Rank -eq 0 }).Count
    $what = if ($lobbies) { 'salas de espera' } else { 'servers' }
    $hidden = @($all | Where-Object { ($_.FriendsOnly -and -not $showFriendsOnly) -or ($_.Mutation -and -not $showMutation) }).Count
    $hiddenTxt = if ($hidden) { "  $hidden ocultos (solo amigos / mutaciones)." } else { '' }
    $status.Text = "Mostrando $($rows.Count) de $($all.Count) $what ($seguros seguros).$hiddenTxt  Última búsqueda: $($script:times[$script:view])"
}

# Las tarjetas de la otra pestaña se guardan armadas: volver a una pestaña es instantáneo mientras no
# cambien los resultados, los filtros, cuántos son ni las imágenes (si algo cambió, se rearman).
$script:cardCache = @{}
function Get-CardKey([string]$v) {
    $id = { param($o) if ($null -eq $o) { 0 } else { [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($o) } }
    return @((& $id $script:results[$v]), ((Get-SelectedCampaigns) -join ','), ((Get-Picked $pickMode) -join ','),
        ((Get-Picked $pickHost) -join ','), $chkFriendsOnly.Checked, $chkMutation.Checked, $chkIdeal.Checked, [int]$numParty.Value,
        (& $id $script:imgCache), (Get-CardWidth)) -join '|'
}
function Remove-CardCache([string]$v) {
    $entry = $script:cardCache[$v]   # (no usar $c: en PowerShell es lo mismo que $C, la paleta de colores)
    if ($entry) { foreach ($ctl in $entry.Controls) { $ctl.Dispose() } }
    $script:cardCache.Remove($v)
}

function Set-View([string]$v) { Invoke-Frozen { Set-ViewCore $v } }
function Set-ViewCore([string]$v) {
    $prev = $script:view
    $script:view = $v
    foreach ($b in $btnViewServers, $btnViewLobbies) {
        $on = $b.Tag -eq $v
        $b.BackColor = if ($on) { $C.CardHi } else { $C.Input }
        $b.ForeColor = if ($on) { $C.Text } else { $C.Dim }
        $b.FlatAppearance.BorderSize = if ($on) { 1 } else { 0 }
        $b.FlatAppearance.BorderColor = $C.Accent
    }
    # Ping, servers grandes, solo amigos y mutaciones no aplican a las salas de espera (las listadas son
    # siempre publicas y versus): ahi la fila no se muestra, en vez de verse apagada y gris.
    $filters.Visible = $v -eq 'servers'
    $subtitle.Text = if ($v -eq 'lobbies') { 'Left 4 Dead 2  ·  salas de espera con lugar para tu grupo' } else { 'Left 4 Dead 2  ·  servers con lugar para tu grupo' }

    # Guardar las tarjetas de la pestaña que se deja (si no está buscando)
    $kept = @($list.Controls | Where-Object { $_ -ne $spinPanel })
    if ($prev -ne $v -and $null -ne $script:results[$prev] -and $kept.Count -and -not $list.Controls.Contains($spinPanel)) {
        Remove-CardCache $prev
        $script:cardCache[$prev] = @{ Key = (Get-CardKey $prev); Controls = $kept; Status = $status.Text; Scroll = $list.VerticalScroll.Value }
        $list.Controls.Clear()
    } else { Clear-List }

    $entry = $script:cardCache[$v]   # (no usar $c: en PowerShell es lo mismo que $C, la paleta de colores)
    if ($entry -and $null -ne $script:results[$v] -and $entry.Key -eq (Get-CardKey $v)) {
        $script:cardCache.Remove($v)
        $list.SuspendLayout()
        $script:cardsWidth = Get-CardWidth
        $list.Controls.AddRange([Windows.Forms.Control[]]$entry.Controls)
        $list.ResumeLayout()
        $list.AutoScrollPosition = New-Object Drawing.Point(0, $entry.Scroll)
        $status.Text = $entry.Status
        return
    }
    Remove-CardCache $v
    if ($null -ne $script:results[$v]) { Show-Rows }
    elseif ($btnSearch.Enabled) { $btnSearch.PerformClick() }
}
# Si cambia cuántos son (a mano o porque se sumó alguien al grupo), recalcular lo que se ve
$script:lobbyJson = $null; $script:lobbyJsonParty = 0
$partyTimer = New-Object Windows.Forms.Timer
$partyTimer.Interval = 800   # esperar a que dejen de tocar las flechitas
$partyTimer.add_Tick({
        $this.Stop()
        $p = [int]$numParty.Value
        # Salas: si ya las pedimos para un grupo igual o más chico, alcanza con volver a filtrar
        if ($script:lobbyJson -and $p -ge $script:lobbyJsonParty) {
            $script:results.lobbies = @(ConvertTo-LobbyRows $script:lobbyJson $p $false)
        } else { $script:results.lobbies = $null }
        $script:results.servers = $null   # el veredicto de los servers depende del tamaño: rehacer
        if ($null -ne $script:results[$script:view]) { Show-Rows }
        elseif ($btnSearch.Enabled) { $btnSearch.PerformClick() }
    })
$numParty.add_ValueChanged({ Update-PartyLabel; $partyTimer.Stop(); $partyTimer.Start() })
$btnViewServers.add_Click({ if ($script:view -ne 'servers') { Set-View 'servers' } })
$btnViewLobbies.add_Click({ if ($script:view -ne 'lobbies') { Set-View 'lobbies' } })

$btnCamp.add_Click({ $menuCamp.Show($btnCamp, 0, $btnCamp.Height) })
$itemAll.add_Click({
        $script:bulkCheck = $true
        foreach ($it in $campItems.Values) { $it.Checked = $false }
        $script:bulkCheck = $false
        Update-CampButton; Show-Rows
    })
foreach ($it in $campItems.Values) {
    $it.add_CheckedChanged({ if (-not $script:bulkCheck) { Update-CampButton; Show-Rows } })
}
$chkFriendsOnly.add_CheckedChanged({ Show-Rows })
$chkMutation.add_CheckedChanged({ Show-Rows })
$chkIdeal.add_CheckedChanged({ Show-Rows })
foreach ($pick in $pickMode, $pickHost) {
    $pick.Button.add_Click({ $this.Tag.Menu.Show($this, 0, $this.Height) })
    $pick.All.add_Click({
            $p = $this.Owner.Tag
            $p.Bulk = $true
            foreach ($it in $p.Items.Values) { $it.Checked = $false }
            $p.Bulk = $false
            Update-PickButton $p; Show-Rows
        })
    foreach ($it in $pick.Items.Values) {
        $it.add_CheckedChanged({ $p = $this.Owner.Tag; if (-not $p.Bulk) { Update-PickButton $p; Show-Rows } })
    }
    Update-PickButton $pick
}
Update-CampButton

# Las tarjetas son imágenes: si cambia el ancho de la ventana se vuelven a armar (cuando se termina de
# agrandar/achicar, no en cada pixel del arrastre).
$script:cardsWidth = 0
$resizeTimer = New-Object Windows.Forms.Timer
$resizeTimer.Interval = 200
$resizeTimer.add_Tick({
        $this.Stop()
        if ((Get-CardWidth) -ne $script:cardsWidth -and @($list.Controls | Where-Object { $_ -is [L4dCard] }).Count) { Show-Rows }
    })
$list.add_Resize({ $resizeTimer.Stop(); $resizeTimer.Start() })
# Al scrollear, pintar ya mismo lo que quedó al descubierto (UPDATENOW | ALLCHILDREN), sin esperar turno
$list.add_Scroll({ [void][L4dShell.Redraw]::RedrawWindow($list.Handle, [IntPtr]::Zero, [IntPtr]::Zero, 0x0180) })
$list.add_MouseWheel({ [void][L4dShell.Redraw]::RedrawWindow($list.Handle, [IntPtr]::Zero, [IntPtr]::Zero, 0x0180) })

# ---------------- acciones ----------------
# Traer el juego al frente (y sacarlo de minimizado) al tocar Unirme. Si el juego todavía no está abierto,
# Steam lo abre y aparece adelante solo.
if (-not ('L4dShell.Focus' -as [type])) {
    Add-Type -Name Focus -Namespace L4dShell -MemberDefinition ('[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);' +
        '[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);' +
        '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);' +
        '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();')
}
function Show-Game {
    $g = Get-Process left4dead2 -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if (-not $g) { return $false }
    $h = $g.MainWindowHandle
    if ([L4dShell.Focus]::IsIconic($h)) { [void][L4dShell.Focus]::ShowWindow($h, 9) }   # 9 = restaurar
    [void][L4dShell.Focus]::SetForegroundWindow($h)
    return $true
}
$gameFront = New-Object Windows.Forms.Timer
$gameFront.Interval = 1200
$gameFront.add_Tick({
        # Segundo intento, por si Steam se quedó con el foco al procesar el link
        $this.Stop()
        $g = Get-Process left4dead2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g -and [L4dShell.Focus]::GetForegroundWindow() -ne $g.MainWindowHandle) { [void](Show-Game) }
    })

function Invoke-Join([string]$link) {
    Write-AppLog "Unirme (botón): $link"
    Start-Process $link
    if (Show-Game) { $gameFront.Stop(); $gameFront.Start() }
    if ($link -like 'steam://joinlobby/*') {
        $status.Text = 'Entrando a la sala...  Si "Compartir mi partida" está tildado, tus amigos que te siguen entran solos.'
    } else {
        $status.Text = "Entrando a $($link -replace '^steam://connect/')...  Si quedan en equipos distintos: ESC > Cambiar de equipo."
    }
}

function Copy-Link([string]$link) {
    $text = if ($link -like 'steam://connect/*') { $a = $link -replace '^steam://connect/'; "$link   (pegalo en Win+R)   o en la consola del juego: connect $a" }
    else { "$link   (pegalo en Win+R con el juego abierto)" }
    [Windows.Forms.Clipboard]::SetText($text)
    $status.Text = 'Link copiado. Pegáselo a tus amigos (Discord/WhatsApp).'
}

function Stop-Searching {
    Hide-Spinner
    $form.Cursor = 'Default'
    $btnSearch.Enabled = $true; $btnSearch.Text = (Get-UiText 'Buscar')
}

$btnSearch.add_Click({
        $btnSearch.Enabled = $false; $btnSearch.Text = (Get-UiText 'Buscando...')
        $script:searchedAt[$script:view] = Get-Date
        $form.Cursor = 'AppStarting'
        Clear-List
        Show-Spinner $(if ($script:view -eq 'lobbies') { 'Buscando salas de espera...' } else { 'Buscando partidas en curso...' })
        if ($script:view -eq 'lobbies') {
            # Las salas se piden a Steam en un proceso aparte (en segundo plano: la ventana no se traba)
            $status.Text = 'Pidiéndole a Steam las salas de espera de versus...'
            $script:lobbyArgs = @{ Party = [int]$numParty.Value; HideValve = $false }   # el $done corre en otro alcance
            Start-Async 'lobbies' { param($p, $dir) Get-LobbyJson $p $dir } @($script:lobbyArgs.Party, $here) {
                param($res, $err)
                Stop-Searching
                if ($err) { $status.Text = "Error: $err"; return }
                $script:lobbyJson = [string](Get-First $res); $script:lobbyJsonParty = $script:lobbyArgs.Party
                try { if (Update-CustomIndexFromLobbies $script:customIx $script:lobbyJson) { Save-CustomIndex $script:customIx $customFile } } catch {}
                try { $script:results.lobbies = @(ConvertTo-LobbyRows $script:lobbyJson $script:lobbyArgs.Party $script:lobbyArgs.HideValve) }
                catch { $status.Text = "Error: $($_.Exception.Message)"; return }
                $script:times.lobbies = Get-Date -Format 'HH:mm'
                if ([int]$numParty.Value -ne $script:lobbyArgs.Party) { $partyTimer.Stop(); $partyTimer.Start() }   # el grupo cambio mientras buscaba
                if ($script:view -eq 'lobbies') { Show-Rows }
            }
            return
        }

        # La busqueda corre en otro hilo: la ventana sigue respondiendo y abajo se ve el avance
        $script:searchState = [hashtable]::Synchronized(@{ Msg = 'Pidiendo la lista de servidores a Steam...' })
        $status.Text = $script:searchState.Msg
        Start-Async 'servers' {
            param($finder, $p, $ping, $big, $valve, $state)
            $ErrorActionPreference = 'Stop'
            $here = Split-Path -Parent $finder
            $keyFile = Join-Path $here 'apikey.txt'
            # Cargar solo la parte de busqueda de finder.ps1 (sin abrir otra ventana)
            $src = [IO.File]::ReadAllText($finder)
            $a = $src.IndexOf('# >>> BUSQUEDA'); $b = $src.IndexOf('# <<< BUSQUEDA')
            . ([scriptblock]::Create($src.Substring($a, $b - $a)))
            Find-Servers $p $ping $big $valve { param($m) $state.Msg = $m }
        } @((Join-Path $here 'finder.ps1'), [int]$numParty.Value, [int]$numPing.Value, [bool]$chkBig.Checked, $false, $script:searchState) {
            param($res, $err)
            Stop-Searching
            if ($err) { $status.Text = "Error: $err"; return }
            $script:results.servers = @($res | ForEach-Object { $_ })
            $script:times.servers = Get-Date -Format 'HH:mm'
            if ($script:view -eq 'servers') { Show-Rows }
        }
    })

# ---------------- seguir a un amigo de Steam ----------------
# El que juega (con API key) transmite en que server/lobby esta; los que siguen solo escuchan (sin key).
$script:me = Get-MySteamId

$script:followLobby = ''
$script:joinedServer = ''   # ultimo server al que te llevó (no se borra al destildar)
$script:pendingAction = ''; $script:pendingSince = Get-Date; $script:leaderState = ''; $script:leaderLobby = ''; $script:followedFor = ''; $script:myName = ''
$script:followKeyName = 'F5'
$script:lobbyJoinedAt = [datetime]::MinValue
$script:shareState = ''
$script:shareSentAt = [datetime]::MinValue
$script:friendsQuiet = $false

# ---------------- grupo ----------------
# Como en los juegos de hoy: un grupo tiene un líder y los demás lo siguen. Te unís desde "Unirse a un
# amigo" (si ese amigo ya estaba en un grupo, entrás a ese grupo) y la app te lleva a donde vaya el líder.
# Seguís en el grupo hasta tocar "Salir" (o cerrar la app). La tecla (F5) solo pausa el seguimiento.
# Si se unen a vos, sos el líder: no hace falta hacer nada.
$script:groupLeader = if ($settings.SteamFollow -and $settings.FollowSteamId) { [string]$settings.FollowSteamId } else { '' }
$script:followPaused = $false
$script:friendByHash = @{}
$script:friendNameById = @{}
$script:partyMap = @{}   # huella -> huella de a quien sigue (de los avisos de cada app)
$script:groupKey = $null
$script:groupCount = 0
$script:seenInGroup = @{}   # huella -> última vez que estuvo en el grupo
$script:groupData = @()
$script:avatars = @{}
$script:avatarTried = @{}

function Get-FriendName([string]$sid) {
    if (-not $sid) { return '?' }
    if ($sid -eq $script:me) { return 'Vos' }
    $fr = $script:friendByHash[(Get-SidHash $sid)]
    if ($fr) { return $fr.Name }
    if ($script:friendNameById[$sid]) { return $script:friendNameById[$sid] }
    return 'Amigo'
}

function Test-Following { return ([bool]$script:groupLeader -and -not $script:followPaused) }

function Send-Beat([switch]$Force) {
    if (-not $script:me -or $Screenshot -or (-not $Force -and (Test-NtfyPaused))) { return }
    Start-Async 'beat' { param($me, $leader) Send-FollowSignal $me $leader } @($script:me, $script:groupLeader) { param($res, $err) if ($err) { Set-NtfyError $err } }
}

# Los avisos de todos + el mío al día (el mío puede no haber llegado todavía)
function Get-MyPartyMap {
    $map = @{}
    foreach ($k in $script:partyMap.Keys) { $map[$k] = $script:partyMap[$k] }
    if ($script:me) { $map[(Get-SidHash $script:me)] = $(if ($script:groupLeader) { Get-SidHash $script:groupLeader } else { '' }) }
    return $map
}

function Update-FollowButtons {
    $inGroup = [bool]$script:groupLeader
    $btnPause.Visible = $inGroup; $btnFollowKey.Visible = $inGroup; $btnLeave.Visible = $inGroup
    $btnPause.Text = if ($script:followPaused) { Get-UiText 'Reanudar' } else { Get-UiText 'Pausar' }
    $btnPause.BackColor = if ($script:followPaused) { $C.Accent } else { $C.CardHi }
    $tips.SetToolTip($btnPause, $(if ($script:followPaused) { 'El seguimiento está en pausa: tocá para que te vuelva a llevar con el líder.' } else { 'Dejar de seguir al líder un rato (seguís en el grupo).' }))
}

function Set-GroupLeader([string]$sid) {
    if ($sid -eq $script:me) { $sid = '' }
    $script:groupLeader = $sid
    $script:followPaused = $false
    # Destino nuevo: olvidar a dónde te había llevado
    $script:followLobby = ''; $script:joinedServer = ''; $script:pendingAction = ''; $script:leaderState = ''; $script:leaderLobby = ''
    $script:groupKey = $null
    Write-AppLog "Grupo: sigo a $(if ($sid) { $sid } else { 'nadie (soy líder o estoy solo)' })"
    Send-Beat -Force
    Update-Group
    Update-FollowButtons
}

# "Unirse a un amigo": entrás a su grupo. Si es tu amigo, seguís directo al líder (Steam te dice dónde
# está); si no, seguís al amigo, que a su vez sigue al líder.
function Join-Friend([string]$fid) {
    if (-not $fid -or -not $script:me) { return }
    $map = Get-MyPartyMap
    $myRoot = Get-PartyRoot (Get-SidHash $script:me) $map
    $root = Get-PartyRoot (Get-SidHash $fid) $map
    if ($root -eq $myRoot) { $status.Text = "$(Get-FriendName $fid) ya está en tu grupo."; return }
    $target = $fid
    $rootFr = $script:friendByHash[$root]
    if ($rootFr -and [string]$rootFr.SteamId -ne $script:me) { $target = [string]$rootFr.SteamId }
    Set-GroupLeader $target
    $leaderName = if ($rootFr) { $rootFr.Name } else { Get-FriendName $fid }
    Write-AppLog "Me uní al grupo de $leaderName (elegí a $fid, sigo a $target)"
    [System.Media.SystemSounds]::Asterisk.Play()
    $status.Text = "Te uniste al grupo de $leaderName. Te llevo a donde vaya ($($script:followKeyName) pausa)."
    Invoke-FollowCheck
}

function Exit-Group {
    Set-GroupLeader ''
    $status.Text = 'Saliste del grupo.'
}

function Set-FollowPaused([bool]$paused) {
    if (-not $script:groupLeader) { return }
    $script:followPaused = $paused; $script:pendingAction = ''
    Write-AppLog "Seguimiento $(if ($paused) { 'PAUSADO' } else { 'reanudado' })"
    Update-FollowButtons
    $script:groupKey = $null; Update-Group
    $status.Text = if ($paused) { "Seguimiento en pausa. $($script:followKeyName) o 'Reanudar' lo vuelve a activar." } else { "Seguimiento activado: te llevo con $(Get-FriendName $script:groupLeader)." }
    if (-not $paused) { Invoke-FollowCheck }
}

function New-AvatarImage([string]$name) {
    # Placeholder con la inicial mientras llega el avatar (o si el perfil no lo muestra)
    $bmp = New-Object Drawing.Bitmap(28, 28)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear($C.CardHi)
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString(([string]$name).Substring(0, [math]::Min(1, ([string]$name).Length)).ToUpper(), $F.Btn, (New-Object Drawing.SolidBrush($C.Text)), (New-Object Drawing.RectangleF(0, 0, 28, 28)), $sf)
    $g.Dispose()
    return $bmp
}

# Pide los avatares que falten y vuelve a dibujar lo que haga falta
function Request-Avatars([string[]]$sids, [scriptblock]$then) {
    $missing = @($sids | Where-Object { $_ -and -not $script:avatars[$_] -and -not $script:avatarTried[$_] })
    if (-not $missing.Count -or $Screenshot) { return }
    foreach ($s in $missing) { $script:avatarTried[$s] = $true }
    Start-Async 'avatars' { param($sids) Get-SteamAvatars $sids } @(, [string[]]$missing) {
        param($res, $err)
        $map = Get-First $res
        if (-not $map) { return }
        foreach ($k in @($map.Keys)) {
            try { $script:avatars[$k] = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [byte[]]$map[$k]))) } catch {}
        }
        Show-Group
    }
}

function Show-Group {
    $old = @($groupMembers.Controls); $groupMembers.Controls.Clear(); foreach ($ctl in $old) { $ctl.Dispose() }   # ojo: $c pisaria $C (colores)
    foreach ($m in $script:groupData) {
        $item = New-Object Windows.Forms.FlowLayoutPanel
        $item.AutoSize = $true; $item.WrapContents = $false
        $item.BackColor = if ($m.Leader) { RGB 58 44 30 } else { $C.Card }
        $item.Padding = New-Object Windows.Forms.Padding(3, 3, 10, 3); $item.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 0)
        $pic = New-Object Windows.Forms.PictureBox
        $pic.Size = New-Object Drawing.Size(28, 28); $pic.SizeMode = 'Zoom'; $pic.Margin = New-Object Windows.Forms.Padding(0)
        $pic.Image = if ($m.Sid -and $script:avatars[$m.Sid]) { $script:avatars[$m.Sid] } else { New-AvatarImage $m.Name }
        $item.Controls.Add($pic)
        if ($m.Leader) {
            $crown = New-Text (Get-UiText 'Líder') $F.Chip $C.Amber
            $crown.Margin = New-Object Windows.Forms.Padding(6, 8, 0, 0)
            $item.Controls.Add($crown)
            $tips.SetToolTip($item, 'Líder del grupo: los demás lo siguen a su server o sala')
        }
        $lbl = New-Text $m.Name $F.Body $(if ($m.Leader) { $C.Amber } else { $C.Text })
        $lbl.Margin = New-Object Windows.Forms.Padding(6, 6, 0, 0)
        $item.Controls.Add($lbl)
        $groupMembers.Controls.Add($item)
    }
    Request-Avatars @($script:groupData | ForEach-Object { $_.Sid }) $null
    if (Get-Command Update-Where -ErrorAction SilentlyContinue) { Update-Where }
}

# Arma el grupo con los avisos de todas las apps: el líder es el final de la cadena de "a quién sigo"
function Update-Group {
    if (-not $script:me) { return }
    $map = Get-MyPartyMap
    $myHash = Get-SidHash $script:me
    $root = Get-PartyRoot $myHash $map
    $hashes = @($map.Keys | Where-Object { (Get-PartyRoot $_ $map) -eq $root })
    if ($hashes -notcontains $root) { $hashes += $root }   # el líder puede no tener la app abierta
    $members = New-Object System.Collections.ArrayList
    $unknown = 0
    foreach ($h in (@($root) + @($hashes | Where-Object { $_ -ne $root }))) {
        $isLeader = $h -eq $root
        if ($h -eq $myHash) { [void]$members.Add([pscustomobject]@{ Sid = $script:me; Name = 'Vos'; Leader = $isLeader }); continue }
        $fr = $script:friendByHash[$h]
        if ($fr) { [void]$members.Add([pscustomobject]@{ Sid = [string]$fr.SteamId; Name = $fr.Name; Leader = $isLeader }) }
        elseif ($isLeader) { [void]$members.Add([pscustomobject]@{ Sid = ''; Name = 'Líder'; Leader = $true }) }
        else { $unknown++ }
    }
    if ($unknown) { [void]$members.Add([pscustomobject]@{ Sid = ''; Name = "+$unknown"; Leader = $false }) }
    $n = $members.Count - [int][bool]$unknown + $unknown
    $leaderName = $members[0].Name
    if ($n -le 1) { $members[0].Leader = $false }   # solo: no hay a quién liderar

    # Quién es nuevo de verdad: no estuvo en el grupo en los últimos 30 min (si alguien sale y vuelve
    # enseguida, por ejemplo al reiniciar la app, no suena de nuevo)
    $nowT = Get-Date
    $fresh = @($hashes | Where-Object { $_ -ne $myHash -and (-not $script:seenInGroup.ContainsKey($_) -or ($nowT - $script:seenInGroup[$_]).TotalMinutes -gt 30) })
    foreach ($h in $hashes) { $script:seenInGroup[$h] = $nowT }
    $hint = if ($n -le 1) { "Solo vos. Tocá 'Unirse a un amigo' para jugar con alguien; si se unen a vos, sos el líder." }
    elseif ($root -eq $myHash) { 'Sos el líder: te siguen a donde vayas.' }
    elseif ($script:followPaused) { 'Seguimiento en pausa.' }
    else { "Te llevo a donde vaya $leaderName." }
    $key = (($members | ForEach-Object { "$($_.Sid):$($_.Name):$($_.Leader)" }) -join ',') + "|$hint"
    if ($key -ne $script:groupKey) {
        $script:groupKey = $key
        $script:groupData = @($members)
        Show-Group
        $groupHint.Text = $hint
    }
    if ($n -ne $script:groupCount) {
        $old = $script:groupCount
        $script:groupCount = $n
        Write-AppLog "Grupo: ahora son $n (líder: $leaderName)"
        $numParty.Value = [math]::Min(4, [math]::Max(1, $n))
        Update-PartyLabel
        if ($old -gt 0 -and $n -gt $old -and $script:groupLoaded) {
            # Sonido solo si se sumó alguien nuevo y no estás jugando (con el juego adelante no se sabe de dónde viene)
            $gameFrontNow = $false; try { $gameFrontNow = [GameFocus]::IsFront() } catch {}
            if ($fresh.Count -and -not $gameFrontNow) { [System.Media.SystemSounds]::Asterisk.Play() }
            $status.Text = "Se sumó alguien al grupo: ahora son $n."
        }
        elseif ($old -gt 0 -and $n -lt $old) { $status.Text = "Alguien salió del grupo: ahora son $n." }
        if ($n -gt 4) { $status.Text = "El grupo tiene $n jugadores: en versus entran hasta 4 por equipo." }
    }
}

# El grupo viaja por ntfy.sh, que es gratis pero limita los pedidos por conexión (y si se pasan, bloquea
# la IP por un rato). Por eso: mirar cada 20 s, avisar solo al cambiar y cada 4 min, y si falla esperar.
$script:ntfyPauseUntil = [datetime]::MinValue
function Test-NtfyPaused { return (Get-Date) -lt $script:ntfyPauseUntil }
function Set-NtfyError([string]$err) {
    if (Test-NtfyPaused) { return }
    $mins = if ($err -match '429') { 10 } else { 3 }
    $script:ntfyPauseUntil = (Get-Date).AddMinutes($mins)
    Write-AppLog "ntfy.sh falló ($err): pauso el grupo $mins min."
}
# Los avisos del grupo llegan por UNA conexión que queda abierta con ntfy.sh: cada aviso llega al instante,
# sin preguntar cada tanto (y sin gastar pedidos: ntfy bloquea la IP si se hacen muchos). Si se corta, se
# reconecta esperando cada vez un poco más.
$partyValidity = 1200   # un aviso vale 20 min (cada app avisa cada 9 min, al cambiar de grupo y al cerrar)
$script:partyMsgs = @{}
$script:groupStream = $null
$script:streamFails = 0
$script:groupLoaded = $false
function Start-GroupStream {
    if (-not $script:me -or $Screenshot -or $script:groupStream) { return }
    $script:groupStream = [L4dLines]::FromUrl("https://ntfy.sh/$followTopic/json?since=20m", 100000, $form,
        [Action[string]] { param($line) Receive-GroupLine $line },
        [Action[string]] { param($err) Stop-GroupStream $err })
}
function Receive-GroupLine([string]$line) {
    try { $m = $line | ConvertFrom-Json } catch { return }
    if ($m.event -eq 'open') { Write-AppLog "Grupo: conectado con ntfy.sh, los avisos llegan al instante."; $script:streamFails = 0; return }
    if ($m.event -ne 'message') { return }
    try { $d = [string]$m.message | ConvertFrom-Json } catch { return }
    $h = "$($d.h)"
    if ($h -notmatch '^[0-9a-f]{16}$') { return }
    $prev = $script:partyMsgs[$h]
    if ($prev -and $prev.Time -gt [long]$m.time) { return }
    $script:partyMsgs[$h] = [pscustomobject]@{ Topic = $followTopic; Time = [long]$m.time; Data = $d }
    # Al conectar llegan de golpe los avisos de los últimos 20 min: se aplican todos juntos
    $groupApply.Stop(); $groupApply.Start()
}
function Update-PartyFromMessages {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($k in @($script:partyMsgs.Keys)) { if (($now - $script:partyMsgs[$k].Time) -gt $partyValidity) { $script:partyMsgs.Remove($k) } }
    $script:partyMap = Get-PartyMap @($script:partyMsgs.Values) $partyValidity
    Update-Group
    $script:groupLoaded = $true
    # Cuando venza el próximo aviso (alguien a quien se le colgó la app), revisar justo en ese momento
    $expireTimer.Stop()
    if ($script:partyMsgs.Count) {
        $next = ($script:partyMsgs.Values | Measure-Object -Property Time -Minimum).Minimum + $partyValidity - $now
        $expireTimer.Interval = [int]([math]::Max(1, [math]::Min(2000000, $next)) * 1000 + 500)
        $expireTimer.Start()
    }
}
function Stop-GroupStream([string]$err) {
    $script:groupStream = $null
    $script:streamFails++
    $wait = if ($err -match '429') { 600 } else { @(2, 5, 15, 30, 60)[[math]::Min(4, $script:streamFails - 1)] }
    Write-AppLog "Grupo: se cortó la conexión con ntfy.sh ($err). Reconecto en $wait s."
    $reconnectTimer.Interval = $wait * 1000
    $reconnectTimer.Start()
}
$groupApply = New-Object Windows.Forms.Timer
$groupApply.Interval = 150
$groupApply.add_Tick({ $this.Stop(); Update-PartyFromMessages })
$expireTimer = New-Object Windows.Forms.Timer
$expireTimer.add_Tick({ $this.Stop(); Update-PartyFromMessages })
$reconnectTimer = New-Object Windows.Forms.Timer
$reconnectTimer.add_Tick({ $this.Stop(); Start-GroupStream })

# Cada 9 min cada app avisa que sigue abierta (así, si a alguien se le cuelga, deja de figurar solo).
# Los cambios (unirse, salir, cerrar) se avisan en el momento.
$beatTimer = New-Object Windows.Forms.Timer
$beatTimer.Interval = 540000
$beatTimer.add_Tick({ Send-Beat })
$beatTimer.Start()

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Update-FriendList([switch]$Quiet) {
    if (-not $script:me) { $script:me = Get-MySteamId }
    if (-not $script:me) { if (-not $Quiet) { $status.Text = 'No encuentro tu cuenta de Steam: abrí Steam.' }; return }
    # Nombres de tus amigos (config local de Steam, sin internet). Quién está jugando lo dice el vigía.
    Start-Async 'friends' {
        param($me)
        $everyone = @(Get-LocalFriends $me)   # incluye tu propia cuenta
        , @($everyone | ForEach-Object { [pscustomobject]@{ SteamId = $_.SteamId; Name = $_.Name; Hash = (Get-SidHash $_.SteamId) } })
    } @($script:me) {
        param($res, $err)
        if ($err) { Write-AppLog "No pude cargar la lista de amigos: $err"; return }
        $all = @($res | ForEach-Object { $_ })
        $byHash = @{}; $names = @{}
        foreach ($fr in $all) { $byHash[$fr.Hash] = $fr; $names[[string]$fr.SteamId] = [string]$fr.Name }   # ojo: $f pisaria $F (fuentes)
        $script:friendByHash = $byHash; $script:friendNameById = $names
        if ($names[[string]$script:me]) { $script:myName = $names[[string]$script:me] }   # para reconocerte en la lista de jugadores de un server
        $script:groupKey = ''; Update-Group   # ahora con nombres
    }
}

# Amigos que están en L4D2 ahora (según el vigía)
function Get-PlayingFriends { if ($script:steamNow) { return @($script:steamNow.friends) } return @() }

# Menú "Unirse a un amigo": los que están jugando L4D2 (lo dice tu Steam, con el juego abierto) y los que
# tienen la app abierta. Al lado, dónde están y en qué grupo.
function Show-FriendsMenu {
    $menuFriends.Items.Clear()
    $map = Get-MyPartyMap
    $myHash = if ($script:me) { Get-SidHash $script:me } else { '' }
    $myRoot = if ($myHash) { Get-PartyRoot $myHash $map } else { '' }
    $rows = @{}
    foreach ($p in (Get-PlayingFriends)) {
        $id = [string]$p.id
        $where = if ($p.server) { 'jugando en un server' } elseif ($p.lobby) { 'en una sala de espera' } else { 'en el menú de L4D2' }
        $rows[$id] = [pscustomobject]@{ Sid = $id; Name = (Get-FriendName $id); Where = $where; Order = 0 }
    }
    foreach ($h in $map.Keys) {
        if ($h -eq $myHash) { continue }
        $fr = $script:friendByHash[$h]
        if (-not $fr -or $rows.ContainsKey([string]$fr.SteamId)) { continue }
        $rows[[string]$fr.SteamId] = [pscustomobject]@{ Sid = [string]$fr.SteamId; Name = $fr.Name; Where = 'con la app abierta'; Order = 1 }
    }
    $sorted = @($rows.Values | Sort-Object Order, Name)
    if (-not $sorted.Count) {
        $it = $menuFriends.Items.Add('Ningún amigo con L4D2 o la app abierta ahora')
        $it.Enabled = $false
    }
    foreach ($r in $sorted) {
        $h = Get-SidHash $r.Sid
        $root = Get-PartyRoot $h $map
        $extra = if ($myRoot -and $root -eq $myRoot) { '   ·   en tu grupo' }
        elseif ($root -ne $h) { $ln = if ($script:friendByHash[$root]) { $script:friendByHash[$root].Name } else { 'otro' }; "   ·   grupo de $ln" }
        else { '' }
        $it = New-Object Windows.Forms.ToolStripMenuItem("$($r.Name)   —   $($r.Where)$extra")
        $it.Tag = $r.Sid
        $it.Image = if ($script:avatars[$r.Sid]) { $script:avatars[$r.Sid] } else { New-AvatarImage $r.Name }
        if ($myRoot -and $root -eq $myRoot) { $it.Enabled = $false }
        $it.add_Click({ Join-Friend ([string]$this.Tag) })
        [void]$menuFriends.Items.Add($it)
    }
    if (-not $script:steamNow) {
        [void]$menuFriends.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        $note = $menuFriends.Items.Add('Abrí L4D2 para ver también quién está jugando')
        $note.Enabled = $false
    }
    $menuFriends.Show($btnJoinFriend, 0, $btnJoinFriend.Height)
    Request-Avatars @($sorted | ForEach-Object { $_.Sid }) $null
}

# Nombres de amigos: se releen cuando Steam cambia su archivo de config (Windows avisa), no cada tanto
$friendsDebounce = New-Object Windows.Forms.Timer
$friendsDebounce.Interval = 3000   # Steam escribe el archivo varias veces seguidas
$friendsDebounce.add_Tick({ $this.Stop(); Update-FriendList -Quiet })
$script:friendsWatcher = $null
function Start-FriendsWatcher {
    if ($Screenshot -or $script:friendsWatcher -or -not $script:me) { return }
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return }
    $dir = Join-Path $steam "userdata\$([int64]$script:me - 76561197960265728)\config"
    if (-not (Test-Path $dir)) { return }
    try {
        $fsw = New-Object IO.FileSystemWatcher($dir, 'localconfig.vdf')
        $fsw.NotifyFilter = [IO.NotifyFilters]'LastWrite, Size, FileName'
        $fsw.SynchronizingObject = $form   # el aviso llega en el hilo de la ventana
        $onChange = { $friendsDebounce.Stop(); $friendsDebounce.Start() }
        $fsw.add_Changed($onChange); $fsw.add_Created($onChange); $fsw.add_Renamed($onChange)
        $fsw.EnableRaisingEvents = $true
        $script:friendsWatcher = $fsw
    } catch { Write-AppLog "No pude vigilar la lista de amigos: $($_.Exception.Message)" }
}

# ---------------- vigía de Steam ----------------
# Mientras L4D2 está abierto corre lobbies.ps1 -Watch: Steam le avisa al instante cuando vos o un amigo
# cambian de server o sala, y la app reacciona a cada aviso. No usa internet ni API key, y no hace falta
# que el otro tenga la app abierta.
$script:watch = $null
$script:steamNow = $null
$script:watchFails = 0
function Start-Watcher {
    try {
        $h = Start-LobbyHelper $here ("-Watch -ParentPid $PID") -Stream
        $script:watch = @{ Proc = $h.Proc; Started = Get-Date }
        $script:watch.Reader = [L4dLines]::FromReader($h.Proc.StandardOutput, $form,
            [Action[string]] { param($line) Receive-WatchLine $line },
            [Action[string]] { param($err) Stop-Watcher })
        $gameTimer.Stop()
        Write-AppLog 'Vigía de Steam iniciado (L4D2 abierto).'
    } catch {
        $script:watchFails++
        $gameTimer.Interval = [math]::Min(120000, 10000 * $script:watchFails)
        Write-AppLog "No pude iniciar el vigía de Steam: $($_.Exception.Message)"
    }
}
function Receive-WatchLine([string]$line) {
    if ($line -like 'ERROR:*') { Write-AppLog "Vigía de Steam: $line"; return }
    if (-not $line.StartsWith('{')) { return }
    try { $now = $line | ConvertFrom-Json } catch { return }
    $before = $script:steamNow
    $script:steamNow = $now
    # Saliste de una partida o sala (volviste al menú): buen momento para tener la lista al día
    if ($before -and "$($before.me.server)$($before.me.lobby)" -and -not "$($now.me.server)$($now.me.lobby)") { Invoke-AutoRefresh 'saliste de la partida' 0 }
    Invoke-FollowCheck
    Update-Where
}
function Stop-Watcher {
    $w = $script:watch
    $script:watch = $null; $script:steamNow = $null
    if ($w -and ((Get-Date) - $w.Started).TotalSeconds -lt 15) { $script:watchFails++ } else { $script:watchFails = 0 }
    $gameTimer.Interval = if ($script:watchFails) { [math]::Min(120000, 10000 * $script:watchFails) } else { 3000 }
    $gameTimer.Start()
    Write-AppLog 'Vigía de Steam terminado.'
    Update-Where
}
# Lo único que se sigue mirando cada tanto: si abriste el juego (mirar la lista de procesos no cuesta nada;
# el aviso de Windows para esto pide permisos de administrador). Con el juego abierto queda apagado.
$gameTimer = New-Object Windows.Forms.Timer
$gameTimer.Interval = 3000
$gameTimer.add_Tick({
        if ($Screenshot -or $script:watch) { return }
        if (Get-Process left4dead2 -ErrorAction SilentlyContinue) { Start-Watcher }
    })
$gameTimer.Start()

# ---------------- dónde están ----------------
# Debajo de "Tu grupo", una tarjeta por cada lugar donde hay alguien del grupo (vos incluido): imagen del
# mapa, campaña y capítulo, server o sala, si es pública o de solo amigos, quiénes están ahí y cuántos
# lugares quedan. Se arma con lo que avisa el vigía de Steam (al instante) y, para los servers, con una
# consulta directa al server (mapa y jugadores) cada 15 s mientras haya alguien adentro.
$script:whereInfo = @{}      # "ip:puerto" -> respuesta del server (Name, Map, Players, MaxPlayers, Ping)
$script:whereKey = $null
$script:whereAddrs = ''
$whereApply = New-Object Windows.Forms.Timer
$whereApply.Interval = 200
$whereApply.add_Tick({ $this.Stop(); Show-Where })
function Update-Where { $whereApply.Stop(); $whereApply.Start() }
$whereTimer = New-Object Windows.Forms.Timer
$whereTimer.Interval = 15000
$whereTimer.add_Tick({ Request-WhereInfo })
$wherePanel.add_Resize({ if ($wherePanel.Visible) { Update-Where } })

function Get-WhereData {
    $now = $script:steamNow
    if (-not $now -or -not $script:me) { return $null }
    $members = @($script:groupData | Where-Object { $_.Sid })
    if (-not @($members | Where-Object { $_.Sid -eq $script:me }).Count) { $members = @([pscustomobject]@{ Sid = $script:me; Name = 'Vos'; Leader = $false }) + $members }
    $locs = [ordered]@{}
    $others = New-Object Collections.ArrayList
    foreach ($m in $members) {
        $st = if ($m.Sid -eq $script:me) { $now.me } else { @($now.friends | Where-Object { [string]$_.id -eq $m.Sid }) | Select-Object -First 1 }
        if (-not $st) { [void]$others.Add("$($m.Name): no está jugando L4D2"); continue }
        $srv = [string]$st.server; $lob = [string]$st.lobby
        if (-not $srv -and -not $lob) { [void]$others.Add("$($m.Name): en el menú del juego"); continue }
        $key = if ($srv) { "s:$srv" } else { "l:$lob" }
        if (-not $locs.Contains($key)) { $locs[$key] = [pscustomobject]@{ Server = $srv; Lobby = $lob; Members = (New-Object Collections.ArrayList) } }
        if (-not $locs[$key].Lobby -and $lob) { $locs[$key].Lobby = $lob }
        [void]$locs[$key].Members.Add($m)
    }
    return [pscustomobject]@{ Locs = @($locs.Values); Others = @($others); Count = $members.Count }
}

# Lo que se muestra de un lugar, juntando la sala (Steam) y la respuesta del server
function Get-WhereCardData($loc) {
    $ld = $null
    if ($loc.Lobby -and $script:steamNow.lobbies) { $pr = $script:steamNow.lobbies.PSObject.Properties[$loc.Lobby]; if ($pr) { $ld = $pr.Value } }
    $info = if ($loc.Server) { $script:whereInfo[$loc.Server] } else { $null }
    $camp = ''; $ldTitle = ''; $ldMap = ''
    if ($ld) {
        $raw = [string]$ld.campaign
        $camp = if ($raw -match '^L4D2C(\d+)$' -and $campaigns.Contains("c$($Matches[1])")) { "c$($Matches[1])" } else { 'custom' }
        $chapter = [int]$ld.chapter; if ($chapter -le 0) { $chapter = 1 }
        $nm = if ($camp -ne 'custom') { $campaigns[$camp] } elseif ($ld.title -and -not ([string]$ld.title).StartsWith('#')) { [string]$ld.title } else { $raw }
        $ldTitle = "$nm  ·  Capítulo $chapter"
        $ldMap = if ($camp -ne 'custom') { $camp } else { $raw.ToLower() }
    }
    $map = ''; $title = ''; $sub = ''
    if ($info -and $info.Map) {
        $map = [string]$info.Map; $title = Get-MapTitle $map
        if ($title -eq $map -and $ldTitle) { $title = $ldTitle }
        $sub = [string]$info.Name
    } elseif ($ldTitle) { $title = $ldTitle; $map = $ldMap }
    else { $title = if ($loc.Server) { 'Entrando al server...' } else { 'Sala de espera' } }
    if (-not $sub) { $sub = if ($loc.Server) { $loc.Server } else { 'Sala de espera' } }
    $ws = if ($ld) { ConvertFrom-HexId ([string]$ld.ws) } else { '' }
    $isCustom = if ($ld) { $camp -eq 'custom' } elseif ($map) { (Get-CampaignKey $map) -eq 'custom' } else { $false }

    $chips = New-Object Collections.ArrayList
    $inGame = [bool]$loc.Server -or ($ld -and $ld.state -eq 'game')
    [void]$chips.Add(@($(if ($inGame) { 'EN PARTIDA' } else { 'EN LA SALA' }), $(if ($inGame) { $C.Green } else { $C.Blue }), $C.Bg))
    if ($ld) {
        switch ([string]$ld.access) {
            'public' { [void]$chips.Add(@('PÚBLICA', $C.CardHi, $C.Dim)) }
            'friends' { [void]$chips.Add(@('SOLO AMIGOS', $C.CardHi, $C.Orange)) }
            'private' { [void]$chips.Add(@('PRIVADA', $C.CardHi, $C.Orange)) }
        }
    }
    $official = ($ld -and $ld.server -eq 'official') -or ($info -and ([string]$info.Name) -like 'Valve Left4Dead 2*')
    if ($official) { [void]$chips.Add(@('OFICIAL VALVE', $C.CardHi, $C.Dim)) }
    if ($isCustom) { [void]$chips.Add(@('MAPA CUSTOM', $C.CardHi, $C.Amber)) }

    $humans = 0; $max = 0
    if ($info -and $info.MaxPlayers) { $humans = [int]$info.Players; $max = [int]$info.MaxPlayers }
    elseif ($ld -and [int]$ld.slots) { $humans = [int]$ld.players; $max = [int]$ld.slots }
    $here = @($loc.Members | Where-Object { $_.Sid -eq $script:me }).Count -gt 0
    $link = if ($here) { '' } elseif ($loc.Lobby) { "steam://joinlobby/550/$($loc.Lobby)" } else { "steam://connect/$($loc.Server)" }
    $ping = if ($info -and $null -ne $info.Ping) { [int]$info.Ping } else { $null }
    return [pscustomobject]@{
        Title = $title; Sub = $sub; Map = $map; WorkshopId = $ws; Custom = $isCustom; Chips = @($chips)
        Members = @($loc.Members); Humans = $humans; Max = $max; Ping = $ping; Link = $link; Here = $here
    }
}

function New-WhereCard($d) {
    $W = Get-CardWidth; $H = 112
    # Distinta a las de la lista a simple vista: fondo cálido (como el del líder), marco verde si estás ahí o
    # ámbar si no, y las caras del grupo arriba de la imagen del mapa
    $bg = RGB 52 40 27
    $edge = if ($d.Here) { $C.Green } else { $C.Amber }
    $card = New-Object L4dCard
    $card.Size = New-Object Drawing.Size($W, $H); $card.BackColor = $bg
    $strip = New-Object Windows.Forms.Panel
    $strip.BackColor = $edge; $strip.Location = New-Object Drawing.Point(0, 0); $strip.Size = New-Object Drawing.Size(4, $H)

    $pic = New-Object Windows.Forms.PictureBox
    $pic.Location = New-Object Drawing.Point(4, 0); $pic.Size = New-Object Drawing.Size(200, $H); $pic.BackColor = $bg
    $img = $null
    if ($d.Map) {
        if ($d.Custom) {
            $id = if ($d.WorkshopId) { $d.WorkshopId } else { Get-CustomWorkshopId $script:customIx $d.Map }
            if ($id) { $img = Get-MapImage "ws_$id" }
            if (-not $img) { $img = Get-MapImage $d.Map }
            if (-not $img) { $img = Get-MapImage 'addon' }
        } else { $img = Get-MapImage $d.Map }
    }
    if ($img) { $pic.Image = Get-CardThumb $img 200 $H $bg }

    $x = 222; $rightW = 320; $midW = $W - $x - $rightW - 10
    $t = New-Text (Get-UiText $d.Title) $F.H $C.Text
    $t.Location = New-Object Drawing.Point($x, 8)
    $sub = New-Text $d.Sub $F.Body $C.Dim
    $sub.AutoSize = $false; $sub.AutoEllipsis = $true
    $sub.Location = New-Object Drawing.Point($x, 36); $sub.Size = New-Object Drawing.Size($midW, 20)
    $chips = New-Object Windows.Forms.FlowLayoutPanel
    $chips.BackColor = [Drawing.Color]::Transparent; $chips.WrapContents = $false
    $chips.Location = New-Object Drawing.Point($x, 58); $chips.Size = New-Object Drawing.Size($midW, 22)
    foreach ($ch in $d.Chips) { $chips.Controls.Add((New-Chip $ch[0] $ch[1] $ch[2])) }

    # Quiénes están acá: avatar y nombre (el líder en ámbar)
    $who = New-Object Windows.Forms.FlowLayoutPanel
    $who.BackColor = [Drawing.Color]::Transparent; $who.WrapContents = $false
    $who.Location = New-Object Drawing.Point($x, 84); $who.Size = New-Object Drawing.Size($midW, 24)
    foreach ($m in $d.Members) {
        $av = New-Object Windows.Forms.PictureBox
        $av.Size = New-Object Drawing.Size(20, 20); $av.SizeMode = 'Zoom'; $av.Margin = New-Object Windows.Forms.Padding(0, 1, 0, 0)
        $av.Image = if ($script:avatars[$m.Sid]) { $script:avatars[$m.Sid] } else { New-AvatarImage $m.Name }
        $nm = New-Text $m.Name $F.Small $(if ($m.Leader) { $C.Amber } else { $C.Text })
        $nm.Margin = New-Object Windows.Forms.Padding(4, 3, 12, 0)
        $who.Controls.AddRange(@($av, $nm))
    }

    $keep = @()
    $ctls = @($strip, $pic, $t, $sub, $chips, $who)
    $slotX = $W - 176 - 132
    if ($d.Max -gt 0) {
        $free = [math]::Max(0, $d.Max - $d.Humans)
        $slots = New-Text "$($d.Humans)/$($d.Max)" $F.Slots $C.Text
        $slots.AutoSize = $false; $slots.TextAlign = 'MiddleCenter'
        $slots.Size = New-Object Drawing.Size(120, 46); $slots.Location = New-Object Drawing.Point($slotX, 10)
        $pips = New-Object Windows.Forms.PictureBox
        $pips.Size = New-Object Drawing.Size(120, 12); $pips.Location = New-Object Drawing.Point($slotX, 60)
        $pips.BackColor = $bg; $pips.Image = Get-SlotPips $d.Humans $d.Max $C.Green $bg
        $freeText = switch ($free) { 0 { 'Lleno' } 1 { 'Queda 1' } default { "Quedan $free" } }
        $slotsSub = New-Text (Get-UiText $freeText) $F.SlotsSub $(if ($free) { $C.Green } else { $C.Orange })
        $slotsSub.AutoSize = $false; $slotsSub.TextAlign = 'MiddleCenter'
        $slotsSub.Size = New-Object Drawing.Size(120, 20); $slotsSub.Location = New-Object Drawing.Point($slotX, 78)
        $ctls += @($slots, $pips, $slotsSub)
    }
    if ($null -ne $d.Ping) {
        $ping = New-Text "$($d.Ping) ms" $F.Ping (Get-PingColor $d.Ping)
        $ping.AutoSize = $false; $ping.TextAlign = 'MiddleRight'
        $ping.Size = New-Object Drawing.Size(160, 26); $ping.Location = New-Object Drawing.Point(($W - 176), 8)
        $ctls += $ping
    }
    if ($d.Here) {
        $hereLbl = New-Text (Get-UiText 'Estás acá') $F.Btn $C.Green
        $hereLbl.AutoSize = $false; $hereLbl.TextAlign = 'MiddleCenter'
        $hereLbl.Size = New-Object Drawing.Size(160, 34); $hereLbl.Location = New-Object Drawing.Point(($W - 176), 44)
        $ctls += $hereLbl
    } elseif ($d.Link) {
        $join = New-FlatButton (Get-UiText 'Unirme') $C.Accent $C.AccentHi 160 34
        $join.Location = New-Object Drawing.Point(($W - 176), 44); $join.Tag = $d.Link
        $join.add_Click({ Invoke-Join $this.Tag })
        $ctls += $join; $keep += $join
    }
    $card.Controls.AddRange([Windows.Forms.Control[]]$ctls)
    $faces = @($d.Members | ForEach-Object { if ($script:avatars[$_.Sid]) { $script:avatars[$_.Sid] } else { New-AvatarImage $_.Name } })
    Convert-CardToImage $card $keep {
        param($g, $w, $h)
        # Marco de 2 px alrededor de toda la tarjeta
        $pen = New-Object Drawing.Pen($edge, 2)
        $g.SmoothingMode = 'None'
        $g.DrawRectangle($pen, 1, 1, ($w - 2), ($h - 2))
        $g.SmoothingMode = 'AntiAlias'
        # Caras del grupo sobre la imagen, abajo a la izquierda (con borde del color del marco)
        $sz = 30; $fx = 12; $fy = $h - $sz - 10
        foreach ($img in ($faces | Select-Object -First 5)) {
            $g.FillRectangle((New-Object Drawing.SolidBrush($edge)), ($fx - 2), ($fy - 2), ($sz + 4), ($sz + 4))
            $g.DrawImage($img, $fx, $fy, $sz, $sz)
            $fx += $sz + 6
        }
    }
    return $card
}

function Show-Where {
    $data = Get-WhereData
    $show = $data -and ($data.Locs.Count -gt 0 -or $data.Count -gt 1)
    # Servers a consultar (si cambiaron, ya mismo; después cada 15 s)
    $addrs = if ($show) { @($data.Locs | Where-Object { $_.Server } | ForEach-Object { $_.Server }) } else { @() }
    $addrKey = $addrs -join ','
    if ($addrKey -ne $script:whereAddrs) { $script:whereAddrs = $addrKey; if ($addrs.Count) { Request-WhereInfo } }
    if ($addrs.Count) { if (-not $whereTimer.Enabled) { $whereTimer.Start() } } else { $whereTimer.Stop() }

    $cards = if ($show) { @($data.Locs | ForEach-Object { Get-WhereCardData $_ }) } else { @() }
    $key = if ($show) {
        "$(Get-CardWidth)|" + (($cards | ForEach-Object {
                    "$($_.Title)~$($_.Sub)~$($_.Map)~$($_.Humans)/$($_.Max)~$($_.Ping)~$($_.Link)~$($_.Here)~" +
                    (($_.Chips | ForEach-Object { $_[0] }) -join '+') + '~' + (($_.Members | ForEach-Object { "$($_.Name):$($_.Leader):$([bool]$script:avatars[$_.Sid])" }) -join '+')
                }) -join '||') + '|' + ($data.Others -join ';')
    } else { '' }
    if ($key -eq $script:whereKey) { return }
    $script:whereKey = $key

    Invoke-Frozen {
        $old = @($wherePanel.Controls); $wherePanel.Controls.Clear(); foreach ($ctl in $old) { $ctl.Dispose() }
        if (-not $show) { $wherePanel.Visible = $false; return }
        $y = 8
        $cap = New-Text (Get-UiText 'Dónde está tu grupo') $F.Btn $C.Amber
        $cap.Location = New-Object Drawing.Point(16, $y); $wherePanel.Controls.Add($cap)
        $y += 26
        foreach ($d in $cards) {
            $cardCtl = New-WhereCard $d
            $cardCtl.Location = New-Object Drawing.Point(16, $y)
            $wherePanel.Controls.Add($cardCtl)
            $y += $cardCtl.Height + 8
        }
        if ($data.Others.Count) {
            $o = New-Text ($data.Others -join '    ·    ') $F.Small $C.Dim
            $o.Location = New-Object Drawing.Point(18, $y); $wherePanel.Controls.Add($o)
            $y += 22
        }
        $wherePanel.Height = $y + 6
        $line = New-Object Windows.Forms.Panel
        $line.BackColor = RGB 74 58 36; $line.Height = 2; $line.Dock = 'Bottom'
        $wherePanel.Controls.Add($line)
        $wherePanel.Visible = $true
    }
}

# Mapa, nombre y jugadores de los servers donde está el grupo (consulta directa, sin Steam ni internet extra)
function Request-WhereInfo {
    $addrs = @($script:whereAddrs -split ',' | Where-Object { $_ })
    if (-not $addrs.Count -or $script:busy['whereinfo']) { return }
    Start-Async 'whereinfo' {
        param($finder, $addrs)
        $src = [IO.File]::ReadAllText($finder)
        $a = $src.IndexOf('# >>> BUSQUEDA'); $b = $src.IndexOf('# <<< BUSQUEDA')
        . ([scriptblock]::Create($src.Substring($a, $b - $a)))
        Invoke-InfoScan $addrs 40 1500
    } @((Join-Path $here 'finder.ps1'), [string[]]$addrs) {
        param($res, $err)
        foreach ($i in @($res)) { if ($i -and $i.Addr) { $script:whereInfo[[string]$i.Addr] = $i } }
        Update-Where
        # Respaldo: con datos nuevos del server, revisar si hay que esperar lugar o reintentar
        Invoke-FollowCheck
    }
}


# ---------------- seguir ----------------
# Se revisa con cada aviso del vigía. Un destino nuevo se confirma a los 2 s con un único temporizador.
$confirmTimer = New-Object Windows.Forms.Timer
$confirmTimer.Interval = 2100
$confirmTimer.add_Tick({ $this.Stop(); Invoke-FollowCheck })
$script:connectTo = ''; $script:connectAt = [datetime]::MinValue; $script:waitingSlot = $false
# ¿La última orden "connect" a este server no funcionó? (pasaron 25 s y Steam no dice que estés ahí)
function Test-ConnectFailed([string]$server, [string]$myServer) {
    if ($myServer -eq $server -or $script:connectTo -ne $server) { return $false }
    return ((Get-Date) - $script:connectAt).TotalSeconds -ge 25
}

# --- esperar lugar en el server del líder ---
# Un hilo chico (C#, un solo socket) le pregunta al server cada 1 s cuánta gente tiene (A2S_INFO, un paquete
# de ~25 bytes) y avisa a la ventana en cuanto hay un lugar. Solo existe mientras estás esperando: al entrar,
# si el líder se mueve, si pausás o cerrás la app, se apaga. Sin consultas a internet ni tareas pesadas.
if (-not ('L4dSlotWatch' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;
public class L4dSlotWatch {
    volatile bool stop;
    public string Addr;
    static readonly byte[] Req = Build(null);
    static byte[] Build(byte[] challenge) {
        var q = new System.Collections.Generic.List<byte>(new byte[] { 255, 255, 255, 255, 0x54 });
        q.AddRange(Encoding.ASCII.GetBytes("Source Engine Query")); q.Add(0);
        if (challenge != null) q.AddRange(challenge);
        return q.ToArray();
    }
    // onFree(jugadores, máximo) se llama una vez, en el hilo de la ventana, al ver un lugar libre
    public static L4dSlotWatch Start(string addr, int intervalMs, Control ui, Action<int, int> onFree) {
        var w = new L4dSlotWatch(); w.Addr = addr;
        var t = new Thread(() => w.Loop(addr, intervalMs, ui, onFree));
        t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        return w;
    }
    void Loop(string addr, int intervalMs, Control ui, Action<int, int> onFree) {
        int c = addr.LastIndexOf(':');
        var ep = new IPEndPoint(IPAddress.Parse(addr.Substring(0, c)), int.Parse(addr.Substring(c + 1)));
        using (var udp = new UdpClient(0)) {
            udp.Client.ReceiveTimeout = 800;
            try { udp.Client.IOControl(-1744830452, new byte[] { 0, 0, 0, 0 }, null); } catch { }
            while (!stop) {
                var started = DateTime.UtcNow;
                try {
                    udp.Send(Req, Req.Length, ep);
                    var from = new IPEndPoint(IPAddress.Any, 0);
                    byte[] d = udp.Receive(ref from);
                    if (d.Length >= 9 && d[4] == 0x41) {   // el server pide el desafío: se repite con él
                        var r2 = Build(new byte[] { d[5], d[6], d[7], d[8] });
                        udp.Send(r2, r2.Length, ep);
                        d = udp.Receive(ref from);
                    }
                    if (d.Length > 6 && d[4] == 0x49) {
                        int p = 6;
                        for (int s = 0; s < 4; s++) { while (p < d.Length && d[p] != 0) p++; p++; }   // nombre, mapa, carpeta, juego
                        p += 2;   // appid
                        if (p + 1 < d.Length) {
                            int players = d[p], max = d[p + 1];
                            if (max > 0 && players < max && !stop) {
                                stop = true;
                                try { if (!ui.IsDisposed) ui.BeginInvoke(onFree, players, max); } catch { }
                                return;
                            }
                        }
                    }
                } catch { }
                int left = intervalMs - (int)(DateTime.UtcNow - started).TotalMilliseconds;
                if (left > 0 && !stop) Thread.Sleep(left);
            }
        }
    }
    public void Stop() { stop = true; }
}
"@
}
$script:slotWatch = $null; $script:slotTarget = ''; $script:slotSince = [datetime]::MinValue
function Sync-SlotWatch {
    $want = if ($script:waitingSlot) { $script:slotTarget } else { '' }
    if ($script:slotWatch -and $script:slotWatch.Addr -eq $want) { return }
    if ($script:slotWatch) { $script:slotWatch.Stop(); $script:slotWatch = $null; Write-AppLog 'Dejo de esperar lugar.' }
    if (-not $want) { return }
    $script:slotSince = Get-Date
    Write-AppLog "No entraste a $want (lleno). Lo miro cada 1 s y te meto apenas se libere un lugar."
    try { $script:slotWatch = [L4dSlotWatch]::Start($want, 1000, $form, [Action[int, int]] { param($pl, $mx) Invoke-SlotFree $pl $mx }) }
    catch { Write-AppLog "No pude vigilar el server: $($_.Exception.Message)" }
}
# Se liberó un lugar: conectar ya, sin la confirmación de 2 s (acá cada segundo cuenta)
function Invoke-SlotFree([int]$players, [int]$max) {
    $addr = if ($script:slotWatch) { $script:slotWatch.Addr } else { '' }
    $script:slotWatch = $null
    $b = if ($script:steamNow) { @($script:steamNow.friends | Where-Object { [string]$_.id -eq $script:groupLeader }) | Select-Object -First 1 }
    if (-not $addr -or -not (Test-Following) -or -not $b -or [string]$b.server -ne $addr -or [string]$script:steamNow.me.server -eq $addr) {
        Write-AppLog "Lugar libre en $addr, pero ya no hace falta (te moviste, pausaste o el líder cambió)."
        Invoke-FollowCheck; return
    }
    Write-AppLog ("Lugar libre en {0} ({1}/{2}) tras {3:N0} s esperando: conecto ya." -f $addr, $players, $max, ((Get-Date) - $script:slotSince).TotalSeconds)
    $script:waitingSlot = $false; $script:pendingAction = ''; $confirmTimer.Stop()
    $script:joinedServer = $addr
    Invoke-FollowCommand "steam://connect/$addr"
    $status.Text = "Se liberó un lugar en el server de $(Get-FriendName $script:groupLeader): entrando..."
}
# 26 s después de cada "connect": si no entraste, pasar a esperar lugar sin depender de otro aviso
$failCheck = New-Object Windows.Forms.Timer
$failCheck.Interval = 26000
$failCheck.add_Tick({ $this.Stop(); Invoke-FollowCheck })

function Invoke-FollowCheck {
    Invoke-FollowCheckCore
    Sync-SlotWatch
}
function Invoke-FollowCheckCore {
    $script:waitingSlot = $false
    if (-not (Test-Following)) { return }
    $fid = $script:groupLeader
    $name = Get-FriendName $fid
    if (-not $script:steamNow) { $status.Text = "Para seguir a $name, abrí L4D2: la app mira en tu Steam dónde está mientras jugás."; return }
    $b = @($script:steamNow.friends | Where-Object { [string]$_.id -eq $fid })
    if (-not $b.Count) { $status.Text = "$name no está jugando L4D2 ahora."; return }
    $b = $b[0]; $mine = $script:steamNow.me
    $bServer = [string]$b.server; $bLobby = [string]$b.lobby; $myServer = [string]$mine.server; $myLobby = [string]$mine.lobby

    $state = "$bServer|$bLobby"
    if ($state -ne $script:leaderState) { Write-AppLog "Líder ${name}: server='$bServer' lobby='$bLobby'   (yo: server='$myServer' lobby='$myLobby')" }
    $prevLobby = $script:leaderLobby   # lobby del lider antes del ultimo cambio
    if ($state -ne $script:leaderState) { $script:leaderLobby = $bLobby }
    $script:leaderState = $state

    # Reglas (cualquier orden de mas saca al juego de la partida en la que estás):
    # - Si ya estás en su mismo server o lobby, no se hace nada.
    # - Si entraste a su lobby, al arrancar la partida el juego te lleva con el lobby: no conectar a mano.
    # - Un destino nuevo se confirma si sigue igual 2 s (para no reaccionar a estados de paso).
    # - Antes de conectar a un server, si Steam no dice dónde estás, se mira tu nombre en su lista de jugadores.
    $action = ''
    if ($bServer) {
        if ($myServer -eq $bServer) {
            $script:joinedServer = $bServer; if ($bLobby) { $script:followLobby = $bLobby }
            $status.Text = "Estás en el server de $name. Si se cambia de server o arma otro lobby, te llevo."
        } elseif ($bServer -eq $script:joinedServer -and (Test-ConnectFailed $bServer $myServer)) {
            # Te mandé a su server pero no entraste (casi siempre: estaba lleno). Se mira el server cada 1 s
            # (L4dSlotWatch) y apenas se libera un lugar se conecta en el momento.
            $info = $script:whereInfo[$bServer]
            $full = $info -and [int]$info.Players -ge [int]$info.MaxPlayers
            if ($full -or -not $info) {
                $script:waitingSlot = $true; $script:slotTarget = $bServer
                $status.Text = "El server de $name está lleno: te meto apenas se libere un lugar. ($($script:followKeyName) pausa)"
            } elseif (((Get-Date) - $script:connectAt).TotalSeconds -ge 30) {
                Write-AppLog "Se liberó un lugar en $bServer ($($info.Players)/$($info.MaxPlayers)): reintento."
                $script:joinedServer = ''
                $action = "connect|$bServer"
            }
        } elseif ($bServer -eq $script:joinedServer) {
            $status.Text = "Ya te llevé al server de $name ($bServer). Te llevo de nuevo cuando se mueva."
        } elseif (($bLobby -and ($myLobby -eq $bLobby -or $script:followLobby -eq $bLobby)) -or (-not $bLobby -and $script:followLobby -and $prevLobby -eq $script:followLobby)) {
            $script:joinedServer = $bServer
            Write-AppLog "Su lobby arrancó en ${bServer}: entrás con el lobby, no mando nada."
            $status.Text = "La partida del lobby de $name arrancó: entrás con el lobby."
        } else { $action = "connect|$bServer" }
    } elseif ($bLobby) {
        if ($myLobby -eq $bLobby -or $script:followLobby -eq $bLobby) { $status.Text = "Estás en el lobby de $name." }
        else { $action = "lobby|$bLobby" }
    } else {
        $script:followLobby = ''   # volvió al menú sin lobby: lo próximo es nuevo
        $status.Text = "$name está en el menú del juego. Cuando entre a un server o arme un lobby, te llevo."
    }
    if (-not $action) { $script:pendingAction = ''; $confirmTimer.Stop(); return }
    if ($script:pendingAction -ne $action) {
        $script:pendingAction = $action; $script:pendingSince = Get-Date
        Write-AppLog "Nuevo destino: $action (lo confirmo en 2 s)"
        $confirmTimer.Stop(); $confirmTimer.Start()
        return
    }
    if (((Get-Date) - $script:pendingSince).TotalSeconds -lt 2) { if (-not $confirmTimer.Enabled) { $confirmTimer.Start() }; return }
    $script:pendingAction = ''
    $kind, $target = $action -split '\|', 2
    if ($kind -eq 'lobby') {
        $script:followLobby = $target; $script:joinedServer = ''
        Invoke-FollowCommand "steam://joinlobby/550/$target/$fid"
        $status.Text = "$name está en un lobby. Te llevo... ($($script:followKeyName) pausa el seguimiento)"
        return
    }
    $script:joinedServer = $target
    if ($bLobby) { $script:followLobby = $bLobby }   # entrar a su server te mete en su lobby
    if ($myServer) {
        # Steam dice que estás en otro server: ir directo
        Invoke-FollowCommand "steam://connect/$target"
        $status.Text = "$name está en otro server: te llevo. ($($script:followKeyName) pausa el seguimiento)"
        return
    }
    # Steam no dice dónde estás: mirar si ya estás en ese server (tu nombre en su lista de jugadores)
    $script:checkTarget = $target
    Start-Async 'followcheck' {
        param($finder, $addr)
        $src = [IO.File]::ReadAllText($finder)
        $a = $src.IndexOf('# >>> BUSQUEDA'); $b = $src.IndexOf('# <<< BUSQUEDA')
        . ([scriptblock]::Create($src.Substring($a, $b - $a)))
        $pl = Invoke-PlayerScan @($addr) 2000
        $list = if ($pl.ContainsKey($addr)) { @($pl[$addr]) } else { @() }
        [pscustomobject]@{ Names = @($list | ForEach-Object { [string]$_.Name }) }
    } @((Join-Path $here 'finder.ps1'), $target) {
        param($res2, $err2)
        if (-not (Test-Following)) { return }
        $target = $script:checkTarget
        $who = Get-FriendName $script:groupLeader
        $chk = Get-First $res2
        if ($chk -and $script:myName -and @($chk.Names) -contains $script:myName) {
            Write-AppLog "Ya estás en $target (te vi en la lista de jugadores): no reconecto."
            $script:connectTo = ''   # no hace falta reintentar
            $status.Text = "Ya estás en el server de $who."
            return
        }
        Invoke-FollowCommand "steam://connect/$target"
        $status.Text = "$who está en un server: te llevo. ($($script:followKeyName) pausa el seguimiento)"
    }
}


# --- volver a poner el juego adelante despues de mandarle una orden ---
# Abrir un link steam:// le saca el foco al juego (en pantalla completa se minimiza). Si el juego estaba
# adelante cuando la app mando la orden, durante 15 s se lo vuelve a traer cada vez que lo pierde.
if (-not ('GameFocus' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class GameFocus {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static IntPtr Window() {
        foreach (var p in Process.GetProcessesByName("left4dead2")) { if (p.MainWindowHandle != IntPtr.Zero) return p.MainWindowHandle; }
        return IntPtr.Zero;
    }
    public static bool IsFront() { IntPtr h = Window(); return h != IntPtr.Zero && GetForegroundWindow() == h && !IsIconic(h); }
    public static bool Restore() {
        IntPtr h = Window();
        if (h == IntPtr.Zero) return false;
        if (GetForegroundWindow() == h && !IsIconic(h)) return true;
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero), me = GetCurrentThreadId();
        bool att = fg != 0 && fg != me && AttachThreadInput(me, fg, true);
        bool ok = SetForegroundWindow(h);
        BringWindowToTop(h);
        if (att) AttachThreadInput(me, fg, false);
        if (!ok) { keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); ok = SetForegroundWindow(h); }   // Alt: Windows deja cambiar el foco
        return ok;
    }
}
"@
}
$script:refocusUntil = [datetime]::MinValue
$refocusTimer = New-Object Windows.Forms.Timer
$refocusTimer.Interval = 300
$refocusTimer.add_Tick({
        if ((Get-Date) -gt $script:refocusUntil) { $refocusTimer.Stop(); return }
        try { if (-not [GameFocus]::IsFront()) { $ok = [GameFocus]::Restore(); if (-not $script:refocusLogged) { Write-AppLog "El juego perdió el foco tras la orden: lo traigo de vuelta ($ok)"; $script:refocusLogged = $true } } } catch {}
    })

# Manda una orden steam:// al juego (seguir) y, si el juego estaba adelante, lo mantiene adelante
function Invoke-FollowCommand([string]$url) {
    $front = $false
    try { $front = [GameFocus]::IsFront() } catch {}
    Write-AppLog "ORDEN: $url  (juego adelante: $front)"
    if (-not $front) { [System.Media.SystemSounds]::Asterisk.Play() }   # jugando no: ya se ve que el juego conecta
    if ($url -like 'steam://connect/*') { $script:connectTo = $url.Substring(16); $script:connectAt = Get-Date; $failCheck.Stop(); $failCheck.Start() }
    Start-Process $url
    if ($front) { $script:refocusUntil = (Get-Date).AddSeconds(15); $script:refocusLogged = $false; $refocusTimer.Start() }
}


# --- tecla para activar/pausar "Seguirlo" desde el juego (global; por defecto F5) ---
if (-not ('FollowHotKey' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class FollowHotKey : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    public event EventHandler Pressed;
    bool on;
    public FollowHotKey() { var cp = new CreateParams(); cp.Parent = new IntPtr(-3); CreateHandle(cp); }
    public bool Set(int vk) {
        if (on) { UnregisterHotKey(Handle, 1); on = false; }
        if (vk == 0) return true;
        on = RegisterHotKey(Handle, 1, 0x4000, (uint)vk);
        return on;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
"@
}
# Ventana invisible (solo mensajes) que recibe la tecla aunque el juego tenga el foco. 0x4000 = sin repeticion.
$hotKey = New-Object FollowHotKey
function Set-FollowKey([string]$keyName) {
    $vk = 0
    if ($keyName) { try { $vk = [int][Windows.Forms.Keys]$keyName } catch { $keyName = '' } }
    $ok = $hotKey.Set($vk)
    $script:followKeyName = if ($keyName) { $keyName } else { "'Pausar'" }
    $btnFollowKey.Text = if ($keyName) { $keyName } else { '—' }
    if (-not $ok) { $status.Text = "No pude usar $keyName como tecla para pausar (la usa otro programa). Tocá el botón de la tecla y elegí otra."; $btnFollowKey.Text = "$keyName ✗" }
    return $ok
}
$hotKey.add_Pressed({
        if (-not $script:groupLeader) { [Console]::Beep(300, 150); return }   # no estás en el grupo de nadie
        Set-FollowPaused (-not $script:followPaused)
        # Aviso con sonido (estás en el juego y no ves la ventana): agudo = siguiendo, grave = pausado
        if (-not $script:followPaused) { [Console]::Beep(660, 90); [Console]::Beep(990, 120) } else { [Console]::Beep(500, 90); [Console]::Beep(330, 160) }
    })
$script:capturingKey = $false
$btnFollowKey.add_Click({
        $script:capturingKey = $true
        $btnFollowKey.Text = '...'
        $status.Text = 'Apretá la tecla para pausar/reanudar el seguimiento (Esc cancela, Supr = ninguna).'
    })
$form.KeyPreview = $true
$form.add_KeyDown({
        if (-not $script:capturingKey) { return }
        $_.Handled = $true; $_.SuppressKeyPress = $true
        $k = [string]$_.KeyCode
        if ($k -in 'ShiftKey', 'ControlKey', 'Menu', 'LWin', 'RWin') { return }   # esperar una tecla de verdad
        $script:capturingKey = $false
        if ($k -eq 'Escape') { [void](Set-FollowKey ([string]$settings.FollowKey)); $status.Text = 'Sin cambios.'; return }
        $name = if ($k -in 'Delete', 'Back') { '' } else { $k }
        if (Set-FollowKey $name) {
            $settings.FollowKey = $name
            Write-AppLog "Tecla de Seguir: '$name'"
            $status.Text = if ($name) { "Listo: $name pausa/reanuda el seguimiento, también desde el juego." } else { "Sin tecla: pausá con el botón 'Pausar'." }
        }
    })
[void](Set-FollowKey ([string]$settings.FollowKey))
$btnJoinFriend.add_Click({ Show-FriendsMenu })
$btnPause.add_Click({ Set-FollowPaused (-not $script:followPaused) })
$btnLeave.add_Click({ Exit-Group })

# ---------------- refresco automatico ----------------
# Sin contar minutos: la lista se actualiza cuando tiene sentido. Al volver a la ventana (si lo que ves
# tiene más de 2 min) y apenas salís de una partida o sala (lo avisa el vigía de Steam).
$script:searchedAt = @{ servers = [datetime]::MinValue; lobbies = [datetime]::MinValue }
function Invoke-AutoRefresh([string]$why, [int]$minAgeSec = 120) {
    if (-not $chkAuto.Checked -or -not $btnSearch.Enabled -or $Screenshot) { return }
    if (((Get-Date) - $script:searchedAt[$script:view]).TotalSeconds -lt [math]::Max(20, $minAgeSec)) { return }
    Write-AppLog "Actualizo la lista ($why)"
    $btnSearch.PerformClick()
}
$form.add_Activated({ Invoke-AutoRefresh 'volviste a la ventana' })
# ---------------- actualizaciones ----------------
# Al abrir la app: si hay version nueva firmada, se instala sola y se ofrece reiniciar.
$form.Text = "Buscador de versus · L4D2  (v$AppVersion)"
$script:updatedTo = 0
function Request-Update {
    if ($Screenshot -or -not $updateBase -or $script:updatedTo) { return }
    Start-Async 'update' {
        param($base, $key, $ver, $dir, $allowed)
        Install-Update $base $key $ver $dir $allowed
    } @($updateBase, $updatePublicKey, $AppVersion, $here, [string[]]$updateFiles) {
        param($res, $err)
        if ($err) { return }   # sin internet o GitHub caido: se reintenta en el proximo chequeo
        $u = Get-First $res
        if (-not $u) { return }
        $script:updatedTo = $u.Version
        $btnRestart.Text = "Reiniciar para usar la v$($u.Version)"
        $btnRestart.Visible = $true
        [System.Media.SystemSounds]::Asterisk.Play()
        $status.Text = "Se instaló la versión $($u.Version)" + $(if ($u.Notes) { ": $($u.Notes)" } else { '.' }) + ' Reiniciá cuando quieras.'
    }
}
$btnRestart.add_Click({
        $env:L4D2_RESTART = '1'   # la nueva espera a que esta se cierre (si no, se cerraría por "ya hay una abierta")
        Start-Process -FilePath (Join-Path $here 'Buscar versus.bat') -WorkingDirectory $here
        $form.Close()
    })


# ---------------- arranque y cierre ----------------
$form.add_Shown({
        if (-not (Test-Path (Join-Path $mapDir 'c1.png'))) {
            # Primera vez: extraer las imagenes en segundo plano; las tarjetas se completan al terminar
            Start-Async 'maps' { param($dir) $g = Find-L4D2Path; if ($g) { Export-MapImages $g $dir } else { -1 } } @($mapDir) {
                param($res, $err)
                $script:imgCache = @{}
                Show-Rows
            }
        }
        if (-not (Test-Path (Join-Path $mapDir 'ui_logo.png')) -or -not (Test-Path (Join-Path $mapDir 'spinner_9.png'))) {
            # El arte de la interfaz (spinner, logo, fondo) sale del juego, una sola vez
            Start-Async 'uiart' { param($dir) $g = Find-L4D2Path; if ($g) { Export-UiArt $g $dir } else { 0 } } @($mapDir) {
                param($res, $err)
                $fr = @(Get-SpinnerFrames)
                if ($fr.Count) { $script:spinFrames = $fr; $script:spinIdx = 0 }
                Update-HeaderArt
                Update-AppIcon
            }
        }
        Update-FriendList
        Update-Group
        # Addons instalados: que mapas trae cada uno (para la imagen de los mapas custom)
        Start-Async 'addons' { param($known) $g = Find-L4D2Path; if ($g) { Get-InstalledAddonMaps $g $known } } @(, $script:customIx.Addons) {
            param($res, $err)
            $a = Get-First $res
            if ($a -is [hashtable]) { Update-AddonMaps $a; $script:imgCache = @{}; Show-Rows }
        }
        Send-Beat   # que tus amigos vean que tenés la app abierta (y en qué grupo estás)
        Update-FollowButtons
        Start-GroupStream
        Start-FriendsWatcher
        Request-Update
        Set-View $script:view   # busca enseguida (ni salas ni servers necesitan API key)
        if ($btnSearch.Enabled -and $null -eq $script:results[$script:view]) {
            if ($script:groupLeader) { $status.Text = "Estás en el grupo de $(Get-FriendName $script:groupLeader)." }
            else { $status.Text = "Para jugar con un amigo: 'Unirse a un amigo'." }
        }
    })
$form.add_FormClosing({
        try { [void]$hotKey.Set(0) } catch {}
        $refocusTimer.Stop(); $gameTimer.Stop(); $confirmTimer.Stop(); $reconnectTimer.Stop(); $expireTimer.Stop(); $failCheck.Stop()
        if ($script:slotWatch) { $script:slotWatch.Stop() }
        if ($script:groupStream) { $script:groupStream.Stop() }
        if ($script:friendsWatcher) { $script:friendsWatcher.EnableRaisingEvents = $false }
        if ($script:watch) { try { $script:watch.Proc.Kill() } catch {} }
        Write-AppLog '=== App cerrada'
        $pumpTimer.Stop(); $beatTimer.Stop(); $whereTimer.Stop()
        # Avisar que cerraste la app: salís del grupo para los demás (si no llega, vence a los 10 min)
        if ($script:me -and -not $Screenshot) { try { Send-FollowSignal $script:me '' -Closed } catch {} }
        $settings.Share = $chkShare.Checked
        # Al volver a abrir la app seguís en el mismo grupo
        $settings.FollowSteamId = $script:groupLeader
        $settings.SteamFollow = [bool]$script:groupLeader
        $settings.AutoRefresh = $chkAuto.Checked
        $settings.Campaigns = @(Get-SelectedCampaigns)
        $settings.IncludeFriendsOnly = $chkFriendsOnly.Checked
        $settings.IncludeMutations = $chkMutation.Checked
        $settings.PreferIdeal = $chkIdeal.Checked
        $settings.ModeFilter = @(Get-Picked $pickMode)
        $settings.HostFilter = @(Get-Picked $pickHost)
        $settings.View = $script:view
        $settings.Party = [int]$numParty.Value
        $settings.MaxPing = [int]$numPing.Value
        if (-not $Screenshot) { Save-Settings $settings }   # las capturas de prueba no tocan la config
    })

# Un error en la ventana queda anotado en eventos.log (con la línea) en vez de quedar solo en un cartel
if (-not $Screenshot) {
    [Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            $ex = $e.Exception
            $where = ''
            if ($ex -is [Management.Automation.RuntimeException] -and $ex.ErrorRecord.InvocationInfo) {
                $ii = $ex.ErrorRecord.InvocationInfo; $where = " @ línea $($ii.ScriptLineNumber): $($ii.Line.Trim())"
            }
            Write-AppLog "ERROR: $($ex.GetType().Name): $($ex.Message)$where"
            Write-AppLog "  $(($ex.StackTrace -split "`n" | Select-Object -First 6) -join ' | ')"
            $status.Text = "Ups, algo falló (quedó anotado en eventos.log): $($ex.Message)"
        })
}

# Pruebas sin tocar el grupo real: L4D2_TEST_NOGROUP=1 no avisa nada a ntfy ni guarda la configuración
if ($env:L4D2_TEST_NOGROUP) {
    function Send-Beat { }
    function Start-GroupStream { }
    function Send-FollowSignal { }
    function Save-Settings { }
}

if ($Screenshot) {
    # Modo prueba: busca, saca una captura de la ventana y se cierra.
    # Si algo falla, anotarlo al lado de la captura en vez de quedar trabado en un cartel de error.
    [Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            [IO.File]::AppendAllText("$Screenshot.error.txt", "$($e.Exception)`r`n")
            $form.Close()
        })
    $watchdog = New-Object Windows.Forms.Timer
    $watchdog.Interval = 60000
    $watchdog.add_Tick({
            $this.Stop()
            [IO.File]::AppendAllText("$Screenshot.error.txt", "Tiempo agotado. Ocupados: $(($script:busy.Keys | Where-Object { $script:busy[$_] }) -join ', ')  boton=$($btnSearch.Enabled)`r`n")
            $form.Close()
        })
    $watchdog.Start()
    $form.add_Shown({
            # Prueba del grupo sin tocar a nadie: L4D2_FAKE_PARTY=1 arma un grupo con tus 2 primeros amigos
            # (el primero de líder, vos siguiéndolo) y saca también una captura del menú de amigos
            # Prueba de "Dónde están": L4D2_FAKE_WHERE=1 arma un grupo con 2 amigos y finge que vos y el
            # líder están en un server oficial real y el otro en una sala de espera
            if ($env:L4D2_FAKE_WHERE) {
                $fakeW = New-Object Windows.Forms.Timer
                $fakeW.Interval = 2500
                $fakeW.add_Tick({
                        if (-not $script:friendByHash.Count) { return }
                        $this.Stop()
                        $fr = @($script:friendByHash.Values | Where-Object { [string]$_.SteamId -ne $script:me } | Sort-Object Name | Select-Object -First 2)
                        $script:groupLeader = [string]$fr[0].SteamId
                        $script:partyMap = @{ $fr[0].Hash = ''; $fr[1].Hash = $fr[0].Hash }
                        $script:groupKey = $null; Update-Group; Update-FollowButtons
                        $srv = if ($env:L4D2_FAKE_WHERE -match ':') { $env:L4D2_FAKE_WHERE } else { '155.133.244.69:27015' }
                        $script:steamNow = ('{"me":{"server":"' + $srv + '","lobby":"111","playing":true},"friends":[' +
                            '{"id":"' + $fr[0].SteamId + '","name":"x","server":"' + $srv + '","lobby":"111"},' +
                            '{"id":"' + $fr[1].SteamId + '","name":"y","server":"","lobby":"222"}],' +
                            '"lobbies":{"111":{"campaign":"L4D2C1","chapter":"2","state":"game","players":"7","slots":"8","access":"public","server":"official","mode":"versus","title":"","ws":"0"},' +
                            '"222":{"campaign":"L4D2C5","chapter":"1","state":"lobby","players":"3","slots":"8","access":"friends","server":"listen","mode":"versus","title":"","ws":"0"}}}') | ConvertFrom-Json
                        Update-Where
                    })
                $fakeW.Start()
            }
            if ($env:L4D2_FAKE_PARTY) {
                $fake = New-Object Windows.Forms.Timer
                $fake.Interval = 2500
                $fake.add_Tick({
                        if (-not $script:friendByHash.Count) { return }
                        $this.Stop()
                        $fr = @($script:friendByHash.Values | Where-Object { [string]$_.SteamId -ne $script:me } | Sort-Object Name | Select-Object -First 3)
                        $script:groupLeader = [string]$fr[0].SteamId
                        $script:partyMap = @{ $fr[0].Hash = ''; $fr[1].Hash = $fr[0].Hash; $fr[2].Hash = '' }
                        $script:groupKey = $null; Update-Group; Update-FollowButtons
                        Show-FriendsMenu
                        $menuShot = New-Object Windows.Forms.Timer
                        $menuShot.Interval = 600
                        $menuShot.add_Tick({
                                $this.Stop()
                                $r = [Drawing.Rectangle]::Union($form.Bounds, $menuFriends.Bounds)
                                $bmp = New-Object Drawing.Bitmap($r.Width, $r.Height)
                                $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.Location, [Drawing.Point]::Empty, $r.Size); $g.Dispose()
                                $bmp.Save("$Screenshot.menu.png", [Drawing.Imaging.ImageFormat]::Png)
                                $menuFriends.Close()
                            })
                        $menuShot.Start()
                    })
                $fake.Start()
            }
            # Captura extra a mitad de la busqueda (para ver el spinner)
            $mid = New-Object Windows.Forms.Timer
            $mid.Interval = 4000
            $mid.add_Tick({
                    $this.Stop()
                    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
                    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                    $bmp.Save("$Screenshot.cargando.png", [Drawing.Imaging.ImageFormat]::Png)
                })
            $mid.Start()
            $shot = New-Object Windows.Forms.Timer
            $shot.Interval = 500
            $shot.add_Tick({
                    if (-not $btnSearch.Enabled -or $partyTimer.Enabled -or $script:busy['wsimg'] -or $script:busy['addons'] -or $script:busy['group'] -or $script:busy['avatars'] -or $script:busy['friends']) { return }   # esperar a que termine todo
                    $this.Stop()
                    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
                    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                    $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
                    $form.Close()
                })
            $shot.Start()
        })
}
[void]$form.ShowDialog()
# Cerrar el proceso del todo (que no quede nada esperando de fondo)
try { $pool.Close() } catch {}
[Environment]::Exit(0)

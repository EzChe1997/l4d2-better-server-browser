# ui.ps1 - ventana del buscador (la carga finder.ps1; usa sus funciones y variables)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
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

# ---------------- trabajo en segundo plano ----------------
# Todo lo que espera a internet o lee archivos grandes corre en otro hilo, asi la ventana
# nunca queda "No responde". Cuando termina, el resultado se procesa en la ventana.
$iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in 'Get-Topic', 'Get-SidHash', 'Send-SteamBroadcast', 'Receive-SteamBroadcasts', 'Get-SteamStatus',
    'Get-LocalFriends', 'Get-ApiKey', 'Find-L4D2Path', 'Read-VpkIndex', 'Read-VpkFile', 'Export-MapImages', 'Get-LobbyJson',
    'Receive-NtfyMessages', 'Send-FollowSignal', 'Get-GroupHashes', 'Get-SteamAvatars', 'Get-WorkshopImages', 'Get-InstalledAddonMaps',
    'Install-Update') {
    $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($fn, (Get-Item "function:$fn").Definition)))
}
foreach ($v in 'presenceTopic', 'followTopic', 'keyFile') {
    $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry($v, (Get-Variable $v -ValueOnly), '')))
}
$pool = [RunspaceFactory]::CreateRunspacePool(1, 4, $iss, $Host)
$pool.Open()
$script:jobs = New-Object System.Collections.ArrayList
$script:busy = @{}

# Corre $work en segundo plano (uno a la vez por nombre) y despues llama $done con (resultado, error)
function Start-Async([string]$name, [scriptblock]$work, [object[]]$argv, [scriptblock]$done) {
    if ($script:busy[$name]) { return }
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($work.ToString())
    foreach ($a in $argv) { [void]$ps.AddArgument($a) }
    $script:busy[$name] = $true
    [void]$script:jobs.Add(@{ Name = $name; PS = $ps; H = $ps.BeginInvoke(); Done = $done })
}

function Get-First($res) {
    if ($null -eq $res -or $res.Count -eq 0) { return $null }
    $x = $res[0]
    if ($x -is [Management.Automation.PSObject] -and $x.BaseObject -is [hashtable]) { $x = $x.BaseObject }
    return $x
}

$pumpTimer = New-Object Windows.Forms.Timer
$pumpTimer.Interval = 150
$pumpTimer.add_Tick({
        for ($i = $script:jobs.Count - 1; $i -ge 0; $i--) {
            $j = $script:jobs[$i]
            if (-not $j.H.IsCompleted) { continue }
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
            try { & $j.Done $res $err } catch { if ($Screenshot) { [IO.File]::AppendAllText("$Screenshot.error.txt", "[$($j.Name)] $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())`r`n") } }
        }
    })
$pumpTimer.Start()

# La busqueda de servers corre en la ventana, pero atiende a Windows mientras espera respuestas
$Pump = { [Windows.Forms.Application]::DoEvents() }

# ---------------- estilo ----------------
function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$C = @{
    Bg = RGB 22 23 27; Panel = RGB 31 33 39; Card = RGB 38 40 47; CardHi = RGB 52 55 64
    Text = RGB 236 236 240; Dim = RGB 150 152 162; Input = RGB 18 19 23
    Accent = RGB 190 32 38; AccentHi = RGB 220 52 58
    Green = RGB 76 196 116; Amber = RGB 232 172 64; Gray = RGB 112 115 126; Orange = RGB 236 110 60
    Blue = RGB 110 160 240
}
$F = @{
    Title = New-Object Drawing.Font('Segoe UI Semibold', 16)
    Sub   = New-Object Drawing.Font('Segoe UI', 9)
    H     = New-Object Drawing.Font('Segoe UI Semibold', 12.5)
    Body  = New-Object Drawing.Font('Segoe UI', 9.5)
    Small = New-Object Drawing.Font('Segoe UI', 8.75)
    Chip  = New-Object Drawing.Font('Segoe UI Semibold', 8.25)
    Ping  = New-Object Drawing.Font('Segoe UI Semibold', 13)
    Btn   = New-Object Drawing.Font('Segoe UI Semibold', 10)
}

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
$header.Dock = 'Top'; $header.Height = 66; $header.BackColor = $C.Panel
$header.Width = $form.ClientSize.Width   # ancho real antes de anclar cosas a la derecha
$title = New-Text 'BUSCADOR DE VERSUS' $F.Title $C.Text
$title.Location = New-Object Drawing.Point(16, 10)
$subtitle = New-Text 'Left 4 Dead 2  ·  servers con lugar para tu grupo' $F.Sub $C.Dim
$subtitle.Location = New-Object Drawing.Point(19, 40)
$btnSearch = New-FlatButton 'Buscar' $C.Accent $C.AccentHi 140 38
$btnSearch.Anchor = 'Top, Right'
$btnSearch.Location = New-Object Drawing.Point(($form.ClientSize.Width - 156), 14)
$chkAuto = New-Object Windows.Forms.CheckBox
$chkAuto.Text = 'Actualizar cada 1 min'; $chkAuto.AutoSize = $true; $chkAuto.ForeColor = $C.Dim
$chkAuto.BackColor = $C.Panel; $chkAuto.Checked = [bool]$settings.AutoRefresh
$chkAuto.Anchor = 'Top, Right'
$chkAuto.Location = New-Object Drawing.Point(($form.ClientSize.Width - 330), 24)
# Que buscar: partidas en curso (servers) o salas de espera (lobbies de Steam)
$btnViewServers = New-FlatButton 'Partidas en curso' $C.Input $C.CardHi 150 32
$btnViewLobbies = New-FlatButton 'Salas de espera' $C.Input $C.CardHi 140 32
$btnViewServers.Location = New-Object Drawing.Point(360, 17)
$btnViewLobbies.Location = New-Object Drawing.Point(510, 17)
$btnViewServers.Tag = 'servers'; $btnViewLobbies.Tag = 'lobbies'
$tips = New-Object Windows.Forms.ToolTip
$tips.SetToolTip($btnViewServers, 'Servers con una partida ya empezada y lugar libre (necesita API key)')
$tips.SetToolTip($btnViewLobbies, 'Salas que todavía no arrancaron, como las del buscador del juego (no necesita API key)')
$header.Controls.AddRange(@($title, $subtitle, $btnViewServers, $btnViewLobbies, $chkAuto, $btnSearch))

# Filtros
$filters = New-Row 42
$numParty = New-Object Windows.Forms.NumericUpDown
$numParty.Minimum = 1; $numParty.Maximum = 4; $numParty.Width = 48
$numParty.Value = [math]::Min(4, [math]::Max(1, [int]$settings.Party)); Set-Dark $numParty
$numPing = New-Object Windows.Forms.NumericUpDown
$numPing.Minimum = 20; $numPing.Maximum = 400; $numPing.Increment = 10; $numPing.Width = 64
$numPing.Value = [math]::Min(400, [math]::Max(20, [int]$settings.MaxPing)); Set-Dark $numPing
$chkBig = New-Object Windows.Forms.CheckBox
$chkBig.Text = 'Incluir servers de más de 8'; $chkBig.AutoSize = $true; $chkBig.ForeColor = $C.Text
$chkBig.Checked = $IncludeBig.IsPresent; $chkBig.Margin = New-Object Windows.Forms.Padding(24, 5, 0, 0)
$chkValve = New-Object Windows.Forms.CheckBox
$chkValve.Text = 'Ocultar oficiales de Valve'; $chkValve.AutoSize = $true; $chkValve.ForeColor = $C.Text
$chkValve.Checked = $HideValve.IsPresent; $chkValve.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
$lblPing = New-FieldLabel 'Ping máximo'
$lblPing.Margin = New-Object Windows.Forms.Padding(24, 6, 6, 0)
$filters.Controls.AddRange(@((New-FieldLabel 'Somos'), $numParty, $lblPing, $numPing, (New-FieldLabel 'ms'), $chkBig, $chkValve))

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

$cmbType = New-Object Windows.Forms.ComboBox
$cmbType.DropDownStyle = 'DropDownList'; $cmbType.Width = 220; $cmbType.FlatStyle = 'Flat'
$cmbType.BackColor = $C.Input; $cmbType.ForeColor = $C.Text; $cmbType.Font = $F.Body
$cmbType.Width = 250
# Las opciones dependen de la vista (las carga Set-View)
$typeOptions = @{
    servers = @('Todos', 'Solo ZoneMod', 'Solo competitivos', 'Sin competitivo (vanilla)')
    lobbies = @('Todas', 'Sin host local (oficial o dedicado)', 'Solo oficiales de Valve', 'Solo servers dedicados', 'Solo hosteadas por un jugador')
}
$script:typeSel = @{ servers = [string]$settings.ServerType; lobbies = [string]$settings.LobbyType }
$script:fillingType = $false

$lblType = New-FieldLabel 'Tipo de server'
$lblType.Margin = New-Object Windows.Forms.Padding(24, 6, 6, 0)
$modeBar.Controls.AddRange(@((New-FieldLabel 'Campañas'), $btnCamp, $lblType, $cmbType))

# Seguir a un amigo de Steam
$steamBar = New-Row 46
$steamBar.Padding = New-Object Windows.Forms.Padding(16, 4, 16, 8)
$cmbFriend = New-Object Windows.Forms.ComboBox
$cmbFriend.DropDownStyle = 'DropDownList'; $cmbFriend.Width = 300; $cmbFriend.FlatStyle = 'Flat'
$cmbFriend.BackColor = $C.Input; $cmbFriend.ForeColor = $C.Text; $cmbFriend.Font = $F.Body
$cmbFriend.MaxDropDownItems = 20
$btnFriends = New-FlatButton '↻' $C.CardHi (RGB 66 70 80) 32 26
$btnFriends.Margin = New-Object Windows.Forms.Padding(4, 0, 0, 0)
(New-Object Windows.Forms.ToolTip).SetToolTip($btnFriends, 'Actualizar la lista de amigos')
$chkSteamFollow = New-Object Windows.Forms.CheckBox
$chkSteamFollow.Text = 'Seguirlo (entro solo a su server o lobby)'; $chkSteamFollow.AutoSize = $true
$chkSteamFollow.ForeColor = $C.Text; $chkSteamFollow.Checked = [bool]$settings.SteamFollow
$chkSteamFollow.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
$chkShare = New-Object Windows.Forms.CheckBox
$chkShare.Text = 'Compartir mi partida con mis amigos'; $chkShare.AutoSize = $true
$chkShare.ForeColor = $C.Text; $chkShare.Checked = [bool]$settings.Share
$chkShare.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
$chkShare.Visible = (Test-Path $keyFile)
$btnKey = New-FlatButton 'API key (solo para buscar)' $C.CardHi (RGB 66 70 80) 190 26
$btnKey.Font = $F.Body; $btnKey.Margin = New-Object Windows.Forms.Padding(16, 0, 0, 0)
$btnKey.Visible = -not (Test-Path $keyFile)
$steamBar.Controls.AddRange(@((New-FieldLabel 'Seguir a un amigo de Steam'), $cmbFriend, $btnFriends, $chkSteamFollow, $chkShare, $btnKey))

# Tu grupo: vos + los que te siguen (o, si seguís a alguien, el grupo de esa persona)
$groupBar = New-Row 48
$groupBar.Padding = New-Object Windows.Forms.Padding(16, 6, 16, 6)
$groupBar.BackColor = $C.Bg
$groupMembers = New-Object Windows.Forms.FlowLayoutPanel
$groupMembers.AutoSize = $true; $groupMembers.WrapContents = $false; $groupMembers.BackColor = $C.Bg
$groupMembers.Margin = New-Object Windows.Forms.Padding(0)
$groupHint = New-Text '' $F.Small $C.Dim
$groupHint.Margin = New-Object Windows.Forms.Padding(10, 10, 0, 0)
$btnLeave = New-FlatButton 'Salir del grupo' $C.CardHi (RGB 66 70 80) 120 26
$btnLeave.Font = $F.Small; $btnLeave.Margin = New-Object Windows.Forms.Padding(12, 4, 0, 0); $btnLeave.Visible = $false
$lblGroup = New-FieldLabel 'Tu grupo'
$lblGroup.Margin = New-Object Windows.Forms.Padding(0, 9, 10, 0)
$groupBar.Controls.AddRange(@($lblGroup, $groupMembers, $groupHint, $btnLeave))

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
$form.Controls.Add($groupBar)
$form.Controls.Add($steamBar)
$form.Controls.Add($modeBar)
$form.Controls.Add($filters)
$form.Controls.Add($header)

# ---------------- tarjetas ----------------
function Get-CardWidth { return [math]::Max(600, $list.ClientSize.Width - $list.Padding.Horizontal - 4) }

function Get-PingColor([int]$ms) {
    if ($ms -le 60) { return $C.Green }
    if ($ms -le 100) { return $C.Amber }
    return $C.Orange
}

function New-Card($r) {
    $W = Get-CardWidth; $H = 120
    $statusColor = switch ($r.Estado) { 'Seguro' { $C.Green } 'Probable' { $C.Amber } default { $C.Gray } }

    $card = New-Object Windows.Forms.Panel
    $card.Size = New-Object Drawing.Size($W, $H); $card.BackColor = $C.Card
    $card.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10)

    $strip = New-Object Windows.Forms.Panel
    $strip.BackColor = $statusColor; $strip.Location = New-Object Drawing.Point(0, 0); $strip.Size = New-Object Drawing.Size(4, $H)

    $pic = New-Object Windows.Forms.PictureBox
    $pic.Location = New-Object Drawing.Point(4, 0); $pic.Size = New-Object Drawing.Size(240, $H)
    $pic.SizeMode = 'Zoom'; $pic.BackColor = [Drawing.Color]::Black
    $img = $null
    if ($r.Campaign -eq 'custom') {
        $id = if ($r.WorkshopId) { $r.WorkshopId } else { Get-CustomWorkshopId $script:customIx $r.Mapa }
        if ($id) { $img = Get-MapImage "ws_$id" }
        if (-not $img) { $img = Get-MapImage $r.Mapa }
        if (-not $img) { $img = Get-MapImage 'addon' }   # imagen generica de "addon" del juego, mejor que negro
    } else { $img = Get-MapImage $r.Mapa }
    if ($img) { $pic.Image = $img }
    else {
        $noimg = New-Text $r.Mapa $F.Small $C.Dim
        $noimg.AutoSize = $false; $noimg.Dock = 'Fill'; $noimg.TextAlign = 'MiddleCenter'
        $pic.Controls.Add($noimg)
    }

    $x = 262; $rightW = 190
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
    $t = New-Text $titleText $F.H $C.Text
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
    $chips.Controls.Add((New-Chip "$($r.Humans)/$($r.Max) jugadores" $C.CardHi $C.Text))
    if ($r.Config) { $chips.Controls.Add((New-Chip $r.Config.ToUpper() $C.Blue $C.Bg)) }
    elseif ($r.Competitive) { $chips.Controls.Add((New-Chip 'COMPETITIVO' $C.Blue $C.Bg)) }
    if ($r.Premade) { $chips.Controls.Add((New-Chip "GRUPO ARMADO ($($r.Premade))" $C.CardHi $C.Orange)) }
    if ($isLobby) { $chips.Controls.Add((New-Chip 'SALA DE ESPERA' $C.Blue $C.Bg)) }
    if ($isLobby -and $r.Server -eq 'listen') { $chips.Controls.Add((New-Chip 'HOST LOCAL' $C.CardHi $C.Amber)) }
    if ($r.Custom -or (-not $isLobby -and $r.Campaign -eq 'custom')) { $chips.Controls.Add((New-Chip 'MAPA CUSTOM' $C.CardHi $C.Amber)) }
    if ($r.Valve -and -not $isLobby) { $chips.Controls.Add((New-Chip 'OFICIAL VALVE' $C.CardHi $C.Dim)) }
    if ($r.Max -gt 8) { $chips.Controls.Add((New-Chip "GRANDE ($($r.Max))" $C.CardHi $C.Amber)) }

    $hint = New-Text $r.Hint $F.Small $C.Dim
    $hint.AutoSize = $false; $hint.AutoEllipsis = $true
    $hint.Location = New-Object Drawing.Point($x, 94); $hint.Size = New-Object Drawing.Size(($W - $x - $rightW - 10), 18)
    $hint.Anchor = 'Top, Left, Right'

    # Los lobbies no tienen ping: Steam solo dice si estan en tu region o lejos
    $ping = if (-not $isLobby) { New-Text "$($r.Ping) ms" $F.Ping (Get-PingColor $r.Ping) }
    elseif ($r.Near) { New-Text 'Tu región' $F.Btn $C.Green }
    else { New-Text 'Otra región' $F.Btn $C.Orange }
    $ping.AutoSize = $false; $ping.TextAlign = 'MiddleRight'
    $ping.Size = New-Object Drawing.Size(160, 26); $ping.Location = New-Object Drawing.Point(($W - 176), 8)
    $ping.Anchor = 'Top, Right'

    $join = New-FlatButton 'Unirme' $C.Accent $C.AccentHi 160 34
    $join.Location = New-Object Drawing.Point(($W - 176), 40); $join.Anchor = 'Top, Right'; $join.Tag = $link
    $join.add_Click({ Invoke-Join $this.Tag })

    $copy = New-FlatButton 'Copiar link' $C.CardHi (RGB 66 70 80) 160 28
    $copy.Font = $F.Body
    $copy.Location = New-Object Drawing.Point(($W - 176), 80); $copy.Anchor = 'Top, Right'; $copy.Tag = $link
    $copy.add_Click({ Copy-Link $this.Tag })

    $card.Controls.AddRange(@($strip, $pic, $t, $name, $chips, $hint, $ping, $join, $copy))
    return $card
}

function Show-Message([string]$text) {
    $l = New-Text $text $F.Body $C.Dim
    $l.Margin = New-Object Windows.Forms.Padding(4, 20, 0, 0)
    $list.Controls.Add($l)
}

function Clear-List {
    $old = @($list.Controls)
    $list.Controls.Clear()
    foreach ($ctl in $old) { $ctl.Dispose() }
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

function Test-ServerType($r, [string]$type) {
    switch ($type) {
        'Solo ZoneMod' { return [bool]$r.ZoneMod }
        'Solo competitivos' { return [bool]$r.Competitive }
        'Sin competitivo (vanilla)' { return -not $r.Competitive }
        # salas de espera (Options:server del lobby)
        'Sin host local (oficial o dedicado)' { return $r.Server -in 'official', 'dedicated' }
        'Solo oficiales de Valve' { return $r.Server -eq 'official' }
        'Solo servers dedicados' { return $r.Server -eq 'dedicated' }
        'Solo hosteadas por un jugador' { return $r.Server -eq 'listen' }
        default { return $true }
    }
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
    $all = $script:results[$script:view]
    if ($null -eq $all) { return }
    $lobbies = $script:view -eq 'lobbies'
    $sel = @(Get-SelectedCampaigns)
    $type = [string]$cmbType.SelectedItem
    $rows = @($all | Where-Object { ($sel.Count -eq 0 -or $sel -contains $_.Campaign) -and (Test-ServerType $_ $type) })
    Clear-List
    $list.SuspendLayout()
    foreach ($r in $rows) { $list.Controls.Add((New-Card $r)) }
    $list.ResumeLayout()
    Request-WorkshopImages
    if ($all.Count -eq 0) {
        Show-Message $(if ($lobbies) { 'No hay salas de espera de versus con lugar para ustedes ahora. Probá de nuevo en un rato.' }
            else { 'No hay servers con lugar. Probá subir el ping máximo o buscar de nuevo en un rato.' })
    } elseif ($rows.Count -eq 0) {
        $wantsRare = ($sel -contains 'custom') -or ($type -in 'Solo ZoneMod', 'Solo competitivos')
        if (-not $lobbies -and $wantsRare -and $numPing.Value -lt 200) {
            Show-Message 'Nada con estos filtros. Casi todos los servers ZoneMod y de mapas custom están en EE.UU. (150-190 ms): subí el ping máximo a 200 y tocá Buscar.'
        } else { Show-Message 'Nada coincide con estos filtros ahora. Probá con otra campaña o tipo de server.' }
    }
    $seguros = @($rows | Where-Object { $_.Rank -eq 0 }).Count
    $what = if ($lobbies) { 'salas de espera' } else { 'servers' }
    $status.Text = "Mostrando $($rows.Count) de $($all.Count) $what ($seguros seguros).  Última búsqueda: $($script:times[$script:view])"
}

function Set-View([string]$v) {
    $script:view = $v
    foreach ($b in $btnViewServers, $btnViewLobbies) {
        $on = $b.Tag -eq $v
        $b.BackColor = if ($on) { $C.CardHi } else { $C.Input }
        $b.ForeColor = if ($on) { $C.Text } else { $C.Dim }
        $b.FlatAppearance.BorderSize = if ($on) { 1 } else { 0 }
        $b.FlatAppearance.BorderColor = $C.Accent
    }
    # El ping y los servers grandes no aplican a las salas de espera
    $numPing.Enabled = $v -eq 'servers'; $chkBig.Enabled = $v -eq 'servers'
    $subtitle.Text = if ($v -eq 'lobbies') { 'Left 4 Dead 2  ·  salas de espera con lugar para tu grupo' } else { 'Left 4 Dead 2  ·  servers con lugar para tu grupo' }
    # Cada vista tiene sus propias opciones de "Tipo de server" y recuerda la elegida
    $script:fillingType = $true
    $cmbType.BeginUpdate()
    $cmbType.Items.Clear()
    [void]$cmbType.Items.AddRange([object[]]$typeOptions[$v])
    $cmbType.SelectedItem = if ($typeOptions[$v] -contains $script:typeSel[$v]) { $script:typeSel[$v] } else { $typeOptions[$v][0] }
    $cmbType.EndUpdate()
    $script:fillingType = $false
    Clear-List
    if ($null -ne $script:results[$v]) { Show-Rows }
    elseif ($btnSearch.Enabled -and ($v -eq 'lobbies' -or (Test-Path $keyFile))) { $btnSearch.PerformClick() }
    elseif ($v -eq 'servers' -and -not (Test-Path $keyFile)) { Show-Message 'Para buscar partidas en curso hace falta la API key de Steam (botón "API key"). Las salas de espera no la necesitan.' }
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
            $script:results.lobbies = @(ConvertTo-LobbyRows $script:lobbyJson $p ([bool]$chkValve.Checked))
        } else { $script:results.lobbies = $null }
        $script:results.servers = $null   # el veredicto de los servers depende del tamaño: rehacer
        if ($null -ne $script:results[$script:view]) { Show-Rows }
        elseif ($btnSearch.Enabled -and ($script:view -eq 'lobbies' -or (Test-Path $keyFile))) { $btnSearch.PerformClick() }
    })
$numParty.add_ValueChanged({ $partyTimer.Stop(); $partyTimer.Start() })
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
$cmbType.add_SelectedIndexChanged({
        if ($script:fillingType) { return }
        $script:typeSel[$script:view] = [string]$cmbType.SelectedItem
        Show-Rows
    })
Update-CampButton

$list.add_Resize({
        $w = Get-CardWidth
        $list.SuspendLayout()
        foreach ($ctl in $list.Controls) { if ($ctl -is [Windows.Forms.Panel]) { $ctl.Width = $w } }
        $list.ResumeLayout()
    })

# ---------------- acciones ----------------
function Invoke-Join([string]$link) {
    Start-Process $link
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
    $form.Cursor = 'Default'
    $btnSearch.Enabled = $true; $btnSearch.Text = 'Buscar'
}

$btnSearch.add_Click({
        $btnSearch.Enabled = $false; $btnSearch.Text = 'Buscando...'
        $form.Cursor = 'WaitCursor'
        Clear-List
        if ($script:view -eq 'lobbies') {
            # Las salas se piden a Steam en un proceso aparte (en segundo plano: la ventana no se traba)
            $status.Text = 'Pidiéndole a Steam las salas de espera de versus...'
            $script:lobbyArgs = @{ Party = [int]$numParty.Value; HideValve = [bool]$chkValve.Checked }   # el $done corre en otro alcance
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
        if (-not (Test-Path $keyFile)) {
            Stop-Searching
            Show-Message 'Para buscar partidas en curso hace falta la API key de Steam (botón "API key"). Las salas de espera no la necesitan.'
            return
        }
        try {
            $rows = Find-Servers ([int]$numParty.Value) ([int]$numPing.Value) $chkBig.Checked $chkValve.Checked {
                param($m) $status.Text = $m; [Windows.Forms.Application]::DoEvents()
            }
            $script:results.servers = @($rows)
            $script:times.servers = Get-Date -Format 'HH:mm'
            if ($script:view -eq 'servers') { Show-Rows }
        } catch {
            $status.Text = "Error: $($_.Exception.Message)"
        } finally { Stop-Searching }
    })

# ---------------- seguir a un amigo de Steam ----------------
# El que juega (con API key) transmite en que server/lobby esta; los que siguen solo escuchan (sin key).
$script:me = Get-MySteamId
$script:friendIds = @()
$script:friendNames = @()
$script:followLobby = ''
$script:joinedServer = ''   # ultimo server al que te llevó (no se borra al destildar)
$script:lobbyJoinedAt = [datetime]::MinValue
$script:shareState = ''
$script:shareSentAt = [datetime]::MinValue
$script:friendsQuiet = $false

# ---------------- grupo ----------------
# Lider = la persona que seguís (si tildaste "Seguirlo"); si no seguís a nadie, el lider sos vos.
# Seguís en el grupo aunque "Seguirlo" se destilde solo al entrar a su partida; salís destildándolo
# vos, con "Salir del grupo" o cerrando la app.
$script:groupLeader = if ($settings.SteamFollow -and $settings.FollowSteamId) { [string]$settings.FollowSteamId } else { '' }
$script:autoUncheck = $false
$script:friendByHash = @{}
$script:lastGroupHashes = @()
$script:groupKey = $null
$script:groupCount = 0
$script:groupData = @()
$script:avatars = @{}
$script:avatarTried = @{}

function Get-GroupLeader { if ($script:groupLeader) { return $script:groupLeader } return $script:me }

function Get-FriendName([string]$sid) {
    if (-not $sid) { return '?' }
    $fr = $script:friendByHash[(Get-SidHash $sid)]
    if ($fr) { return $fr.Name }
    $i = [Array]::IndexOf($script:friendIds, $sid)
    if ($i -ge 0) { return $script:friendNames[$i] }
    return 'Amigo'
}

function Send-Beat {
    if (-not $script:me) { return }
    Start-Async 'beat' { param($me, $leader) Send-FollowSignal $me $leader } @($script:me, $script:groupLeader) { param($res, $err) }
}

function Set-GroupLeader([string]$sid) {
    if ($sid -eq $script:me) { $sid = '' }
    $script:groupLeader = $sid
    $script:lastGroupHashes = @(); $script:groupKey = $null
    Send-Beat
    Update-Group @()
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

function Show-Group {
    $old = @($groupMembers.Controls); $groupMembers.Controls.Clear(); foreach ($ctl in $old) { $ctl.Dispose() }   # ojo: $c pisaria $C (colores)
    $missing = @()
    foreach ($m in $script:groupData) {
        $item = New-Object Windows.Forms.FlowLayoutPanel
        $item.AutoSize = $true; $item.WrapContents = $false; $item.BackColor = $C.Card
        $item.Padding = New-Object Windows.Forms.Padding(4, 3, 10, 3); $item.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
        $pic = New-Object Windows.Forms.PictureBox
        $pic.Size = New-Object Drawing.Size(28, 28); $pic.SizeMode = 'Zoom'; $pic.Margin = New-Object Windows.Forms.Padding(0)
        if ($m.Sid -and $script:avatars[$m.Sid]) { $pic.Image = $script:avatars[$m.Sid] }
        else {
            $pic.Image = New-AvatarImage $m.Name
            if ($m.Sid -and -not $script:avatarTried[$m.Sid]) { $missing += $m.Sid }
        }
        $lbl = New-Text $m.Label $F.Body $(if ($m.Leader) { $C.Amber } else { $C.Text })
        $lbl.Margin = New-Object Windows.Forms.Padding(6, 6, 0, 0)
        $item.Controls.AddRange(@($pic, $lbl))
        if ($m.Leader) { $tips.SetToolTip($lbl, 'Líder del grupo: los demás lo siguen') }
        $groupMembers.Controls.Add($item)
    }
    if ($missing.Count) {
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
}

# $hashes = huellas de los que siguen al lider (de Get-GroupHashes)
function Update-Group($hashes) {
    if (-not $script:me) { return }
    $hashes = @($hashes | Where-Object { $_ })
    $script:lastGroupHashes = $hashes
    $leader = Get-GroupLeader
    $iFollow = [bool]$script:groupLeader
    $myHash = Get-SidHash $script:me
    $members = New-Object System.Collections.ArrayList
    [void]$members.Add([pscustomobject]@{ Sid = $leader; Name = $(if ($iFollow) { Get-FriendName $leader } else { 'Vos' }); Leader = $true })
    if ($iFollow) { [void]$members.Add([pscustomobject]@{ Sid = $script:me; Name = 'Vos'; Leader = $false }) }
    $unknown = 0
    foreach ($h in $hashes) {
        if ($h -eq $myHash) { continue }
        $fr = $script:friendByHash[$h]
        if ($fr) { [void]$members.Add([pscustomobject]@{ Sid = $fr.SteamId; Name = $fr.Name; Leader = $false }) } else { $unknown++ }
    }
    if ($unknown) { [void]$members.Add([pscustomobject]@{ Sid = ''; Name = "+$unknown"; Leader = $false }) }
    foreach ($m in $members) { $m | Add-Member -Force NoteProperty Label $(if ($m.Sid -eq '') { "+$unknown (no son tus amigos)" } else { $m.Name }) }
    $n = $members.Count - [int][bool]$unknown + $unknown

    $key = (($members | ForEach-Object { "$($_.Sid):$($_.Name)" }) -join ',')
    if ($key -ne $script:groupKey) {
        $script:groupKey = $key
        $script:groupData = @($members)
        Show-Group
        $btnLeave.Visible = $iFollow
        $groupHint.Text = if ($iFollow) { "Estás en el grupo de $(Get-FriendName $leader)  ·  $n jugadores" }
        elseif ($n -le 1) { "Solo vos por ahora. Cuando tus amigos tilden 'Seguirlo' sobre vos, aparecen acá y 'Somos' se ajusta solo." }
        else { "$n jugadores  ·  'Somos' se ajusta solo" }
    }
    if ($n -ne $script:groupCount) {
        $old = $script:groupCount
        $script:groupCount = $n
        $numParty.Value = [math]::Min(4, [math]::Max(1, $n))
        if ($old -gt 0 -and $n -gt $old) { [System.Media.SystemSounds]::Asterisk.Play(); $status.Text = "Se sumó alguien al grupo: ahora son $n." }
        elseif ($old -gt 0 -and $n -lt $old) { $status.Text = "Alguien salió del grupo: ahora son $n." }
        if ($n -gt 4) { $status.Text = "El grupo tiene $n jugadores: en versus entran hasta 4 por equipo." }
    }
}

# Mirar el grupo cada 10 s (si estás siguiendo a alguien, lo hace el sondeo de "Seguirlo", en el mismo pedido)
$groupTimer = New-Object Windows.Forms.Timer
$groupTimer.Interval = 10000
function Request-Group {
    if (-not $script:me -or ($chkSteamFollow.Checked -and (Get-FollowedId))) { return }
    Start-Async 'group' { param($leader) , @(Get-GroupHashes $leader (Receive-NtfyMessages '2m')) } @(Get-GroupLeader) {
        param($res, $err)
        if ($err) { return }
        Update-Group @($res | ForEach-Object { $_ })
    }
}
$groupTimer.add_Tick({ Request-Group })
$groupTimer.Start()

# Avisar cada 30 s a quién seguís (así el lider te cuenta en su grupo)
$beatTimer = New-Object Windows.Forms.Timer
$beatTimer.Interval = 30000
$beatTimer.add_Tick({ if ($script:groupLeader) { Send-Beat } })
$beatTimer.Start()

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-FollowedId {
    if ($cmbFriend.SelectedIndex -ge 0) { return $script:friendIds[$cmbFriend.SelectedIndex] }
    return $null
}

function Update-FriendList([switch]$Quiet) {
    if ($cmbFriend.DroppedDown) { return }   # no cambiar la lista mientras la estás mirando
    if (-not $script:me) { $script:me = Get-MySteamId }
    if (-not $script:me) { if (-not $Quiet) { $status.Text = 'No encuentro tu cuenta de Steam: abrí Steam y tocá ↻.' }; return }
    if (-not $Quiet) { $status.Text = 'Buscando amigos que estén jugando...' }
    $script:friendsQuiet = [bool]$Quiet
    $prev = Get-FollowedId
    if (-not $prev) { $prev = [string]$settings.FollowSteamId }

    Start-Async 'friends' {
        param($me, $prev)
        $everyone = @(Get-LocalFriends $me)   # incluye tu propia cuenta
        $friends = @($everyone | Where-Object { $_.SteamId -ne $me })
        $live = @{}; $netErr = ''
        if ($friends.Count) {
            try { $live = Receive-SteamBroadcasts @($friends | ForEach-Object { $_.SteamId }) '3m' } catch { $netErr = $_.Exception.Message }
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $rows = foreach ($f in $friends) {
            $b = $live[$f.SteamId]
            $active = [bool]($b -and $b.Playing -and ($now - $b.Time) -le 150)
            if ($active -or $f.SteamId -eq $prev) {
                $label = $f.Name
                if (-not $active) { $label += '   (no está compartiendo ahora)' }
                elseif ($b.Server) { $label += '   ● en un server' }
                elseif ($b.Lobby) { $label += '   ● en un lobby' }
                else { $label += '   ● en el menú' }
                [pscustomobject]@{ SteamId = $f.SteamId; Name = $f.Name; Label = $label; Active = $active }
            }
        }
        [pscustomobject]@{
            Rows = @($rows | Sort-Object @{ Expression = 'Active'; Descending = $true }, Name)
            Prev = $prev; NetErr = $netErr
            All = @($everyone | ForEach-Object { [pscustomobject]@{ SteamId = $_.SteamId; Name = $_.Name; Hash = (Get-SidHash $_.SteamId) } })
        }
    } @($script:me, $prev) {
        param($res, $err)
        $r = Get-First $res
        if ($err -or -not $r) {
            if (-not $script:friendsQuiet) { $status.Text = "No pude cargar la lista de amigos: $err" }
            return
        }
        $byHash = @{}
        foreach ($fr in @($r.All)) { $byHash[$fr.Hash] = $fr }   # ojo: $f pisaria $F (fuentes)
        $script:friendByHash = $byHash
        $script:groupKey = ''; Update-Group $script:lastGroupHashes   # ahora con nombres
        if ($cmbFriend.DroppedDown) { return }
        $cmbFriend.BeginUpdate()
        try {
            $cmbFriend.Items.Clear(); $script:friendIds = @(); $script:friendNames = @()
            foreach ($row in @($r.Rows)) {
                [void]$cmbFriend.Items.Add($row.Label); $script:friendIds += $row.SteamId; $script:friendNames += $row.Name
            }
            $idx = [Array]::IndexOf($script:friendIds, [string]$r.Prev)
            if ($idx -ge 0) { $cmbFriend.SelectedIndex = $idx }
        } finally { $cmbFriend.EndUpdate() }
        if (-not $script:friendsQuiet) {
            $n = @($r.Rows | Where-Object { $_.Active }).Count
            $status.Text = if ($r.NetErr) { "No pude ver quién está jugando (ntfy.sh: $($r.NetErr)). Reintento en un rato." }
            elseif ($n) { "$n amigo(s) jugando y compartiendo su partida." }
            else { 'Ningún amigo está compartiendo su partida ahora (tiene que estar jugando con esta app abierta). La lista se actualiza sola.' }
        }
    }
}

# La lista se refresca sola cada 2 minutos, asi aparecen los que van entrando al juego
$friendsTimer = New-Object Windows.Forms.Timer
$friendsTimer.Interval = 120000
$friendsTimer.add_Tick({ Update-FriendList -Quiet })
$friendsTimer.Start()

# --- seguir: escuchar la transmision del amigo elegido cada 6 segundos ---
$steamTimer = New-Object Windows.Forms.Timer
$steamTimer.Interval = 6000
$steamTimer.add_Tick({
        if (-not $chkSteamFollow.Checked) { return }
        $fid = Get-FollowedId
        if (-not $fid) { return }
        Start-Async 'follow' {
            param($fid, $leader)
            $msgs = Receive-NtfyMessages '3m'   # un solo pedido para su partida y el grupo
            [pscustomobject]@{ B = (Receive-SteamBroadcasts @($fid) '3m' $msgs)[$fid]; Group = @(Get-GroupHashes $leader $msgs) }
        } @($fid, (Get-GroupLeader)) {
            param($res, $err)
            $fid = Get-FollowedId
            if (-not $chkSteamFollow.Checked -or -not $fid) { return }
            $name = $script:friendNames[$cmbFriend.SelectedIndex]
            if ($err) { $status.Text = "No pude conectar con ntfy.sh ($err). Reintento en unos segundos."; return }
            $r = Get-First $res
            if ($r) { Update-Group @($r.Group) }
            $b = if ($r) { $r.B } else { $null }
            if ($b -and $b.SteamId -ne $fid) { return }   # cambiaste de amigo mientras tanto

            if (-not $b -or ((Get-UnixNow) - $b.Time) -gt 150) {
                $status.Text = "Esperando a ${name}: tiene que estar jugando con esta app abierta y 'Compartir mi partida' tildado."; return
            }
            if (-not $b.Playing) { $status.Text = "$name no está jugando L4D2 ahora."; return }

            # Regla: solo mandar una orden cuando el amigo se mueve a un server DISTINTO, o arma un lobby
            # nuevo estando fuera de un server. Cualquier orden extra (reconectar al mismo server, unirse
            # a un lobby) saca al juego de la partida en la que ya estás.
            if ($b.Server) {
                # Una vez que estamos en su server, se deja de seguir: si despues el amigo se va,
                # vos te quedas en la partida. Para volver a seguirlo, se tilda "Seguirlo" de nuevo.
                $stopMsg = "Dejé de seguir a $name para que no te saque de la partida si se va. Seguís en su grupo; tildá 'Seguirlo' para que te vuelva a llevar."
                # Si ya te llevé a este mismo server, no reconectar (te sacaría de la partida): esperar a que cambie
                if ($b.Server -eq $script:joinedServer) {
                    $status.Text = "Ya te llevé al server de $name ($($b.Server)). Te llevo de nuevo cuando se cambie de server."
                    return
                }
                $script:joinedServer = $b.Server
                # Si hace poco entramos a su lobby, el juego nos lleva junto con el lobby: no conectar a mano
                if ($script:followLobby -and ($b.Lobby -eq $script:followLobby -or (Get-Date) -lt $script:lobbyJoinedAt.AddSeconds(120))) {
                    $script:autoUncheck = $true; $chkSteamFollow.Checked = $false; $script:autoUncheck = $false   # sigue en el grupo
                    $status.Text = "Entrás con el lobby de $name al server $($b.Server). $stopMsg"
                    return
                }
                [System.Media.SystemSounds]::Asterisk.Play()
                Start-Process "steam://connect/$($b.Server)"
                $script:autoUncheck = $true; $chkSteamFollow.Checked = $false; $script:autoUncheck = $false   # sigue en el grupo
                $status.Text = "$name está en el server $($b.Server): te llevo. $stopMsg"
                return
            }

            # Sin server: si armó un lobby nuevo, entrar a su lobby (y seguir esperando a que arranque)
            if ($b.Lobby -and $b.Lobby -ne $script:followLobby) {
                $script:followLobby = $b.Lobby; $script:lobbyJoinedAt = Get-Date
                [System.Media.SystemSounds]::Asterisk.Play()
                Start-Process "steam://joinlobby/550/$($b.Lobby)/$fid"
                $status.Text = "$name armó un lobby. Te llevo..."
                return
            }
            $status.Text = if ($b.Lobby) { "Siguiendo a $name (su lobby)." } else { "$name está en el menú del juego. Cuando entre a un server o arme un lobby, te llevo." }
        }
    })
$steamTimer.Start()

# --- compartir: mirar mi estado en Steam cada 5 s y transmitirlo si cambio (o cada 60 s mientras juego) ---
$shareTimer = New-Object Windows.Forms.Timer
$shareTimer.Interval = 5000
$shareTimer.add_Tick({
        if (-not $chkShare.Visible -or -not $chkShare.Checked -or -not $script:me) { return }
        Start-Async 'share' {
            param($me, $lastState, $lastSentTicks)
            $key = Get-ApiKey
            if (-not $key) { return }
            $mine = (Get-SteamStatus $key @($me))[$me]
            if (-not $mine) { return }
            $state = "$($mine.InL4D2)|$($mine.Server)|$($mine.Lobby)"
            $due = $mine.InL4D2 -and (([datetime]::Now.Ticks - $lastSentTicks) / 1e7) -ge 60
            $sent = $false
            if ($state -ne $lastState -or $due) { Send-SteamBroadcast $me $mine.InL4D2 $mine.Server $mine.Lobby; $sent = $true }
            [pscustomobject]@{ State = $state; Sent = $sent; Mine = $mine }
        } @($script:me, $script:shareState, $script:shareSentAt.Ticks) {
            param($res, $err)
            $r = Get-First $res
            if ($err -or -not $r -or -not $r.Sent) { return }
            if ($r.State -ne $script:shareState -and $r.Mine.InL4D2) {
                $where = if ($r.Mine.Server) { "en el server $($r.Mine.Server)" } elseif ($r.Mine.Lobby) { 'en un lobby' } else { 'en el menú' }
                $status.Text = "Compartiendo tu partida con tus amigos: estás $where."
            }
            $script:shareState = $r.State; $script:shareSentAt = Get-Date
        }
    })
$shareTimer.Start()

$chkSteamFollow.add_CheckedChanged({
        $script:followLobby = ''
        # Grupo: tildar = entrar al grupo del amigo; destildar a mano = salir (el destildado automatico no saca)
        if ($chkSteamFollow.Checked) { $fid = Get-FollowedId; if ($fid -and $fid -ne $script:groupLeader) { Set-GroupLeader $fid } }
        elseif (-not $script:autoUncheck -and $script:groupLeader) { Set-GroupLeader '' }
        if ($chkSteamFollow.Checked) {
            if (-not (Get-FollowedId)) { $status.Text = 'Elegí a quién seguir en la lista de amigos.' }
            else { $status.Text = "Siguiendo a $($script:friendNames[$cmbFriend.SelectedIndex]). Dejá esta ventana abierta (puede estar minimizada)." }
        }
    })
$chkShare.add_CheckedChanged({ $script:shareState = '' })
$cmbFriend.add_SelectedIndexChanged({ $script:followLobby = '' })
# Solo cuando lo elegís vos (no cuando la lista se refresca sola)
$cmbFriend.add_SelectionChangeCommitted({
        $fid = Get-FollowedId
        if ($chkSteamFollow.Checked -and $fid -and $fid -ne $script:groupLeader) { Set-GroupLeader $fid }
    })
$btnLeave.add_Click({
        if ($chkSteamFollow.Checked) { $chkSteamFollow.Checked = $false }   # destildar a mano ya te saca del grupo
        else { Set-GroupLeader '' }
        $status.Text = 'Saliste del grupo.'
    })
$btnFriends.add_Click({ Update-FriendList })
$btnKey.add_Click({
        Start-Process 'https://steamcommunity.com/dev/apikey'
        Add-Type -AssemblyName Microsoft.VisualBasic
        $k = [Microsoft.VisualBasic.Interaction]::InputBox(
            "La API key solo hace falta para BUSCAR servers y para compartir tu partida. Para seguir a un amigo no hace falta.`n`nSe abrió la página de Steam: en 'Domain Name' poné cualquier cosa (por ejemplo: localhost), aceptá, copiá la key y pegala acá:",
            'API key de Steam')
        $k = "$k".Trim()
        if ($k -match '^[0-9A-Fa-f]{32}$') {
            [IO.File]::WriteAllText($keyFile, $k)
            $btnKey.Visible = $false; $chkShare.Visible = $true
            $status.Text = 'API key guardada. Ya podés buscar servers y compartir tu partida.'
        } elseif ($k) { $status.Text = 'Esa key no parece válida (son 32 letras y números).' }
    })

# ---------------- refresco automatico ----------------
$autoTimer = New-Object Windows.Forms.Timer
$autoTimer.Interval = 60000
$autoTimer.add_Tick({
        # No refresca si esta apagado, si ya hay una busqueda en curso o si la ventana esta minimizada
        if ($chkAuto.Checked -and $btnSearch.Enabled -and $form.WindowState -ne 'Minimized') { $btnSearch.PerformClick() }
    })
$chkAuto.add_CheckedChanged({ $autoTimer.Stop(); $autoTimer.Start() })   # reinicia la cuenta de 1 min
$autoTimer.Start()

# ---------------- actualizaciones ----------------
# Al abrir y cada 6 horas: si hay version nueva firmada, se instala sola y se ofrece reiniciar.
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
        Start-Process -FilePath (Join-Path $here 'Buscar versus.bat') -WorkingDirectory $here
        $form.Close()
    })
$updateTimer = New-Object Windows.Forms.Timer
$updateTimer.Interval = 6 * 3600 * 1000
$updateTimer.add_Tick({ Request-Update })
$updateTimer.Start()

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
        Update-FriendList
        Update-Group @()
        # Addons instalados: que mapas trae cada uno (para la imagen de los mapas custom)
        Start-Async 'addons' { param($known) $g = Find-L4D2Path; if ($g) { Get-InstalledAddonMaps $g $known } } @(, $script:customIx.Addons) {
            param($res, $err)
            $a = Get-First $res
            if ($a -is [hashtable]) { Update-AddonMaps $a; $script:imgCache = @{}; Show-Rows }
        }
        if ($script:groupLeader) { Send-Beat }
        Request-Group
        Request-Update
        Set-View $script:view   # busca solo si se puede (las salas siempre; los servers con API key)
        if ($btnSearch.Enabled -and $null -eq $script:results[$script:view]) {
            if ($chkSteamFollow.Checked -and (Get-FollowedId)) { $status.Text = "Siguiendo a $($script:friendNames[$cmbFriend.SelectedIndex])." }
            else { $status.Text = 'Para seguir a un amigo: elegilo en "Seguir a un amigo de Steam" y tildá "Seguirlo". Las salas de espera se buscan sin API key.' }
        }
    })
$form.add_FormClosing({
        $autoTimer.Stop(); $steamTimer.Stop(); $friendsTimer.Stop(); $shareTimer.Stop(); $pumpTimer.Stop(); $groupTimer.Stop(); $beatTimer.Stop()
        # Avisar que dejás el grupo (si no llega, el lider te saca solo al minuto y poco)
        if ($script:groupLeader -and $script:me -and -not $Screenshot) { try { Send-FollowSignal $script:me '' } catch {} }
        $settings.Share = $chkShare.Checked
        $fid = Get-FollowedId
        if ($fid) { $settings.FollowSteamId = $fid }
        $settings.SteamFollow = $chkSteamFollow.Checked
        $settings.AutoRefresh = $chkAuto.Checked
        $settings.Campaigns = @(Get-SelectedCampaigns)
        $settings.ServerType = [string]$script:typeSel.servers
        $settings.LobbyType = [string]$script:typeSel.lobbies
        $settings.View = $script:view
        $settings.Party = [int]$numParty.Value
        $settings.MaxPing = [int]$numPing.Value
        if (-not $Screenshot) { Save-Settings $settings }   # las capturas de prueba no tocan la config
    })

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

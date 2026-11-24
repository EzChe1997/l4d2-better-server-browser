<#
  finder.ps1 - Buscador de partidas versus de L4D2 con lugar para tu grupo.

  Abrir la ventana:  doble clic en "Buscar versus.bat"
  Modo consola (pruebas):
    powershell -ExecutionPolicy Bypass -File finder.ps1 -Console -Party 2 -MaxPing 150

  No necesita API key: la lista de servers se le pide al cliente de Steam (tiene que estar abierto).
#>
param(
    [switch]$Console,
    [int]$Party = 2,
    [int]$MaxPing = 150,
    [switch]$IncludeBig,
    [switch]$HideValve,
    [string]$Screenshot,
    [string]$TestRules,
    [switch]$TestSteam,
    [switch]$Lobbies,
    [switch]$TestGroup,
    [switch]$Audit,
    [string]$View
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$keyFile = Join-Path $here 'apikey.txt'
# ======================= actualizaciones automaticas =======================
# La app se fija si hay una version nueva publicada en GitHub. El indice (update.json) va firmado
# con una clave que solo tiene quien publica: si la firma no coincide, la actualizacion se ignora.
$AppVersion = 14
$updateBase = 'https://raw.githubusercontent.com/EzChe1997/l4d2-better-server-browser/main'   # lo completa publicar.ps1 (https://raw.githubusercontent.com/<usuario>/<repo>/main)
$updatePublicKey = '<RSAKeyValue><Modulus>3uVFz1ZH9ed0Zun/YcmPi4gk8EALr+R7/DYQY+Fz5NArgRYEo1iNfjNpBUn7G3R0Tliw5DjecmnM0/InLrFLJl2BgMmwJo0VBw4BJ/7qmQm1q7oJoZ0mjI8cgxynbgyhARnQY3i9lVnEGfwB3IOnYhire7XM6iFxui9b5fOd3npzorhJakLqdMdPLBc7BT5VE8E/MfeyhlhusGlKpgsB4QWY3U8WufkkE81E5bziCI1m3RYYUVeoqGukzfujshi2OwV9EBpAIWgDmdZNA3UBDwd6Q0ocq2/EvPfzzNZgNbeQObT+DutokxYEz2e8DlZU0ek46JsxTOFQShlNKoOeHUiXMfjfwUc3j6KqYRNUF1VV9xOzML2W9/+l73r6SnmrPVMItghOEzVivQgZ6gtk3Y901stV4yxTB+RFXO89EFbGYF4C2zhGvdssKxuWibjan9P5D6f/00E6uAb4ehy5MT5Cfj7Iy0Wqo8AmKTOFWOJU8BOjDOu7Odbgi8Xs6dNp</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$updateFiles = @('finder.ps1', 'ui.ps1', 'vpk.ps1', 'lobbies.ps1', 'Buscar versus.bat')

# Baja, verifica e instala la version nueva. Devuelve $null si no hay nada nuevo.
function Install-Update([string]$base, [string]$pubKey, [int]$current, [string]$dir, [string[]]$allowed) {
    if (-not $base) { return $null }
    $ErrorActionPreference = 'Stop'   # cualquier error corta: nunca instalar a medias
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient
    $nc = if ($base -like 'http*') { "?t=$([DateTime]::UtcNow.Ticks)" } else { '' }   # evitar copias viejas en cache
    $manBytes = $wc.DownloadData("$base/update.json$nc")
    $sig = [Convert]::FromBase64String($wc.DownloadString("$base/update.sig$nc").Trim())
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($pubKey)
    if (-not $rsa.VerifyData($manBytes, 'SHA256', $sig)) { throw 'La actualización publicada no tiene una firma válida; la ignoro.' }
    $man = [Text.Encoding]::UTF8.GetString($manBytes) | ConvertFrom-Json
    if ([int]$man.version -le $current) { return $null }

    # Bajar todo a una carpeta aparte y verificar cada archivo antes de tocar nada
    $stage = Join-Path $dir 'update-tmp'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory $stage | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    $names = @()
    foreach ($p in $man.files.PSObject.Properties) {
        $name = $p.Name
        if ($allowed -notcontains $name) { throw "La actualización trae un archivo no permitido: $name" }
        $bytes = $wc.DownloadData("$base/$([uri]::EscapeDataString($name))$nc")
        $hash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        if ($hash -ne [string]$p.Value) { throw "El archivo $name no coincide con la versión firmada (puede ser la cache de GitHub; reintento más tarde)." }
        [IO.File]::WriteAllBytes((Join-Path $stage $name), $bytes)
        $names += $name
    }
    foreach ($name in $names) { Copy-Item (Join-Path $stage $name) (Join-Path $dir $name) -Force }
    Remove-Item $stage -Recurse -Force
    return [pscustomobject]@{ Version = [int]$man.version; Notes = [string]$man.notes }
}

# >>> BUSQUEDA (desde aca hasta <<< BUSQUEDA lo carga tambien el hilo de fondo de la ventana)
# ======================= protocolo de consultas de Steam (A2S) =======================
# En C# y no como clase de PowerShell: las clases de PowerShell 5.1 quedan atadas al hilo donde se
# crearon, y esta parte corre en varios hilos a la vez (búsqueda, "dónde está tu grupo", seguir).
if (-not ('L4dPacketReader' -as [type])) {
    Add-Type -TypeDefinition @"
public class L4dPacketReader {
    public byte[] D; public int P;
    public L4dPacketReader(byte[] d, int p) { D = d; P = p; }
    public bool More() { return P < D.Length; }
    public byte Byte() { return D[P++]; }
    public ushort UShort() { ushort v = System.BitConverter.ToUInt16(D, P); P += 2; return v; }
    public int Long() { int v = System.BitConverter.ToInt32(D, P); P += 4; return v; }
    public float Float() { float v = System.BitConverter.ToSingle(D, P); P += 4; return v; }
    public void Skip(int n) { P += n; }
    public string Str() {
        int start = P;
        while (P < D.Length && D[P] != 0) P++;
        string s = System.Text.Encoding.UTF8.GetString(D, start, P - start);
        P++;
        return s;
    }
}
"@
}

# Si la ventana define $Pump, los bucles de espera lo llaman para no trabarla
$Pump = $null

$hdr = [byte[]](0xFF, 0xFF, 0xFF, 0xFF)
$infoReq = [byte[]]($hdr + [byte]0x54 + [Text.Encoding]::ASCII.GetBytes('Source Engine Query') + [byte]0)
$playerReq = [byte[]]($hdr + [byte]0x55 + $hdr)

function New-Udp([int]$timeout) {
    $udp = New-Object System.Net.Sockets.UdpClient(0)
    $udp.Client.ReceiveTimeout = $timeout
    $udp.Client.ReceiveBufferSize = 1MB
    # Que Windows no corte el socket si un server responde "puerto inalcanzable"
    try { [void]$udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch {}
    return $udp
}

function Get-Endpoint([string]$addr) {
    $parts = $addr.Split(':')
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$ip)) {
        $ip = [Net.Dns]::GetHostAddresses($parts[0]) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    }
    return New-Object Net.IPEndPoint($ip, [int]$parts[1])
}

function ConvertFrom-InfoPacket([byte[]]$d) {
    $p = [L4dPacketReader]::new($d, 5)
    $i = [ordered]@{}
    [void]$p.Byte()
    $i.Name = $p.Str(); $i.Map = $p.Str(); [void]$p.Str(); [void]$p.Str()
    $i.AppId = [int]$p.UShort()   # 550 = L4D2 (sirve para los servers del historial, que pueden ser de otro juego)
    $i.Players = [int]$p.Byte(); $i.MaxPlayers = [int]$p.Byte(); $i.Bots = [int]$p.Byte()
    [void]$p.Byte(); [void]$p.Byte()
    $i.Password = [int]$p.Byte()
    [void]$p.Byte()
    [void]$p.Str()
    $i.Tags = ''
    if ($p.More()) {
        $edf = $p.Byte()
        if ($edf -band 0x80) { [void]$p.UShort() }
        if ($edf -band 0x10) { $p.Skip(8) }
        if ($edf -band 0x40) { [void]$p.UShort(); [void]$p.Str() }
        if ($edf -band 0x20) { $i.Tags = $p.Str() }
    }
    return $i
}

function ConvertFrom-PlayerPacket([byte[]]$d) {
    $p = [L4dPacketReader]::new($d, 5)
    $n = $p.Byte()
    $list = @()
    for ($k = 0; $k -lt $n -and $p.More(); $k++) {
        [void]$p.Byte()
        $list += [pscustomobject]@{ Name = $p.Str(); Score = $p.Long(); Seconds = [int]$p.Float() }
    }
    return , $list
}

# Info + ping. Se manda en tandas chicas para que el ping medido sea real.
function Invoke-InfoScan([string[]]$addrs, [int]$batchSize = 40, [int]$waitMs = 700) {
    $udp = New-Udp 50
    $results = @{}; $clock = @{}; $ping = @{}
    try {
        for ($i = 0; $i -lt $addrs.Count; $i += $batchSize) {
            $end = [math]::Min($i + $batchSize, $addrs.Count) - 1
            $batch = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($a in $addrs[$i..$end]) {
                try {
                    $ep = Get-Endpoint $a
                    $k = "$($ep.Address):$($ep.Port)"
                    $clock[$k] = [Diagnostics.Stopwatch]::StartNew()
                    [void]$udp.Send($infoReq, $infoReq.Length, $ep)
                    [void]$batch.Add($k)
                } catch {}
            }
            $answered = 0
            $deadline = (Get-Date).AddMilliseconds($waitMs)
            while ((Get-Date) -lt $deadline -and $answered -lt $batch.Count) {
                $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                if ($Pump) { & $Pump }; try { $d = $udp.Receive([ref]$from) } catch { continue }
                $k = "$($from.Address):$($from.Port)"
                if (-not $clock.ContainsKey($k) -or $d.Length -lt 5) { continue }
                if (-not $ping.ContainsKey($k)) { $ping[$k] = [int]$clock[$k].ElapsedMilliseconds }
                if ($d[4] -eq 0x41 -and $d.Length -ge 9) {
                    $req = [byte[]]($infoReq + $d[5..8])
                    [void]$udp.Send($req, $req.Length, $from)
                } elseif ($d[4] -eq 0x49 -and -not $results.ContainsKey($k)) {
                    try {
                        $info = ConvertFrom-InfoPacket $d
                        $info.Addr = $k
                        $info.Ping = $ping[$k]
                        $results[$k] = [pscustomobject]$info
                        if ($batch.Contains($k)) { $answered++ }
                    } catch {}
                }
            }
        }
    } finally { $udp.Close() }
    return @($results.Values)
}

# Lista de jugadores de varios servers a la vez.
function Invoke-PlayerScan([string[]]$addrs, [int]$waitMs = 1500) {
    $udp = New-Udp 50
    $want = @{}; $results = @{}
    try {
        foreach ($a in $addrs) {
            try { $ep = Get-Endpoint $a; [void]$udp.Send($playerReq, $playerReq.Length, $ep); $want["$($ep.Address):$($ep.Port)"] = $true } catch {}
        }
        $deadline = (Get-Date).AddMilliseconds($waitMs)
        while ((Get-Date) -lt $deadline -and $results.Count -lt $want.Count) {
            $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            if ($Pump) { & $Pump }; try { $d = $udp.Receive([ref]$from) } catch { continue }
            $k = "$($from.Address):$($from.Port)"
            if (-not $want.ContainsKey($k) -or $d.Length -lt 6) { continue }
            if ($d[4] -eq 0x41 -and $d.Length -ge 9) {
                $req = [byte[]]($hdr + [byte]0x55 + $d[5..8])
                [void]$udp.Send($req, $req.Length, $from)
            } elseif ($d[4] -eq 0x44 -and -not $results.ContainsKey($k)) {
                try { $results[$k] = ConvertFrom-PlayerPacket $d } catch {}
            }
        }
    } finally { $udp.Close() }
    return $results
}

# Config competitiva cargada (variable l4d_ready_cfg_name, ej. "ZoneMod v2.9.2b") de varios servers.
function ConvertFrom-RulesCfg([byte[]]$d, [string]$rule = 'l4d_ready_cfg_name') {
    $count = [BitConverter]::ToUInt16($d, 5); $p = 7
    for ($n = 0; $n -lt $count -and $p -lt $d.Length; $n++) {
        $e = [Array]::IndexOf($d, [byte]0, $p); if ($e -lt 0) { break }
        $name = [Text.Encoding]::UTF8.GetString($d, $p, $e - $p); $p = $e + 1
        $e = [Array]::IndexOf($d, [byte]0, $p); if ($e -lt 0) { break }
        if ($name -eq $rule) { return [Text.Encoding]::UTF8.GetString($d, $p, $e - $p) }
        $p = $e + 1
    }
    return '#none'   # el server no publica la variable (distinto de publicarla vacía = sin partida cargada)
}

function Invoke-RulesScan([string[]]$addrs, [int]$waitMs = 2000, [string]$rule = 'l4d_ready_cfg_name') {
    $udp = New-Udp 50
    $req0 = [byte[]]($hdr + [byte]0x56 + $hdr)
    $want = @{}; $results = @{}; $parts = @{}
    try {
        foreach ($a in $addrs) {
            try { $ep = Get-Endpoint $a; [void]$udp.Send($req0, $req0.Length, $ep); $want["$($ep.Address):$($ep.Port)"] = $true } catch {}
        }
        $deadline = (Get-Date).AddMilliseconds($waitMs)
        while ((Get-Date) -lt $deadline -and $results.Count -lt $want.Count) {
            $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            if ($Pump) { & $Pump }; try { $d = $udp.Receive([ref]$from) } catch { continue }
            $k = "$($from.Address):$($from.Port)"
            if (-not $want.ContainsKey($k) -or $results.ContainsKey($k) -or $d.Length -lt 5) { continue }
            $head = [BitConverter]::ToInt32($d, 0)
            if ($head -eq -1) {
                if ($d[4] -eq 0x41 -and $d.Length -ge 9) {
                    $req = [byte[]]($hdr + [byte]0x56 + $d[5..8])
                    [void]$udp.Send($req, $req.Length, $from)
                } elseif ($d[4] -eq 0x45) { $results[$k] = ConvertFrom-RulesCfg $d $rule }
            } elseif ($head -eq -2 -and $d.Length -gt 12) {
                # Respuesta partida en varios paquetes: FE FF FF FF, id, total, numero, tamano, datos
                if ([BitConverter]::ToInt32($d, 4) -lt 0) { $results[$k] = '#none'; continue }   # comprimida: no soportada
                $total = [int]$d[8]
                if (-not $parts.ContainsKey($k)) { $parts[$k] = @{} }
                $chunk = New-Object byte[] ($d.Length - 12)
                [Array]::Copy($d, 12, $chunk, 0, $chunk.Length)
                $parts[$k][[int]$d[9]] = $chunk
                if ($parts[$k].Count -ge $total) {
                    $ms = New-Object IO.MemoryStream
                    for ($n = 0; $n -lt $total; $n++) { $b = $parts[$k][$n]; if ($b) { $ms.Write($b, 0, $b.Length) } }
                    $all = $ms.ToArray()
                    $results[$k] = if ($all.Length -gt 7 -and $all[4] -eq 0x45) { ConvertFrom-RulesCfg $all $rule } else { '#none' }
                }
            }
        }
    } finally { $udp.Close() }
    return $results
}

# ======================= campanas =======================
$campaigns = [ordered]@{
    c1 = 'Dead Center'; c2 = 'Dark Carnival'; c3 = 'Swamp Fever'; c4 = 'Hard Rain'; c5 = 'The Parish'
    c6 = 'The Passing'; c7 = 'The Sacrifice'; c8 = 'No Mercy'; c9 = 'Crash Course'; c10 = 'Death Toll'
    c11 = 'Dead Air'; c12 = 'Blood Harvest'; c13 = 'Cold Stream'; c14 = 'The Last Stand'
}

function Get-CampaignKey([string]$map) {
    if ($map -match '^(c\d+)m\d+_' -and $campaigns.Contains($Matches[1].ToLower())) { return $Matches[1].ToLower() }
    foreach ($k in $campaigns.Keys) { if ($map -like "*$($campaigns[$k])*") { return $k } }   # servers que informan el nombre lindo
    return 'custom'
}

# ======================= salas de espera (lobbies de Steam) =======================
# La Web API no lista lobbies: lobbies.ps1 los pide al cliente de Steam usando el steam_api.dll
# del juego (32 bits), en un PowerShell de 32 bits aparte. No necesita API key.
# Arranca lobbies.ps1 sin esperarlo (Receive-LobbyHelper junta la respuesta)
function Start-LobbyHelper([string]$dir, [string]$helperArgs, [switch]$Stream) {
    $game = Find-L4D2Path
    if (-not $game) { throw 'No encuentro Left 4 Dead 2 instalado.' }
    $dll = Join-Path $game 'bin\steam_api.dll'
    if (-not (Test-Path $dll)) { throw "No encuentro $dll" }
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps32)) { $ps32 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }   # Windows de 32 bits
    $psi = New-Object Diagnostics.ProcessStartInfo $ps32
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Dll "{1}" {2}' -f (Join-Path $dir 'lobbies.ps1'), $dll, $helperArgs
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $err = $proc.StandardError.ReadToEndAsync()
    if ($Stream) { return @{ Proc = $proc; Err = $err } }   # el que lo lanzó lee la salida línea por línea
    return @{ Proc = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $err }
}

function Receive-LobbyHelper($h) {
    if (-not $h.Proc.WaitForExit(45000)) { try { $h.Proc.Kill() } catch {}; throw 'Steam tardó demasiado en responder.' }
    # La salida puede no cerrarse nunca si algo que arrancó Steam heredó la tubería: no esperar para siempre
    if (-not $h.Out.Wait(5000)) { throw 'Steam no terminó de responder (la salida quedó abierta).' }
    $text = $h.Out.Result.Trim()
    if ($text -like 'ERROR:*') { throw $text.Substring(6).Trim() }
    if (-not $text.StartsWith('[')) { throw "No pude leer las salas de Steam. $($h.Err.Result.Trim())" }
    return $text
}

function Get-LobbyJson([int]$party, [string]$dir, [string]$game = 'versus') {
    # Pedido extra: todas las salas del modo con campaña custom del mundo (son pocas y quedan fuera de las 50 cercanas).
    # Sirven para mostrarlas y para aprender qué campaña de la Workshop es cada mapa custom.
    if ($game -notmatch '^(versus|mutation12|mutation15|scavenge)$') { $game = 'versus' }
    Receive-LobbyHelper (Start-LobbyHelper $dir ('-Slots {0} -Filter "Game:mode={1},Game:state=lobby,System:access=public" -ExtraFilter "Game:mode={1},Game:MissionInfo:BuiltIn=0"' -f $party, $game))
}

# Partidas ya empezadas en servers oficiales de Valve con sala PUBLICA (Steam solo lista las publicas).
# Cada pedido trae 50 como mucho, así que se parte: C1, C2 y C5 (las más jugadas) por separado y el resto
# de las campañas juntas ("distinto de" esas tres). Si alguno llega a 50 (puede haber más), en el mismo
# proceso se pide en partes: por capítulo, o el resto campaña por campaña. Antes eran 24 pedidos fijos
# (~10 s); así son 4 casi siempre (~3 s). Steam no deja hacer varios pedidos de salas a la vez desde la
# misma cuenta (cancela los anteriores): por eso van todos en un único proceso, uno tras otro.
function Start-OfficialGamesHelpers([string]$dir) {
    $base = 'Game:state=game,Options:server=official'
    $passes = foreach ($n in 1, 2, 5) {
        $parts = foreach ($ch in 1..5) { "$base,Game:campaign=L4D2C$n,Game:chapter=$ch" }
        "1|0|$base,Game:campaign=L4D2C$n|$($parts -join '^')"
    }
    $others = @(1..14 | Where-Object { $_ -notin 1, 2, 5 })
    $parts = foreach ($n in $others) { "$base,Game:campaign=L4D2C$n" }
    $passes = @($passes) + "1|0|$base,Game:campaign!=L4D2C1,Game:campaign!=L4D2C2,Game:campaign!=L4D2C5|$($parts -join '^')"
    Start-LobbyHelper $dir ('-Passes "{0}"' -f ($passes -join ';'))
}
# Junta las salas de todos los procesos (si alguno falla, falla todo: mejor no marcar nada que marcar mal)
function Receive-OfficialGames($helpers) {
    $all = foreach ($h in @($helpers)) { (Receive-LobbyHelper $h) | ConvertFrom-Json | ForEach-Object { $_ } }
    return @($all | Where-Object { $_ -and [int]$_.'Members:numPlayers' -lt 99 -and [string]$_.'Game:campaign' -match '^L4D2C\d+$' })
}

# Une cada sala publica con un server oficial de la lista (misma campaña y capitulo, ~misma gente).
# Devuelve addr -> modo de la sala. Los oficiales con gente que no quedan unidos a ninguna sala
# casi seguro son de "solo amigos" o privados: conectarse directo te mete igual.
# $fakes: servers de comunidades que se anuncian como "official" (p. ej. Lewd4Dead, con mods): las salas
# "oficiales" pueden estar jugando en ellos. Una sala que coincide con alguno no se une a ningun server de
# Valve: con "Unirme" el juego te lleva a donde esta la sala de verdad, y podria ser ese server.
# Se llama después de cada tanda de la búsqueda: los servers se agrupan por campaña y capítulo una vez,
# en vez de comparar cada sala con cada server.
# $prev: el cruce anterior. A igual parecido, cada server se queda con la sala que ya tenía (si no, al
# sumar servers parecidos las salas saltan de uno a otro y las tarjetas cambian a cada rato).
# $game: el modo buscado; sus salas van primero. En Búsqueda el "capítulo" de la sala no es el número del
# mapa (sala C8 cap. 2 = c8m5_rooftop), así que ahí se cruza solo por campaña y cantidad de gente.
function Get-OfficialLobbyMatch($servers, $lobbies, $fakes = @(), $prev = $null, [string]$game = 'versus') {
    $byCamp = $game -eq 'scavenge'
    $byKey = @{}; $fakeKey = @{}
    foreach ($s in @($servers)) {
        if ($s.Map -notmatch '^(c\d+)m(\d+)_') { continue }
        $k = if ($byCamp) { $Matches[1] } else { "$($Matches[1])|$([int]$Matches[2])" }
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = New-Object Collections.ArrayList }
        [void]$byKey[$k].Add($s)
    }
    foreach ($f in @($fakes)) {
        if ($f.Map -notmatch '^(c\d+)m(\d+)_') { continue }
        $k = if ($byCamp) { $Matches[1] } else { "$($Matches[1])|$([int]$Matches[2])" }
        if (-not $fakeKey.ContainsKey($k)) { $fakeKey[$k] = New-Object Collections.ArrayList }
        [void]$fakeKey[$k].Add([int]$f.Humans)
    }
    $pairs = foreach ($l in @($lobbies)) {
        $camp = ([string]$l.'Game:campaign').Substring(4).ToLower()   # L4D2C5 -> c5
        $k = if ($byCamp) { $camp } else { "$camp|$([int]$l.'Game:chapter')" }
        if (-not $byKey.ContainsKey($k)) { continue }
        $n = [math]::Max([int]$l.'Members:numPlayers', [int]$l._members)
        if ($fakeKey.ContainsKey($k) -and @($fakeKey[$k] | Where-Object { [math]::Abs($_ - $n) -le 1 }).Count) { continue }
        foreach ($s in $byKey[$k]) {
            $diff = [math]::Abs($s.Humans - $n)
            if ($diff -le 1) {
                $keep = if ($prev -and $prev[$s.Addr] -and $prev[$s.Addr].Lobby -eq [string]$l._id) { 0 } else { 1 }
                [pscustomobject]@{ Addr = $s.Addr; Lobby = [string]$l._id; Mode = [string]$l.'Game:mode'; Diff = $diff; Keep = $keep; Ping = $s.Ping; Free = [int]$l._limit - [int]$l._members }
            }
        }
    }
    # Primero las salas del modo buscado; las de otros modos parecidos solo con los servers que sobran
    # (las de coop no: esos servers se anuncian como coop y ni estan en la lista)
    $similar = if ($byCamp) { @('scavenge', 'teamscavenge') } else { @('versus', 'mutation12', 'mutation15', 'mutation18', 'mutation19', 'community3', 'community6') }
    $pairs = @($pairs | Where-Object { $similar -contains $_.Mode })
    $match = @{}; $usedLobby = @{}
    foreach ($p in @($pairs | Sort-Object { [int]($_.Mode -ne $game) }, Diff, Keep, Ping)) {
        if ($match.ContainsKey($p.Addr) -or $usedLobby.ContainsKey($p.Lobby)) { continue }
        $match[$p.Addr] = $p; $usedLobby[$p.Lobby] = $true
    }
    return $match
}

# ======================= imagenes de mapas custom =======================
# Los mapas custom no traen imagen en el juego base. Se busca su campaña en la Workshop de Steam
# (portada sin API key) por 4 caminos, del mas exacto al menos:
#   1) salas: traen el numero de Workshop;  2) addons instalados: su .vpk dice que mapas tiene;
#   3) lo aprendido de las salas (campaña -> Workshop);  4) catalogo de customs populares en versus.
$customCatalog = @(
    @{ Rx = '^l4d2_diescraper'; Id = '121116980' }    # Diescraper Redux
    @{ Rx = '^l4d_dbd2dc_'; Id = '123685403' }        # Dead Before Dawn DC
    @{ Rx = '^l4d2_daybreak0'; Id = '180925247' }     # Day Break
    @{ Rx = '^dkr_m\d'; Id = '1575673903' }           # Dark Carnival: Remix
    @{ Rx = '^uf\d_'; Id = '121086524' }              # Urban Flight
    @{ Rx = '^cdta_'; Id = '121275675' }              # Detour Ahead
    @{ Rx = '^l4d2_stadium\d'; Id = '1910161083' }    # Suicide Blitz 2
    @{ Rx = '^cwm\d_'; Id = '381431565' }             # Carried Off
    @{ Rx = '^l4d2_city17_'; Id = '141632373' }       # City 17
    @{ Rx = '^hf0\d_'; Id = '2325347179' }            # Haunted Forest
)

function ConvertFrom-HexId([string]$hex) {
    if ($hex -match '^[0-9A-Fa-f]{1,16}$' -and $hex -ne '0') { return [string][Convert]::ToUInt64($hex, 16) }
    return ''
}

function Get-NormName([string]$s) { return ($s.ToLower() -replace '[^a-z0-9]', '') }

function Get-CustomIndex([string]$file) {
    $ix = @{ Campaigns = @{}; Maps = @{}; Titles = @{}; Addons = @{} }
    if (Test-Path $file) {
        try {
            $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in 'Campaigns', 'Maps', 'Titles', 'Addons') {
                if ($j.$k) { foreach ($p in $j.$k.PSObject.Properties) { $ix[$k][$p.Name] = $p.Value } }
            }
        } catch {}
    }
    return $ix
}

function Save-CustomIndex($ix, [string]$file) {
    try { [IO.File]::WriteAllText($file, ($ix | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false))) } catch {}
}

# Aprende de las salas custom: nombre de campaña -> numero de Workshop (y el titulo)
function Update-CustomIndexFromLobbies($ix, [string]$json) {
    $changed = $false
    foreach ($l in @(($json | ConvertFrom-Json) | ForEach-Object { $_ })) {
        $id = ConvertFrom-HexId $l.'Game:MissionInfo:workshopid'
        $camp = Get-NormName ([string]$l.'Game:campaign')
        if (-not $id -or $camp.Length -lt 4 -or $camp -match '^l4d2c\d+$') { continue }
        if ($ix.Campaigns[$camp] -ne $id) { $ix.Campaigns[$camp] = $id; $changed = $true }
        $t = [string]$l.'Game:MissionInfo:DisplayTitle'
        if ($t -and -not $t.StartsWith('#') -and -not $ix.Titles[$id]) { $ix.Titles[$id] = $t; $changed = $true }
    }
    return $changed
}

# Numero de Workshop para un mapa custom de un server (o '' si no se sabe)
function Get-CustomWorkshopId($ix, [string]$map) {
    $m = $map.ToLower()
    if ($ix.Maps[$m]) { return $ix.Maps[$m] }
    $n = Get-NormName $m
    $best = ''; $bestLen = 0
    foreach ($camp in $ix.Campaigns.Keys) {
        if ($camp.Length -ge 5 -and $camp.Length -gt $bestLen -and $n.StartsWith($camp)) { $best = $ix.Campaigns[$camp]; $bestLen = $camp.Length }
    }
    if ($best) { return $best }
    foreach ($e in $customCatalog) { if ($m -match $e.Rx) { return $e.Id } }
    return ''
}

# Lee los addons de la Workshop instalados: que mapas trae cada uno (cache por tamaño de archivo)
function Get-InstalledAddonMaps([string]$gameDir, $known) {
    $out = @{}
    $dir = Join-Path $gameDir 'left4dead2\addons\workshop'
    if (-not (Test-Path $dir)) { return $out }
    foreach ($v in Get-ChildItem $dir -Filter '*.vpk' -ErrorAction SilentlyContinue) {
        if ($v.BaseName -notmatch '^\d+$') { continue }
        $sig = "$($v.Length)"
        if ($known -and $known[$v.BaseName] -and $known[$v.BaseName].Sig -eq $sig) { $out[$v.BaseName] = $known[$v.BaseName]; continue }
        $maps = @()
        try { $maps = @(Read-VpkIndex $v.FullName | Where-Object { $_.Path -like 'maps/*.bsp' } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Path) }) } catch {}
        $out[$v.BaseName] = [pscustomobject]@{ Sig = $sig; Maps = $maps }
    }
    return $out
}

# Baja la portada de la Workshop de cada id (sin API key). Devuelve id -> titulo.
function Get-WorkshopImages([string[]]$ids, [string]$dir) {
    $titles = @{}
    $ids = @($ids | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
    if (-not $ids.Count) { return $titles }
    $body = "itemcount=$($ids.Count)"
    for ($i = 0; $i -lt $ids.Count; $i++) { $body += "&publishedfileids[$i]=$($ids[$i])" }
    $r = Invoke-RestMethod -Method Post -TimeoutSec 15 -Uri 'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/' -Body $body -ContentType 'application/x-www-form-urlencoded'
    foreach ($d in $r.response.publishedfiledetails) {
        if ($d.result -ne 1) { continue }
        $titles[[string]$d.publishedfileid] = [string]$d.title
        $file = Join-Path $dir "ws_$($d.publishedfileid).jpg"
        if ($d.preview_url -like 'https://*' -and -not (Test-Path $file)) {
            try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $d.preview_url -OutFile $file } catch {}
        }
    }
    return $titles
}

$serverKinds = @{ official = 'Server oficial de Valve'; dedicated = 'Server dedicado'; listen = 'La hostea un jugador' }

function ConvertTo-LobbyRows([string]$json, [int]$p, [bool]$hideValve) {
    $all = @(($json | ConvertFrom-Json) | ForEach-Object { $_ })
    $i = 0
    $rows = foreach ($l in $all) {
        $i++
        $slots = [int]$l.'Members:numSlots'; if ($slots -le 0) { $slots = [int]$l._limit }
        if ($l.'Game:state' -ne 'lobby' -or $l.'System:access' -ne 'public') { continue }   # el pedido extra trae partidas ya empezadas
        $h = [math]::Max([int]$l.'Members:numPlayers', [int]$l._members)
        if ($slots -ne 8 -or $h -le 0 -or $h -ge $slots) { continue }   # las de "99 jugadores" son truchas
        if ($l.'System:lock') { continue }
        $free = $slots - $h
        if ($free -lt $p) { continue }
        $server = [string]$l.'Options:server'
        if ($hideValve -and $server -eq 'official') { continue }

        $campRaw = [string]$l.'Game:campaign'
        $camp = if ($campRaw -match '^L4D2C(\d+)$' -and $campaigns.Contains("c$($Matches[1])")) { "c$($Matches[1])" } else { 'custom' }
        $chapter = [int]$l.'Game:chapter'; if ($chapter -le 0) { $chapter = 1 }
        $title = if ($camp -ne 'custom') { $campaigns[$camp] }
        elseif ($l.'Game:MissionInfo:DisplayTitle' -and -not ([string]$l.'Game:MissionInfo:DisplayTitle').StartsWith('#')) { $l.'Game:MissionInfo:DisplayTitle' }
        else { $campRaw }
        # En Búsqueda el número de la sala no es el capítulo de la campaña
        $title = if ([string]$l.'Game:mode' -eq 'scavenge') { "$title  ·  Búsqueda" } else { "$title  ·  Capítulo $chapter" }

        # Mismo criterio que en los servers: aunque los reparta parejo, ¿queda un equipo con lugar para todos?
        $seguro = [math]::Floor($h / 2) -le (4 - $p)
        $hint = if ($p -eq 1) { "Quedan $free lugares de 8." }
        elseif ($seguro) { "Entran los $p en el mismo equipo (quedan $free lugares de 8)." }
        else { "Quedan $free lugares, pero los pueden separar: cambiense de equipo en la sala antes de empezar." }

        $kind = if ($serverKinds[$server]) { $serverKinds[$server] } else { 'Sala pública' }
        $owner = [string]$l._owner
        $link = "steam://joinlobby/550/$($l._id)"
        if ($owner -and $owner -ne '0') { $link += "/$owner" }

        [pscustomobject]@{
            Kind = 'lobby'; Rank = $(if ($seguro) { 0 } else { 2 }); Estado = $(if ($seguro) { 'Seguro' } else { 'Depende' })
            Near = ($l._near -eq '1'); Order = $i
            Jugadores = "$h/$slots"; Humans = $h; Max = $slots; Title = $title
            Nombre = "Sala de espera  ·  $kind"; Mapa = $(if ($camp -ne 'custom') { $camp } else { $campRaw.ToLower() })
            Hint = $hint; Addr = [string]$l._id; Link = $link
            Valve = ($server -eq 'official'); Server = $server
            Custom = ([string]$l.'Game:MissionInfo:addon' -eq '1'); WorkshopId = (ConvertFrom-HexId $l.'Game:MissionInfo:workshopid')
            Campaign = $camp; Config = ''; Competitive = $false; ZoneMod = $false; Premade = $null
        }
    }
    return @($rows | Sort-Object Rank, @{ Expression = 'Near'; Descending = $true }, Order)
}

# ======================= logica de "entramos juntos?" =======================

# Agrupa jugadores que entraron con menos de 90 s de diferencia (suelen venir del mismo lobby).
function Get-JoinGroups($players) {
    $durs = @($players | Where-Object { $_.Name } | ForEach-Object { $_.Seconds } | Sort-Object -Descending)
    if ($durs.Count -eq 0) { return @() }
    $groups = @(); $size = 1
    for ($i = 1; $i -lt $durs.Count; $i++) {
        if ($durs[$i - 1] - $durs[$i] -le 90) { $size++ } else { $groups += $size; $size = 1 }
    }
    $groups += $size
    return @($groups | Sort-Object -Descending)
}

function Get-Verdict($info, $players, [int]$p, [int]$team = 0) {
    $h = [math]::Max($info.Players, @($players).Count)
    if ($team -le 0) { $team = [math]::Floor($info.MaxPlayers / 2) }
    $free = [math]::Min($info.MaxPlayers, 2 * $team) - $h
    if ($free -lt $p) { return $null }

    $groups = Get-JoinGroups $players
    $groupText = if ($groups.Count -gt 0) { 'entraron juntos: ' + ($groups -join '+') } else { '' }

    # Peor caso: los humanos estan repartidos parejo. Si aun asi hay lugar, es seguro.
    if ($p -le 1 -or [math]::Floor($h / 2) -le $team - $p) {
        return [pscustomobject]@{ Rank = 0; Status = 'Seguro'; Hint = "Hay lugar para $p juntos sea cual sea el reparto" }
    }
    # Si no, adivinamos por el grupo mas grande que entro junto (probablemente un equipo).
    if ($groups.Count -gt 0 -and $groups[0] -le $team) {
        $a = $groups[0]; $b = $h - $a
        if ($b -le $team -and (($team - $a) -ge $p -or ($team - $b) -ge $p)) {
            return [pscustomobject]@{ Rank = 1; Status = 'Probable'; Hint = "Seguramente $a vs $b ($groupText)" }
        }
    }
    return [pscustomobject]@{ Rank = 2; Status = 'Depende'; Hint = "Depende de como esten repartidos ($groupText)" }
}

# ¿Es versus? Por la etiqueta del modo; si el server no publica ninguna etiqueta, por el nombre.
# Modos que se pueden buscar (el valor es el Game:mode de las salas de Steam)
$gameModes = [ordered]@{ versus = 'Versus'; mutation12 = 'Versus realista'; mutation15 = 'Versus supervivencia'; scavenge = 'Búsqueda' }
# Versus realista y versus supervivencia son mutaciones: los servers se anuncian como versus común. En los
# oficiales se sabe por su sala; en los de la comunidad, solo si el nombre lo dice.
$gameNameRx = @{ mutation12 = '(?i)realis'; mutation15 = '(?i)surviv|superviv' }
function Test-GameServer([string]$tags, [string]$name, [string]$game) {
    if ($game -eq 'scavenge') { return ",$tags," -match '(?i),scavenge,' -or (-not $tags.Trim() -and $name -match '(?i)scavenge') }
    return Test-VersusServer $tags $name
}

function Test-VersusServer([string]$tags, [string]$name) {
    if ($tags -match 'versus') { return $true }
    return (-not $tags.Trim() -and $name -match '(?i)versus|zone\s*mod|zonepug|\bvs\b|\b\dv\d\b')
}

# Mutaciones y otros modos que tambien se anuncian como "versus": etiquetas de otro modo o nombre que lo dice
function Test-MutationServer([string]$tags, [string]$name) {
    if (",$tags," -match '(?i),(coop|realism|survival|scavenge|holdout|dash|shootzones|mutation\d*|community\d*),') { return $true }
    return $name -match '(?i)realism|realista|mutaci[oó]n|mutation'
}

# Servers del historial y favoritos de Steam (ver > servidores): pueden no figurar en la lista publica
function Get-HistoryServers {
    $me = Get-MySteamId
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $me -or -not $steam) { return @() }
    $file = Join-Path $steam "userdata\$([int64]$me - 76561197960265728)\7\remote\serverbrowser_hist.vdf"
    if (-not (Test-Path $file)) { return @() }
    $t = [IO.File]::ReadAllText($file)
    return @([regex]::Matches($t, '"address"\s+"(\d{1,3}(?:\.\d{1,3}){3}:\d{1,5})"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

# Lista de servers versus con gente y lugar, pedida al cliente de Steam como el navegador de servidores
# del juego (lobbies.ps1 -Servers): no necesita API key. Devuelve direcciones "ip:puerto".
function Get-SteamServerList([string]$dir) {
    $json = Receive-LobbyHelper (Start-LobbyHelper $dir '-Servers')
    return @(($json | ConvertFrom-Json) | ForEach-Object { $_ } | Where-Object { $_ })
}

# Fila de la lista para un server ($null si no sirve). $offPending: todavía no se sabe qué oficiales tienen
# sala pública; los de Valve salen "en verificación" (sin poder unirse) hasta saberlo.
function ConvertTo-ServerRow($s, $pl, $rules, $offMatch, [bool]$offPending, $hist, [int]$p, [bool]$includeBig, [string]$game = 'versus') {
    $isValve = $s.Name -like 'Valve Left4Dead 2*'
    # En Búsqueda la etiqueta "scavenge" es el modo buscado, no una mutación
    $modeTags = if ($game -eq 'scavenge') { (@("$($s.Tags)" -split ',' | Where-Object { $_ -ne 'scavenge' })) -join ',' } else { "$($s.Tags)" }
    $mutation = Test-MutationServer $modeTags "$($s.Name)"
    # Se hace pasar por oficial sin ser de Valve: server con mods (p. ej. Lewd4Dead). Se oculta como las mutaciones.
    if (",$($s.Tags)," -match ',official,' -and -not $isValve) { $mutation = $true }
    $friendsOnly = $false; $pending = $false
    if ($isValve -and $offPending) { $pending = $true }
    elseif ($isValve -and $null -ne $offMatch) {
        if (-not $offMatch.ContainsKey($s.Addr)) { $friendsOnly = $true }
        elseif ($offMatch[$s.Addr].Mode -ne $game) { $mutation = $true }
    }
    # OtherMode: no es del modo buscado (la ventana no la muestra). En versus realista / supervivencia: un
    # oficial solo si su sala es de ese modo (mientras se verifica, oculto: casi todos resultan versus común);
    # uno de la comunidad solo si el nombre lo dice.
    $otherMode = $false
    if ($gameNameRx.ContainsKey($game)) {
        if ($isValve) { $otherMode = $pending -or $friendsOnly -or $null -eq $offMatch -or $mutation }
        else { $otherMode = "$($s.Name)" -notmatch $gameNameRx[$game]; $mutation = $false }
    }
    # Oficial con sala publica: se entra por la SALA, no conectando al server. Asi siempre es una partida
    # publica (el cruce sala<->server es aproximado, y conectar directo a un server ajeno te mete en
    # cualquier partida, aunque sea privada o de solo amigos).
    $lobbyLink = ''
    if ($isValve -and $null -ne $offMatch -and $offMatch.ContainsKey($s.Addr)) { $lobbyLink = "steam://joinlobby/550/$($offMatch[$s.Addr].Lobby)" }

    # Config competitiva: la variable del server; si no la publica, el nombre del server.
    $rawCfg = if ($rules.ContainsKey($s.Addr)) { "$($rules[$s.Addr])" } else { '#none' }
    $cfg = if ($rawCfg.StartsWith('#')) { '' } else { $rawCfg }
    # Competitivo con la variable publicada pero vacía: no hay partida armada. La gente que está ahí espera
    # juntar 8 (servers "pug"); suelen irse, y muchos reinician el mapa a los segundos de quedar vacíos
    # (sm_restart_empty). Por eso se puede entrar viendo 1-2 nombres y encontrarse solo.
    $idle = ($s.Tags -match 'confogl') -and ($rawCfg -eq '' -or $rawCfg -eq '#empty')
    $text = "$cfg $($s.Name)"
    $competitive = $s.Tags -match 'confogl'
    $zoneMod = $text -match 'zone\s*mod|zonepug'
    # Formato de equipos si lo dice (1v1, 3v3, 4vs4, 10x10...)
    $team = 0
    if ($text -match '(?<!\d)(\d{1,2})\s*(?:vs|v|x)\s*\1(?!\d)') { $team = [int]$Matches[1] }
    # Competitivo sin formato declarado: 4v4 (el resto de los lugares son para espectadores)
    if ($competitive -and $team -eq 0) { $team = 4 }
    $effMax = if ($team -gt 0) { [math]::Min($s.MaxPlayers, 2 * $team) } else { $s.MaxPlayers }
    if (-not $includeBig -and $effMax -gt 8) { return $null }

    $v = Get-Verdict $s $pl $p $team
    if (-not $v) { return $null }
    $h = [math]::Max($s.Players, @($pl).Count)
    # Grupo armado: 3 o 4 que entraron juntos (tamano de un equipo). 5+ juntos suele ser
    # una partida que arranco entera desde un lobby, eso no lo marcamos.
    $groups = Get-JoinGroups $pl
    $teamSize = if ($team -gt 0) { $team } else { [math]::Floor($s.MaxPlayers / 2) }
    $premade = if ($groups.Count -gt 0 -and $groups[0] -ge 3 -and $groups[0] -le $teamSize) { [int]$groups[0] } else { 0 }
    $hint = $v.Hint
    if ($premade) { $hint += " | grupo armado de $premade" }
    if ($idle) { $hint += ' | sin partida armada: esperan juntar gente (si se van, el server se reinicia)' }
    if ($friendsOnly) { $hint += ' | sin sala pública: probablemente de solo amigos' }
    if ($mutation) { $hint += ' | mutación u otro modo' }
    if ($effMax -gt 8) { $hint += " | server grande ($effMax)" }
    if ($hist.Contains($s.Addr)) { $hint += ' | de tu historial de Steam' }
    return [pscustomobject]@{
        Rank = $v.Rank; Estado = $v.Status; Ping = $s.Ping
        Jugadores = "$h/$effMax"; Nombre = $s.Name; Mapa = $s.Map
        Pista = $hint; Addr = $s.Addr
        Hint = $v.Hint; Valve = $isValve; Max = $effMax; Humans = $h
        Premade = $premade; FriendsOnly = $friendsOnly; Mutation = $mutation; Link = $lobbyLink
        Campaign = (Get-CampaignKey $s.Map); Config = $cfg; Competitive = $competitive; ZoneMod = $zoneMod; Team = $team; Idle = $idle
        Pending = $pending; OtherMode = $otherMode
    }
}

# Orden de la lista: seguros primero; dentro de cada grupo, los sin partida armada al final, después los
# grupos armados, y por ping
function Sort-ServerRows($rows) { return @($rows | Sort-Object Rank, { [int]$_.Idle }, { [int]($_.Premade -gt 0) }, Ping) }

# Busca servers versus con lugar. Va por tandas a medida que Steam da la lista: cada tanda se mide (ping),
# se miran sus jugadores y su config, y sus filas salen enseguida por $OnRows (la ventana las va mostrando).
# Al final se cruzan los oficiales con sus salas públicas y se devuelve la lista completa y definitiva.
# $Stats (opcional): se llena con cuántos servers hubo y por qué quedó afuera cada uno
function Find-Servers([int]$p, [int]$maxPing, [bool]$includeBig, [bool]$hideValve, [scriptblock]$OnStatus, [scriptblock]$OnRows, [hashtable]$Stats, [string[]]$Favorites = @(), [string]$Game = 'versus') {
    $stats = if ($null -ne $Stats) { $Stats } else { @{} }
    & $OnStatus 'Pidiendo la lista de servidores a Steam...'
    # Lo que más tarda (salas de los oficiales y servers que se hacen pasar por oficiales) arranca ya, en paralelo
    $offHelpers = @(); $fakeHelper = $null
    try { $offHelpers = @(Start-OfficialGamesHelpers $here) } catch {}
    try { $fakeHelper = Start-LobbyHelper $here '-Servers -ServerFilter "gamedir=left4dead2,gametagsand=official"' } catch {}
    # Espera por tanda segun el ping maximo: hacen falta 2 idas y vueltas (desafio + respuesta).
    # Lo que conteste mas tarde igual quedaria afuera por ping.
    $wait = [math]::Min(900, 2 * $maxPing + 250)

    $listed = New-Object 'System.Collections.Generic.HashSet[string]'
    $answered = New-Object 'System.Collections.Generic.HashSet[string]'
    $hist = New-Object 'System.Collections.Generic.HashSet[string]'
    $allInfos = New-Object System.Collections.ArrayList
    $near = New-Object System.Collections.ArrayList
    $players = @{}; $rules = @{}
    $queue = New-Object 'System.Collections.Generic.List[string]'
    # Favoritos del usuario: se miden siempre (aunque Steam no los liste) y no se descartan por ping ni tamaño
    $favSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($a in @($Favorites)) { if ($a) { [void]$favSet.Add([string]$a) } }
    $favMore = @()

    # Verificación de los oficiales, apenas se puede (no al final de todo): en cuanto llegan las salas
    # públicas y la lista de servers que se hacen pasar por oficiales, cada tanda nueva sale ya verificada
    # y los oficiales que estaban "Verificando..." se mandan de nuevo con su estado.
    # Lobbies: salas oficiales ($null = todavía no llegaron). Fakes: addr -> info de los falsos.
    # Sent: addr -> lo último que se mandó de cada oficial (para mandar solo los que cambian).
    $off = @{ Lobbies = $null; FakesIn = -not $fakeHelper; Failed = ($offHelpers.Count -eq 0); Match = $null; Fakes = @{}; Sent = @{} }
    $noteFakes = { param($infos) foreach ($i in $infos) { if (",$($i.Tags)," -match ',official,' -and $i.Name -notlike 'Valve Left4Dead 2*') { $off.Fakes[$i.Addr] = $i } } }
    # Junta lo que haya llegado. Sin $block no espera a nadie (se llama entre tanda y tanda).
    $collect = {
        param([bool]$block)
        # Los falsos que también están en la lista de versus se miden con su tanda (y se anotan ahí); acá
        # solo los que no, que son pocos: así no se traba la búsqueda midiéndolos dos veces.
        if (-not $off.FakesIn -and ($block -or $fakeHelper.Proc.HasExited)) {
            $off.FakesIn = $true
            try {
                $fakeAddrs = @(((Receive-LobbyHelper $fakeHelper) | ConvertFrom-Json) | ForEach-Object { [string]$_ } | Where-Object { $_ -and -not $off.Fakes.ContainsKey($_) -and -not $listed.Contains($_) })
                if ($fakeAddrs.Count) { & $noteFakes @(Invoke-InfoScan $fakeAddrs 40 ([math]::Max(900, $wait))) }
            } catch {}
        }
        if ($null -eq $off.Lobbies -and -not $off.Failed -and ($block -or -not @($offHelpers | Where-Object { -not $_.Proc.HasExited }).Count)) {
            try { $off.Lobbies = @(Receive-OfficialGames $offHelpers) } catch { $off.Failed = $true }
        }
    }
    $offReady = { $null -ne $off.Lobbies -and $off.FakesIn }
    $offPending = { -not $off.Failed -and -not (& $offReady) }
    # Rehace el cruce con todos los oficiales vistos hasta ahora y devuelve las filas de los que cambiaron
    # ($skip: los de la tanda en curso, que salen con las demás filas de esa tanda)
    $refreshValve = {
        param($skip)
        if (-not (& $offReady)) { return }
        $fakeList = @($off.Fakes.Values | Where-Object { $_.Players -gt 0 } | ForEach-Object { [pscustomobject]@{ Addr = $_.Addr; Map = $_.Map; Humans = $_.Players } })
        $valve = @($near | Where-Object { $_.Name -like 'Valve Left4Dead 2*' })
        $valveNear = @($valve | ForEach-Object {
                $n = if ($players.ContainsKey($_.Addr)) { @($players[$_.Addr]).Count } else { 0 }
                [pscustomobject]@{ Addr = $_.Addr; Map = $_.Map; Ping = $_.Ping; Humans = [math]::Max($_.Players, $n) } })
        try { $off.Match = Get-OfficialLobbyMatch $valveNear $off.Lobbies $fakeList $off.Match $Game } catch { $off.Failed = $true; $off.Match = $null; return }
        foreach ($s in $valve) {
            if (-not $off.Sent.ContainsKey($s.Addr) -or ($skip -and $skip.Contains($s.Addr))) { continue }
            $m = $off.Match[$s.Addr]
            $sig = if ($m) { "$($m.Lobby)|$($m.Mode)" } else { 'none' }
            if ($off.Sent[$s.Addr] -eq $sig) { continue }
            $off.Sent[$s.Addr] = $sig
            $plS = if ($players.ContainsKey($s.Addr)) { $players[$s.Addr] } else { @() }
            ConvertTo-ServerRow $s $plS $rules $off.Match $false $hist $p ($includeBig -or $favSet.Contains($s.Addr)) $Game
        }
    }
    $signOf = { param($addr) if (& $offPending) { 'pending' } elseif ($null -eq $off.Match) { 'nomatch' } elseif ($off.Match[$addr]) { "$($off.Match[$addr].Lobby)|$($off.Match[$addr].Mode)" } else { 'none' } }
    # Entre tandas: si recién llegaron las salas, actualizar los oficiales que ya están en la ventana
    $tickOfficial = {
        if (& $offReady) { return }
        & $collect $false
        if (& $offReady) {
            $changed = @(& $refreshValve $null | Where-Object { $_ })
            if ($OnRows -and $changed.Count) { & $OnRows $changed }
        }
    }

    # Una tanda: ping + datos; las cercanas con lugar, jugadores y config; y sus filas a la ventana
    $doChunk = {
        param([string[]]$addrs, [int]$waitMs)
        $infos = @(Invoke-InfoScan $addrs 40 $waitMs)
        foreach ($i in $infos) { [void]$answered.Add($i.Addr); [void]$allInfos.Add($i) }
        & $noteFakes $infos
        # Cada server que queda afuera se cuenta por su motivo (la ventana explica por qué hay pocos)
        $nearNow = @(foreach ($i in $infos) {
                $why = if ($hist.Contains($i.Addr) -and $i.AppId -ne 550) { 'otro' }
                elseif (-not (Test-GameServer "$($i.Tags)" "$($i.Name)" $Game)) { 'otro' }
                elseif ($i.Password -ne 0) { 'clave' }
                elseif ($i.Players -le 0) { 'vacio' }
                elseif ($i.Ping -gt $maxPing -and -not $favSet.Contains($i.Addr)) { 'ping' }
                elseif (($i.MaxPlayers - $i.Players) -lt $p) { 'lugar' }
                elseif (-not ($includeBig -or $i.MaxPlayers -le 8 -or $i.Tags -match 'confogl' -or $favSet.Contains($i.Addr))) { 'grande' }
                else { '' }
                if ($why) { $stats[$why] = 1 + [int]$stats[$why] } else { $i }
            })
        if (-not $nearNow.Count) { return }
        $pl = Invoke-PlayerScan @($nearNow | ForEach-Object { $_.Addr }) ([math]::Max(700, $waitMs))
        foreach ($k in $pl.Keys) { $players[$k] = $pl[$k] }
        $comp = @($nearNow | Where-Object { $_.Tags -match 'confogl' } | ForEach-Object { $_.Addr })
        if ($comp.Count) { $r = Invoke-RulesScan $comp 1500; foreach ($k in $r.Keys) { $rules[$k] = $r[$k] } }
        foreach ($s in $nearNow) { [void]$near.Add($s) }
        # Si ya están las salas, el cruce se rehace con estos oficiales incluidos (y cambia el de alguno anterior)
        & $collect $false
        $now = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($s in $nearNow) { [void]$now.Add($s.Addr) }
        $changed = @(& $refreshValve $now | Where-Object { $_ })
        $pend = & $offPending
        $rowsNow = @(foreach ($s in $nearNow) {
                $plS = if ($players.ContainsKey($s.Addr)) { $players[$s.Addr] } else { @() }
                $row = ConvertTo-ServerRow $s $plS $rules $off.Match $pend $hist $p ($includeBig -or $favSet.Contains($s.Addr)) $Game
                if ($row) {
                    if ($row.Valve) { $off.Sent[$s.Addr] = & $signOf $s.Addr }
                    $row
                } else { $stats['lugar'] = 1 + [int]$stats['lugar'] }   # sin lugar en un equipo (o grande por su formato)
            })
        $rowsNow = @($changed) + @($rowsNow)
        if ($OnRows -and $rowsNow.Count) { & $OnRows $rowsNow }
    }

    # 1) Lista del cliente de Steam (sin key), una dirección por línea apenas llega: se mide mientras tanto
    # Steam da esta lista una sola vez cada ~30 s por cuenta (si se pide antes responde vacía):
    # se guarda la última buena y se usa para completar. El ping y los jugadores se miden igual en vivo.
    $cacheFile = Join-Path $here ('servidores-{0}.txt' -f $(if ($Game -eq 'scavenge') { 'busqueda' } else { 'versus' }))
    $cached = @()
    try {
        if ((Test-Path $cacheFile) -and ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalMinutes -lt 60) {
            $cached = @(Get-Content $cacheFile | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}:\d+$' })
        }
    } catch {}
    $clientError = $null
    $listT0 = Get-Date
    for ($listTry = 0; ; $listTry++) {
    $sh = $null
    try { $sh = Start-LobbyHelper $here ('-Servers -StreamList' + $(if ($Game -eq 'scavenge') { ' -ServerFilter "gamedir=left4dead2,empty=1,notfull=1,gametagsand=scavenge"' } else { '' })) -Stream } catch { $clientError = $_.Exception.Message }
    if ($sh) {
        $reader = $sh.Proc.StandardOutput
        $task = $reader.ReadLineAsync()
        $ended = $false
        $deadline = (Get-Date).AddSeconds(25)
        while ($true) {
            while (-not $ended -and $task.IsCompleted) {
                $line = $task.Result
                if ($null -eq $line -or $line -eq 'END') { $ended = $true; break }
                if ($line -like 'ERROR:*') { $clientError = $line.Substring(6).Trim(); $ended = $true; break }
                if ($line -match '^\d{1,3}(\.\d{1,3}){3}:\d+$' -and $listed.Add($line)) { $queue.Add($line) }
                $task = $reader.ReadLineAsync()
            }
            if ($queue.Count -ge 40 -or ($ended -and $queue.Count)) {
                $n = [math]::Min(40, $queue.Count)
                $chunk = $queue.GetRange(0, $n).ToArray(); $queue.RemoveRange(0, $n)
                & $OnStatus "Midiendo ping de servers versus con lugar... ($($answered.Count) contestaron de $($listed.Count))"
                & $doChunk $chunk $wait
                continue
            }
            if ($ended) { break }
            if ((Get-Date) -gt $deadline) { $clientError = 'Steam tardó demasiado en dar la lista de servidores.'; break }
            & $tickOfficial
            Start-Sleep -Milliseconds 30
        }
        try { if (-not $sh.Proc.HasExited) { $sh.Proc.Kill() } } catch {}
    }
    # Vino algo, o hay lista guardada para completar, o Steam no está (error real): seguir
    if ($listed.Count -or $cached.Count -or (Test-Path $keyFile) -or -not $sh -or ($clientError -and $clientError -notlike 'Steam tardó*')) { break }
    if (((Get-Date) - $listT0).TotalSeconds -gt 35) { break }
    & $OnStatus 'Steam está ocupado con la lista de servidores, reintentando...'
    $until = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $until) { & $tickOfficial; Start-Sleep -Milliseconds 100 }
    }
    $clientShort = $listed.Count -eq 0 -or $listed.Count -lt $cached.Count / 2
    $hasKey = Test-Path $keyFile
    if (-not $clientShort) {
        try { [IO.File]::WriteAllLines($cacheFile, [string[]]@($listed)) } catch {}
    } elseif ($cached.Count -and -not $hasKey) {
        # Steam respondió vacío o cortado: los de la última lista buena también se miden
        $extra = @($cached | Where-Object { $listed.Add($_) })
        for ($i = 0; $i -lt $extra.Count; $i += 40) {
            & $OnStatus "Midiendo ping de servers versus con lugar... ($($answered.Count) contestaron de $($listed.Count))"
            & $doChunk @($extra[$i..([math]::Min($i + 40, $extra.Count) - 1)]) $wait
        }
    }

    # 2) Si el cliente no dio nada (o vino cortado) y hay API key, la Web API completa la lista
    if ($listed.Count -eq 0 -or ($clientShort -and $hasKey)) {
        if (-not $hasKey) { throw "No pude pedirle la lista de servidores a Steam: $clientError" }
        $key = (Get-Content $keyFile -Raw).Trim()
        $url = "https://api.steampowered.com/IGameServersService/GetServerList/v1/?key=$key&limit=5000&filter=" + [uri]::EscapeDataString('\appid\550\empty\1\notfull\1')
        $srvList = @((Invoke-RestMethod -Uri $url -TimeoutSec 20).response.servers)
        # Solo los que el cliente no dio (esos ya se están midiendo)
        $srvList = @($srvList | Where-Object { $listed.Add([string]$_.addr) })
        $pre = @($srvList | Where-Object {
                (Test-GameServer "$($_.gametype)" "$($_.name)" $Game) -and ($_.max_players - $_.players) -ge $p -and
                # Los competitivos declaran 14-30 lugares para espectadores: el tamano real se mira despues
                ($includeBig -or $_.max_players -le 8 -or $_.gametype -match 'confogl') -and
                -not ($hideValve -and $_.name -like 'Valve Left4Dead 2*')
            } | ForEach-Object { [string]$_.addr })
        for ($i = 0; $i -lt $pre.Count; $i += 40) {
            & $OnStatus "Midiendo ping de $($pre.Count) servers versus con lugar..."
            & $doChunk @($pre[$i..([math]::Min($i + 40, $pre.Count) - 1)]) $wait
        }
    }

    # 3) Historial y favoritos de Steam (lo que no estaba en la lista pública)
    foreach ($a in (Get-HistoryServers)) { if (-not $listed.Contains($a)) { [void]$hist.Add($a) } }
    if ($hist.Count) { & $doChunk @($hist) $wait }
    # Favoritos que no vinieron en la lista de Steam ni en el historial
    $favMore = @($favSet | Where-Object { -not $listed.Contains($_) -and -not $hist.Contains($_) })
    if ($favMore.Count) { & $doChunk $favMore $wait }
    & $tickOfficial

    # 4) Reintento con mas espera para los que no contestaron (paquetes perdidos o servers lentos)
    $retry = @(@($listed) + @($hist) + @($favMore) | Where-Object { -not $answered.Contains($_) })
    if ($retry.Count) {
        & $OnStatus "Reintentando $($retry.Count) servers que no contestaron..."
        & $doChunk $retry ([math]::Min(1500, 2 * $wait))
    }

    # 4b) Los que quedaron en la lista se vuelven a medir: los primeros se midieron hace 10-15 s y en ese
    #     rato una partida puede llenarse (pasó de entrar a servers que ya estaban llenos). Solo cuenta la
    #     gente: el ping queda el de la primera medida (todos juntos de una no sirve para medir ping).
    #     Los que ya no tienen lugar o se vaciaron se sacan; los que no contestan quedan como estaban.
    if ($near.Count) {
        & $OnStatus 'Revisando si siguen teniendo lugar...'
        $fresh = @{}
        foreach ($i in @(Invoke-InfoScan @($near | ForEach-Object { $_.Addr }) 400 ([math]::Max(700, $wait)))) { $fresh[$i.Addr] = $i }
        $plNow = if ($fresh.Count) { Invoke-PlayerScan @($fresh.Keys) ([math]::Max(700, $wait)) } else { @{} }
        $kept = foreach ($s in @($near)) {
            $f = $fresh[$s.Addr]
            if (-not $f) { $s; continue }
            $f.Ping = $s.Ping
            if ($plNow.ContainsKey($s.Addr)) { $players[$s.Addr] = $plNow[$s.Addr] }
            $n = if ($players.ContainsKey($s.Addr)) { [math]::Max($f.Players, @($players[$s.Addr]).Count) } else { $f.Players }
            if ($f.Players -le 0) { $stats['vacio'] = 1 + [int]$stats['vacio'] }
            elseif (($f.MaxPlayers - $n) -lt $p) { $stats['lugar'] = 1 + [int]$stats['lugar'] }
            else { $f }
        }
        $near.Clear()
        foreach ($s in @($kept)) { [void]$near.Add($s) }
    }

    # 5) Oficiales de Valve: cual tiene sala publica (y de que modo). Si Steam no contesta, no se marca nada.
    #    Casi siempre ya quedó resuelto durante la búsqueda; si no, se espera acá lo que falte.
    if ($off.Failed -and $fakeHelper -and -not $off.FakesIn) { try { $fakeHelper.Proc.Kill() } catch {}; $off.FakesIn = $true }
    if (-not (& $offReady) -and -not $off.Failed) {
        & $OnStatus 'Revisando cuáles partidas oficiales son públicas...'
        & $collect $true
    }
    [void](& $refreshValve $null)   # con todo lo que contestó (también los del reintento)
    $offMatch = if ($off.Failed) { $null } else { $off.Match }

    # 6) Lista definitiva (los oficiales ya con su sala, o marcados como de solo amigos)
    $rows = foreach ($s in $near) {
        $pl = if ($players.ContainsKey($s.Addr)) { $players[$s.Addr] } else { @() }
        ConvertTo-ServerRow $s $pl $rules $offMatch $false $hist $p ($includeBig -or $favSet.Contains($s.Addr)) $Game
    }
    # Lo que no es del modo buscado no va (versus realista / supervivencia: oficiales con sala de otro modo)
    $other = @($rows | Where-Object { $_ -and $_.OtherMode }).Count
    if ($other) { $stats['otro'] = $other + [int]$stats['otro'] }
    $rows = Sort-ServerRows @($rows | Where-Object { $_ -and -not $_.OtherMode })
    $stats['listados'] = $listed.Count + $hist.Count
    $stats['contestaron'] = $answered.Count
    $stats['maxping'] = $maxPing
    & $OnStatus ("Listo: {0} servers ({1} seguros). {2:HH:mm}" -f $rows.Count, @($rows | Where-Object { $_.Rank -eq 0 }).Count, (Get-Date))
    return $rows
}
# <<< BUSQUEDA

# ======================= modo grupo (avisos por ntfy.sh) =======================
# Solo viaja la IP del server elegido, tu nombre y un id al azar de esta instalacion.
# El canal se deriva del codigo de grupo con un hash, asi el codigo no queda a la vista.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$settingsFile = Join-Path $here 'settings.json'

function Get-Settings {
    $s = [ordered]@{ Name = $env:USERNAME; Group = ''; Party = 2; MaxPing = 150; Follow = $false; AutoRefresh = $false; Campaigns = @(); ServerType = ''; LobbyType = ''; ModeFilter = $null; HostFilter = $null; IncludeFriendsOnly = $false; IncludeMutations = $false; PreferIdeal = $false; FollowKey = 'F5'; View = 'servers'; FollowSteamId = ''; SteamFollow = $false; Share = $true; Favorites = @(); Game = 'versus'; UseApiKey = $true; ClientId = [guid]::NewGuid().ToString('N') }
    if (Test-Path $settingsFile) {
        try {
            $saved = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $saved.PSObject.Properties) { if ($s.Contains($prop.Name)) { $s[$prop.Name] = $prop.Value } }
        } catch {}
    }
    return $s
}

function Save-Settings($s) {
    try { [IO.File]::WriteAllText($settingsFile, ($s | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch {}
}

function Get-Topic([string]$code) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($code.Trim().ToLower()))
    return 'l4d2vs-' + (($hash[0..11] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ======================= seguir a un amigo por Steam =======================
# El que juega (con API key) le pregunta a Steam en que server/lobby esta y lo "transmite"
# por ntfy.sh en un canal derivado de su SteamID. Los amigos solo escuchan: no necesitan key.
# Lo transmitido: nombre de Steam, si esta jugando, IP del server y id del lobby.

function Get-MySteamId {
    $acc = (Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue).ActiveUser
    if ($acc -and [int64]$acc -ne 0) { return [string](76561197960265728 + [int64]$acc) }
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $vdf = if ($steam) { Join-Path $steam 'config\loginusers.vdf' } else { $null }
    if ($vdf -and (Test-Path $vdf)) {
        $text = Get-Content $vdf -Raw
        $m = [regex]::Match($text, '"(7656\d{13})"\s*\{[^}]*"MostRecent"\s*"1"')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function Get-ApiKey {
    if (Test-Path $keyFile) { return (Get-Content $keyFile -Raw).Trim() }
    return $null
}

# Amigos desde la config local de Steam (sin API): userdata\<cuenta>\config\localconfig.vdf, bloque "friends".
function Get-LocalFriends([string]$me) {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam -or -not $me) { return @() }
    $acc = [int64]$me - 76561197960265728
    $cfg = Join-Path $steam "userdata\$acc\config\localconfig.vdf"
    if (-not (Test-Path $cfg)) { return @() }
    $t = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
    $i = $t.IndexOf('"friends"')
    if ($i -lt 0) { return @() }
    $open = $t.IndexOf('{', $i)
    if ($open -lt 0) { return @() }
    # Buscar la llave que cierra el bloque, salteando el texto entre comillas
    $depth = 0; $end = -1
    for ($j = $open; $j -lt $t.Length; $j++) {
        $ch = $t[$j]
        if ($ch -eq '"') {
            $k = $j + 1
            while ($true) { $k = $t.IndexOf('"', $k); if ($k -lt 0 -or $t[$k - 1] -ne '\') { break }; $k++ }
            if ($k -lt 0) { break }
            $j = $k; continue
        }
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $j; break } }
    }
    if ($end -lt 0) { return @() }
    $block = $t.Substring($open + 1, $end - $open - 1)
    $out = foreach ($m in [regex]::Matches($block, '"(\d{1,10})"\s*\{((?:[^{}]|\{[^{}]*\})*)\}')) {
        $n = [regex]::Match($m.Groups[2].Value, '"name"\s*"((?:[^"\\]|\\.)*)"')
        if ($n.Success) {
            [pscustomobject]@{ SteamId = [string](76561197960265728 + [int64]$m.Groups[1].Value); Name = ($n.Groups[1].Value -replace '\\"', '"') }
        }
    }
    return @($out)
}

# Estado de varias cuentas por la Web API (max 100 por llamada). Devuelve hashtable steamid -> objeto.
function Get-SteamStatus([string]$key, [string[]]$ids) {
    $out = @{}
    for ($i = 0; $i -lt $ids.Count; $i += 100) {
        $chunk = $ids[$i..([math]::Min($i + 99, $ids.Count - 1))] -join ','
        $r = Invoke-RestMethod -TimeoutSec 10 -Uri "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=$key&steamids=$chunk"
        foreach ($p in $r.response.players) {
            $server = "$($p.gameserverip)"
            if ($server -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$' -or $server -like '0.0.0.0*') { $server = '' }
            $lobby = if ("$($p.lobbysteamid)" -match '^\d{15,20}$') { "$($p.lobbysteamid)" } else { '' }
            $out[$p.steamid] = [pscustomobject]@{
                SteamId = $p.steamid; Name = $p.personaname; Online = ($p.personastate -gt 0)
                InL4D2 = ("$($p.gameid)" -eq '550'); Server = $server; Lobby = $lobby
            }
        }
    }
    return $out
}

# Un solo canal compartido para todos (ntfy.sh limita cuantos canales distintos se consultan).
# Cada aviso lleva una huella (hash) del SteamID, no el SteamID: cada app reconoce a sus amigos.
$presenceTopic = Get-Topic 'steam-presence-v1'

function Get-SidHash([string]$sid) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("l4d2vs:$sid"))
    return (($hash[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# $join = lo eligió recién en la app (Unirme): los que lo siguen van enseguida, sin esperar a confirmarlo
function Send-SteamBroadcast([string]$me, [bool]$playing, [string]$server, [string]$lobby, [bool]$join = $false) {
    $msg = @{ h = (Get-SidHash $me); playing = $playing; server = $server; lobby = $lobby }
    if ($join) { $msg.join = 1 }
    $body = $msg | ConvertTo-Json -Compress
    [void](Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$presenceTopic" -TimeoutSec 8 `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'text/plain; charset=utf-8')
}

# Grupo: el que tilda "Seguirlo" avisa cada 30 s a quien sigue, en un canal aparte (asi las versiones
# viejas de la app no lo confunden con una transmision de partida). Solo viajan huellas: {h = yo, f = a quien sigo}.
$followTopic = Get-Topic 'steam-follow-v2'   # v2: avisos cada 4 min que valen 10 min (v1 era cada 30 s)

# Todas las apps avisan (con o sin grupo): asi tus amigos ven que tenes la app abierta y en que grupo estas.
# $Closed = se cerro la app (deja de figurar enseguida, sin esperar a que venza el aviso).
# $Go: el líder tocó Unirme ("lobby:<id>" o "connect:<ip:puerto>"): los que lo siguen entran al instante,
# sin esperar a que Steam les pase dónde está (1-3 s) ni la confirmación de 2 s. Vale también como aviso normal.
function Send-FollowSignal([string]$me, [string]$leader, [switch]$Closed, [string]$Go = '') {
    $fh = if ($leader) { Get-SidHash $leader } else { '' }
    $msg = @{ h = (Get-SidHash $me); f = $fh }
    if ($Closed) { $msg.c = 1 }
    if ($Go) { $msg.go = $Go }
    $body = $msg | ConvertTo-Json -Compress
    [void](Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$followTopic" -TimeoutSec 5 `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'text/plain; charset=utf-8')
}

# Trae los avisos de los dos canales en UN solo pedido (ntfy limita la cantidad de pedidos)
function Receive-NtfyMessages([string]$since = '3m') {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri "https://ntfy.sh/$followTopic/json?poll=1&since=$since"
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $out = foreach ($line in ($text -split "`n")) {
        if (-not $line.Trim()) { continue }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ($m.event -ne 'message') { continue }
        try { $d = $m.message | ConvertFrom-Json } catch { continue }
        [pscustomobject]@{ Topic = [string]$m.topic; Time = [long]$m.time; Data = $d }
    }
    return @($out)
}

# Huellas de los que siguen a $leader ahora (su ultimo aviso, de hace menos de 75 s, apunta a el)
function Get-GroupHashes([string]$leader, $msgs) {
    $lh = Get-SidHash $leader
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $last = @{}
    foreach ($m in $msgs) {
        if ($m.Topic -ne $followTopic) { continue }
        $h = "$($m.Data.h)"
        if ($h -notmatch '^[0-9a-f]{16}$') { continue }
        if (-not $last.ContainsKey($h) -or $m.Time -ge $last[$h].Time) { $last[$h] = $m }
    }
    return @($last.Keys | Where-Object { "$($last[$_].Data.f)" -eq $lh -and ($now - $last[$_].Time) -le 600 -and $_ -ne $lh })
}

# Ultimo aviso vigente de cada app: huella -> huella de a quien sigue ('' = a nadie: es lider o esta solo).
# Las apps cerradas o con el aviso vencido (20 min: cada app avisa cada 9) no figuran.
function Get-PartyMap($msgs, [int]$validity = 1200) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $last = @{}
    foreach ($m in $msgs) {
        if ($m.Topic -ne $followTopic) { continue }
        $h = "$($m.Data.h)"
        if ($h -notmatch '^[0-9a-f]{16}$') { continue }
        if (-not $last.ContainsKey($h) -or $m.Time -ge $last[$h].Time) { $last[$h] = $m }
    }
    $map = @{}
    foreach ($h in $last.Keys) {
        $m = $last[$h]
        if (($now - $m.Time) -gt $validity -or "$($m.Data.c)" -eq '1') { continue }
        $map[$h] = "$($m.Data.f)"
    }
    return $map
}

# Lider final de una huella siguiendo la cadena (A sigue a B que sigue a C -> C). Si hay un ciclo, la menor.
function Get-PartyRoot([string]$h, $map) {
    $seen = New-Object 'System.Collections.Generic.List[string]'
    $cur = $h
    while ($cur -and $map.ContainsKey($cur) -and $map[$cur] -and -not $seen.Contains($cur)) { $seen.Add($cur); $cur = $map[$cur] }
    if ($seen.Contains($cur)) { return ($seen | Sort-Object | Select-Object -First 1) }
    return $cur
}

# Avatares desde el perfil publico de Steam (no hace falta API key). Devuelve steamid -> bytes de la imagen.
function Get-SteamAvatars([string[]]$sids) {
    $out = @{}
    foreach ($s in $sids) {
        try {
            $x = Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 -Uri "https://steamcommunity.com/profiles/$s/?xml=1"
            $m = [regex]::Match($x.Content, '<avatarMedium><!\[CDATA\[(https://[^\]]+)\]\]>')
            if ($m.Success) { $out[$s] = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 -Uri $m.Groups[1].Value).Content }
        } catch {}
    }
    return $out
}

# Ultima transmision de cada amigo (de los ultimos $since). Devuelve hashtable steamid -> objeto.
# Si ya se trajeron los avisos ($msgs, de Receive-NtfyMessages) no vuelve a pedirlos.
function Receive-SteamBroadcasts([string[]]$sids, [string]$since = '3m', $msgs = $null) {
    $map = @{}
    foreach ($s in $sids) { $map[(Get-SidHash $s)] = $s }
    $latest = @{}
    if ($null -eq $msgs) { $msgs = Receive-NtfyMessages $since }
    foreach ($msg in $msgs) {
        if ($msg.Topic -ne $presenceTopic) { continue }
        $m = [pscustomobject]@{ time = $msg.Time }
        $d = $msg.Data
        $sid = $map["$($d.h)"]
        if (-not $sid) { continue }
        # Solo aceptamos IP:puerto y un id de lobby numerico, nada de otros comandos steam://
        $server = if ("$($d.server)" -match '^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$') { "$($d.server)" } else { '' }
        $lobby = if ("$($d.lobby)" -match '^\d{15,20}$') { "$($d.lobby)" } else { '' }
        $obj = [pscustomobject]@{ SteamId = $sid; Name = ''; Playing = [bool]$d.playing; Server = $server; Lobby = $lobby; Time = [long]$m.time; Join = ("$($d.join)" -eq '1') }
        if (-not $latest.ContainsKey($sid) -or $obj.Time -ge $latest[$sid].Time) { $latest[$sid] = $obj }
    }
    return $latest
}

if ($TestSteam) {
    $me = Get-MySteamId
    Write-Host "Mi SteamID: $(if ($me) { 'detectado' } else { 'NO detectado' })"
    $friends = Get-LocalFriends $me
    Write-Host "Amigos en la config local de Steam: $($friends.Count)"
    $key = Get-ApiKey
    if ($key) {
        $mine = (Get-SteamStatus $key @($me))[$me]
        Write-Host "Mi estado por la API: jugandoL4D2=$($mine.InL4D2) server='$($mine.Server)' lobby=$(if ($mine.Lobby) { 'si' } else { 'no' })"
        Send-SteamBroadcast $me $mine.InL4D2 $mine.Server $mine.Lobby
        Start-Sleep -Seconds 2
        $b = (Receive-SteamBroadcasts @($me) '1m')[$me]
        Write-Host "Transmision de prueba recibida: $(if ($b) { "si (jugando=$($b.Playing), server='$($b.Server)', lobby=$(if ($b.Lobby) { 'si' } else { 'no' }))" } else { 'NO' })"
    } else { Write-Host 'Sin API key: este equipo solo puede seguir, no transmitir.' }
    if ($friends.Count) {
        $live = Receive-SteamBroadcasts @($friends | ForEach-Object { $_.SteamId }) '3m'
        Write-Host "Amigos transmitiendo ahora: $($live.Count)"
    }
    return
}

if ($TestGroup) {
    $me = Get-MySteamId
    $fake = '76561197960265729'   # lider inventado, para no aparecer en el grupo de nadie real
    Send-FollowSignal $me $fake
    Start-Sleep -Seconds 2
    $msgs = Receive-NtfyMessages '1m'
    $g = Get-GroupHashes $fake $msgs
    Write-Host "Avisos traidos: $($msgs.Count) (presencia: $(@($msgs | ? Topic -eq $presenceTopic).Count), grupo: $(@($msgs | ? Topic -eq $followTopic).Count))"
    Write-Host "Me veo en el grupo de prueba: $(@($g) -contains (Get-SidHash $me))"
    Send-FollowSignal $me ''
    Start-Sleep -Seconds 2
    Write-Host "Despues de salir: $(@(Get-GroupHashes $fake (Receive-NtfyMessages '1m')) -contains (Get-SidHash $me))"
    $av = Get-SteamAvatars @($me)
    Write-Host "Avatar propio: $(if ($av[$me]) { "$($av[$me].Length) bytes" } else { 'no' })"
    return
}

if ($Audit) {
    # Diagnostico: que servers versus quedan afuera de la busqueda y por que (sin filtro de ping)
    $key = (Get-Content $keyFile -Raw).Trim()
    $url = "https://api.steampowered.com/IGameServersService/GetServerList/v1/?key=$key&limit=5000&filter=" + [uri]::EscapeDataString('\appid\550\empty\1\notfull\1')
    $list = @((Invoke-RestMethod -Uri $url -TimeoutSec 30).response.servers)
    $vs = @($list | Where-Object { $_.gametype -match 'versus' })
    $infos = @(Invoke-InfoScan @($vs | ForEach-Object { $_.addr }))
    $got = @{}; foreach ($i in $infos) { $got[$i.Addr] = $i }
    $silent = @($vs | Where-Object { -not $got.ContainsKey(($_.addr -replace '^([^:]+):', '$1:')) })
    Write-Host "Versus en la lista: $($vs.Count)  respondieron al ping: $($infos.Count)  no respondieron: $($vs.Count - $infos.Count)"
    Write-Host "Ping de los que respondieron:"
    $infos | Group-Object { if ($_.Ping -le 100) { 'a) <=100' } elseif ($_.Ping -le 150) { 'b) 101-150' } elseif ($_.Ping -le 200) { 'c) 151-200' } else { 'd) >200' } } | Sort-Object Name | ForEach-Object { Write-Host "   $($_.Name): $($_.Count)" }
    $cust = @($infos | Where-Object { $_.Map -notmatch '^c\d+m\d+_' })
    Write-Host "En mapa custom: $($cust.Count)  (ping <=150: $(@($cust | ? Ping -le 150).Count))"
    $cust | Sort-Object Ping | Format-Table Ping, Players, MaxPlayers, Map, Name -AutoSize | Out-String -Width 220 | Write-Host
    $comp = @($infos | Where-Object { $_.Tags -match 'confogl' })
    Write-Host "Competitivos: $($comp.Count)  (ping <=150: $(@($comp | ? Ping -le 150).Count))"
    $comp | Where-Object Ping -le 200 | Sort-Object Ping | Format-Table Ping, Players, MaxPlayers, Map, Name -AutoSize | Out-String -Width 220 | Write-Host
    # Servers sin ninguna etiqueta: preguntarles el modo de juego
    $untagged = @($list | Where-Object { -not $_.gametype })
    $modes = Invoke-RulesScan @($untagged | ForEach-Object { $_.addr }) 2500 'mp_gamemode'
    Write-Host "Sin etiquetas: $($untagged.Count)  respondieron reglas: $($modes.Count)"
    $modes.GetEnumerator() | Group-Object { if ($_.Value) { $_.Value } else { '(no dice)' } } | ForEach-Object { Write-Host "   $($_.Name): $($_.Count)" }
    foreach ($u in $untagged) { $m = $modes[$u.addr]; if ($m -match 'versus') { Write-Host "   VERSUS sin etiqueta: $($u.name) | $($u.map) | $($u.players)/$($u.max_players)" } }
    return
}

if ($TestRules) {
    $r = Invoke-RulesScan @($TestRules -split ',')
    foreach ($a in ($TestRules -split ',')) {
        $cfg = if ($r.ContainsKey($a)) { "'$($r[$a])'" } else { '(sin respuesta)' }
        Write-Host "$a -> $cfg"
    }
    return
}

# ======================= modo consola =======================
if ($Console -and $Lobbies) {
    . (Join-Path $here 'vpk.ps1')
    $rows = ConvertTo-LobbyRows (Get-LobbyJson $Party $here) $Party $HideValve.IsPresent
    $rows | Format-Table Estado, Jugadores, Near, Title, Nombre, Custom, Link -AutoSize | Out-String -Width 300 | Write-Host
    return
}
if ($Console) {
    $rows = Find-Servers $Party $MaxPing $IncludeBig.IsPresent $HideValve.IsPresent { param($m) Write-Host $m -ForegroundColor Cyan }
    $rows | Format-Table Estado, Ping, Jugadores, Campaign, Config, Nombre, Mapa, Pista, Addr -AutoSize | Out-String -Width 300 | Write-Host
    return
}

# ======================= ventana =======================
. (Join-Path $here 'ui.ps1')

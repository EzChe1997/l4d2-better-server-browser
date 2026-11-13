# lobbies.ps1 - pide a Steam la lista de salas de espera (lobbies) publicas de L4D2.
# La Web API de Steam no lista lobbies: solo se puede desde un programa conectado al cliente de
# Steam como si fuera el juego. Para eso usa el steam_api.dll del propio L4D2 (32 bits), asi que
# corre con el PowerShell de 32 bits (finder.ps1 lo lanza solo):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File lobbies.ps1 -Dll <ruta> -Filter 'Game:mode=versus,Game:state=lobby'
# Salida: JSON por stdout, una lista de lobbies con todos sus datos (+ _id, _members, _limit, _owner, _near).
param(
    [Parameter(Mandatory)][string]$Dll,
    [string[]]$Filter = @(),
    [int]$Slots = 1,
    [string]$Distance = '1,3',   # 1 = region cercana, 2 = lejos, 3 = todo el mundo (en orden)
    [string]$AppId = '550',
    [string[]]$ExtraFilter = @(),   # un pedido mas, mundial y sin minimo de lugares (p. ej. salas custom)
    # Varios pedidos sueltos en una sola corrida: "distancia|lugares|k=v,k=v;distancia|lugares|k=v..."
    # (reemplaza a Filter/Slots/Distance/ExtraFilter). Cada lobby trae _pass con el numero de pedido.
    [string]$Passes = '',
    [switch]$Dump,
    [switch]$Watch,          # modo vigia (ver abajo)
    [switch]$Servers,        # lista de servers de internet (ver abajo)
    [string]$ServerFilter = 'gamedir=left4dead2,empty=1,notfull=1,gametagsand=versus',
    [int]$ParentPid = 0
)

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 4) { throw 'Hay que correrlo con PowerShell de 32 bits' }
$env:SteamAppId = $AppId
$env:SteamGameId = $AppId

# -Watch: queda corriendo y cada 1 s mira en el cliente de Steam (sin internet ni API key) en que server
# y lobby de L4D2 estan tus amigos y vos. Escribe una linea JSON cuando algo cambia (y cada 10 s).
# Se cierra solo cuando se cierra el juego o la app que lo lanzo: mientras corre, Steam lo cuenta como
# parte de L4D2, asi que no tiene que quedar vivo sin el juego.
if ($Watch) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class L4dWatch {
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string p);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_Void();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Iface();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Count(IntPtr self, int flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_ByIndex(IntPtr self, int i, int flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Game(IntPtr self, ulong id, IntPtr info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Name(IntPtr self, ulong id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_SteamId(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Pipe();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_PipeVoid(int pipe);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_NextCb(int pipe, IntPtr msg);
    static IntPtr h;
    static T F<T>(string n) where T : class {
        IntPtr p = GetProcAddress(h, n);
        if (p == IntPtr.Zero) throw new Exception("falta " + n + " en steam_api.dll");
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }
    static string Esc(string s) {
        var sb = new StringBuilder();
        foreach (char c in s) {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c < 32) sb.Append(' ');
            else if (c > 126) sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        return sb.ToString();
    }
    static string Utf8(IntPtr p) {
        if (p == IntPtr.Zero) return "";
        int len = 0; while (Marshal.ReadByte(p, len) != 0 && len < 512) len++;
        byte[] buf = new byte[len]; Marshal.Copy(p, buf, 0, len);
        return Encoding.UTF8.GetString(buf);
    }
    static bool Alive(int pid) {
        try { var p = Process.GetProcessById(pid); return !p.HasExited; } catch { return false; }
    }
    static bool GameRunning() { return Process.GetProcessesByName("left4dead2").Length > 0; }

    public static void Run(string dll, int parentPid) {
        h = LoadLibraryW(dll);
        if (h == IntPtr.Zero) throw new Exception("no pude cargar " + dll);
        // Avisos de Steam a mano (sin RunCallbacks): asi nos enteramos al instante cuando un amigo cambia
        // de juego, server o sala (PersonaStateChange_t), en vez de preguntar cada tanto.
        F<D_Void>("SteamAPI_ManualDispatch_Init")();
        if (!F<D_Init>("SteamAPI_Init")()) throw new Exception("No me pude conectar a Steam");
        var shutdown = F<D_Void>("SteamAPI_Shutdown");
        try {
            int pipe = F<D_Pipe>("SteamAPI_GetHSteamPipe")();
            var runFrame = F<D_PipeVoid>("SteamAPI_ManualDispatch_RunFrame");
            var nextCb = F<D_NextCb>("SteamAPI_ManualDispatch_GetNextCallback");
            var freeCb = F<D_PipeVoid>("SteamAPI_ManualDispatch_FreeLastCallback");
            IntPtr cbMsg = Marshal.AllocHGlobal(32);   // CallbackMsg_t { int user; int id; byte* param; int size }
            IntPtr fr = F<D_Iface>("SteamAPI_SteamFriends_v017")();
            IntPtr us = F<D_Iface>("SteamAPI_SteamUser_v021")();
            var count = F<D_Count>("SteamAPI_ISteamFriends_GetFriendCount");
            var byIdx = F<D_ByIndex>("SteamAPI_ISteamFriends_GetFriendByIndex");
            var game = F<D_Game>("SteamAPI_ISteamFriends_GetFriendGamePlayed");
            var name = F<D_Name>("SteamAPI_ISteamFriends_GetFriendPersonaName");
            ulong me = F<D_SteamId>("SteamAPI_ISteamUser_GetSteamID")(us);
            IntPtr info = Marshal.AllocHGlobal(32);
            // FriendGameInfo_t: uint64 gameId, uint32 ip, uint16 port, uint16 queryPort, uint64 lobby
            Func<ulong, string> where = (id) => {
                for (int k = 0; k < 32; k++) Marshal.WriteByte(info, k, 0);
                if (!game(fr, id, info)) return null;
                ulong gid = (ulong)Marshal.ReadInt64(info, 0);
                if ((gid & 0xFFFFFF) != 550) return null;
                uint ip = (uint)Marshal.ReadInt32(info, 8);
                int port = (ushort)Marshal.ReadInt16(info, 12);
                ulong lobby = (ulong)Marshal.ReadInt64(info, 16);
                string srv = ip == 0 ? "" : ((ip >> 24) & 255) + "." + ((ip >> 16) & 255) + "." + ((ip >> 8) & 255) + "." + (ip & 255) + ":" + port;
                return "\"server\":\"" + srv + "\",\"lobby\":\"" + (lobby == 0 ? "" : lobby.ToString()) + "\"";
            };
            string last = null;
            DateTime lastCheck = DateTime.MinValue, lastAlive = DateTime.MinValue, noGameSince = DateTime.MaxValue;
            while (true) {
                bool changed = false;
                runFrame(pipe);
                while (nextCb(pipe, cbMsg)) {
                    if (Marshal.ReadInt32(cbMsg, 4) == 304) changed = true;   // PersonaStateChange_t
                    freeCb(pipe);
                }
                // Por las dudas (avisos que Steam no manda, p. ej. algunos cambios de sala) se revisa igual cada 2 s
                if (!changed && (DateTime.Now - lastCheck).TotalMilliseconds < 2000) { System.Threading.Thread.Sleep(100); continue; }
                lastCheck = DateTime.Now;
                if ((DateTime.Now - lastAlive).TotalSeconds >= 1) {
                    lastAlive = DateTime.Now;
                    if (parentPid > 0 && !Alive(parentPid)) break;
                    if (GameRunning()) noGameSince = DateTime.MaxValue;
                    else if (noGameSince == DateTime.MaxValue) noGameSince = DateTime.Now;
                    else if ((DateTime.Now - noGameSince).TotalSeconds > 5) break;
                }
                var sb = new StringBuilder();
                string mine = where(me);
                sb.Append("{\"me\":{").Append(mine ?? "\"server\":\"\",\"lobby\":\"\"").Append(",\"playing\":").Append(mine != null ? "true" : "false").Append("},\"friends\":[");
                int n = count(fr, 4), added = 0;
                for (int i = 0; i < n; i++) {
                    ulong id = byIdx(fr, i, 4);
                    string w = where(id);
                    if (w == null) continue;
                    if (added++ > 0) sb.Append(',');
                    sb.Append("{\"id\":\"").Append(id).Append("\",\"name\":\"").Append(Esc(Utf8(name(fr, id)))).Append("\",").Append(w).Append('}');
                }
                sb.Append("]}");
                string line = sb.ToString();
                if (line != last) {   // solo cuando algo cambia
                    Console.Out.WriteLine(line); Console.Out.Flush();
                    last = line;
                }
            }
        } finally { shutdown(); }
    }
}
"@
    try { [L4dWatch]::Run($Dll, $ParentPid) } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        [Console]::Out.WriteLine("ERROR: $($e.Message)")
        exit 1
    }
    exit 0
}

# -Servers: la lista de servers de internet del juego (lo mismo que el navegador de servidores de L4D2),
# pedida al cliente de Steam: no necesita API key. Solo se usan las direcciones (Steam las da enseguida);
# el ping y los jugadores los mide finder.ps1. Salida: JSON con "ip:puerto_de_consulta".
if ($Servers) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class L4dServerList {
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string p);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_Void();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Iface();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Req(IntPtr self, uint app, IntPtr filters, uint n, IntPtr resp);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Count(IntPtr self, IntPtr req);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Details(IntPtr self, IntPtr req, int i);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_Req1(IntPtr self, IntPtr req);
    // ISteamMatchmakingServerListResponse: objeto C++ con 3 metodos virtuales (thiscall en 32 bits)
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate void D_Resp(IntPtr self, IntPtr req, int i);
    static IntPtr h;
    static D_Resp onOk, onFail, onDone;   // referencias vivas mientras Steam las pueda llamar
    static bool complete;
    static T F<T>(string n) where T : class {
        IntPtr p = GetProcAddress(h, n);
        if (p == IntPtr.Zero) throw new Exception("falta " + n + " en steam_api.dll");
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }
    public static List<string> Fetch(string dll, string filterSpec, int timeoutMs) {
        h = LoadLibraryW(dll);
        if (h == IntPtr.Zero) throw new Exception("no pude cargar " + dll);
        if (!F<D_Init>("SteamAPI_Init")()) throw new Exception("No me pude conectar a Steam: tiene que estar abierto y con tu cuenta iniciada.");
        var shutdown = F<D_Void>("SteamAPI_Shutdown");
        try {
            var run = F<D_Void>("SteamAPI_RunCallbacks");
            IntPtr mms = F<D_Iface>("SteamAPI_SteamMatchmakingServers_v002")();
            if (mms == IntPtr.Zero) throw new Exception("interfaz de servidores de Steam no disponible");
            var request = F<D_Req>("SteamAPI_ISteamMatchmakingServers_RequestInternetServerList");
            var count = F<D_Count>("SteamAPI_ISteamMatchmakingServers_GetServerCount");
            var details = F<D_Details>("SteamAPI_ISteamMatchmakingServers_GetServerDetails");
            var cancel = F<D_Req1>("SteamAPI_ISteamMatchmakingServers_CancelQuery");
            var release = F<D_Req1>("SteamAPI_ISteamMatchmakingServers_ReleaseRequest");

            onOk = (s, r, i) => { }; onFail = (s, r, i) => { }; onDone = (s, r, i) => { complete = true; };
            IntPtr vt = Marshal.AllocHGlobal(3 * IntPtr.Size);
            Marshal.WriteIntPtr(vt, 0, Marshal.GetFunctionPointerForDelegate(onOk));
            Marshal.WriteIntPtr(vt, IntPtr.Size, Marshal.GetFunctionPointerForDelegate(onFail));
            Marshal.WriteIntPtr(vt, 2 * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(onDone));
            IntPtr resp = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(resp, vt);

            // Filtros: MatchMakingKeyValuePair_t { char key[256]; char value[256]; } contiguos, y un puntero a ellos
            var pairs = new List<string[]>();
            foreach (var kv in filterSpec.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) {
                int eq = kv.IndexOf('=');
                if (eq > 0) pairs.Add(new[] { kv.Substring(0, eq), kv.Substring(eq + 1) });
            }
            IntPtr block = Marshal.AllocHGlobal(512 * Math.Max(1, pairs.Count));
            for (int z = 0; z < 512 * Math.Max(1, pairs.Count); z++) Marshal.WriteByte(block, z, 0);
            for (int k = 0; k < pairs.Count; k++) {
                byte[] a = Encoding.ASCII.GetBytes(pairs[k][0]); Marshal.Copy(a, 0, block + 512 * k, Math.Min(255, a.Length));
                byte[] v = Encoding.ASCII.GetBytes(pairs[k][1]); Marshal.Copy(v, 0, block + 512 * k + 256, Math.Min(255, v.Length));
            }
            IntPtr filters = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(filters, block);

            IntPtr req = request(mms, 550, filters, (uint)pairs.Count, resp);
            if (req == IntPtr.Zero) throw new Exception("Steam rechazo el pedido de servidores");
            // La lista de direcciones llega de una (a veces en tandas): esperar a que deje de crecer.
            // No hace falta que Steam termine de consultar cada server: eso lo hace finder.ps1 mas rapido.
            var t0 = DateTime.Now; var lastChange = DateTime.Now; int last = -1;
            while (true) {
                run();
                System.Threading.Thread.Sleep(100);
                int n = count(mms, req);
                if (n != last) { last = n; lastChange = DateTime.Now; }
                double el = (DateTime.Now - t0).TotalMilliseconds;
                if (complete) break;
                if (n > 0 && (DateTime.Now - lastChange).TotalMilliseconds > 1200) break;
                if (el > timeoutMs) break;
            }
            var list = new List<string>();
            var seen = new HashSet<string>();
            int total = count(mms, req);
            for (int i = 0; i < total; i++) {
                IntPtr p = details(mms, req, i);
                if (p == IntPtr.Zero) continue;
                // gameserveritem_t: servernetadr_t { uint16 puerto de juego; uint16 puerto de consulta; uint32 ip }
                int qport = (ushort)Marshal.ReadInt16(p, 2);
                uint ip = (uint)Marshal.ReadInt32(p, 4);
                if (ip == 0 || qport == 0) continue;
                string a = ((ip >> 24) & 255) + "." + ((ip >> 16) & 255) + "." + ((ip >> 8) & 255) + "." + (ip & 255) + ":" + qport;
                if (seen.Add(a)) list.Add(a);
            }
            cancel(mms, req);
            release(mms, req);
            return list;
        } finally { shutdown(); }
    }
}
"@
    try {
        $list = [L4dServerList]::Fetch($Dll, $ServerFilter, 12000)
        [Console]::Out.Write((ConvertTo-Json -InputObject @($list) -Compress))
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        [Console]::Out.Write("ERROR: $($e.Message)")
        exit 1
    }
    exit 0
}

if (-not ('L4dLobbies2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class L4dLobbies2 {
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string name);

    // Los bool de la API de Steam son de 1 byte: hay que marshallearlos como I1
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_Void();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Iface();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_Call(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_StrFilter(IntPtr self, string key, string val, int cmp);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_IntArg(IntPtr self, int v);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_IsDone(IntPtr self, ulong call, [MarshalAs(UnmanagedType.I1)] out bool failed);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Result(IntPtr self, ulong call, IntPtr buf, int size, int cb, [MarshalAs(UnmanagedType.I1)] out bool failed);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_ByIndex(IntPtr self, int i);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_LobbyInt(IntPtr self, ulong lobby);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_LobbyId(IntPtr self, ulong lobby);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_DataByIndex(IntPtr self, ulong lobby, int i, StringBuilder key, int ks, StringBuilder val, int vs);

    static IntPtr h;
    static T F<T>(string name) where T : class {
        IntPtr p = GetProcAddress(h, name);
        if (p == IntPtr.Zero) throw new Exception("falta " + name + " en steam_api.dll");
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }

    // Un pedido por elemento: filtros "k=v,k=v", distancia, minimo de lugares y etiqueta (near/far/extra)
    public static List<Dictionary<string, string>> Fetch(string dll, string[] passFilters, int[] passDist, int[] passSlots, string[] passTags, int timeoutMs) {
        h = LoadLibraryW(dll);
        if (h == IntPtr.Zero) throw new Exception("no pude cargar " + dll + " (error " + Marshal.GetLastWin32Error() + ")");
        if (!F<D_Init>("SteamAPI_Init")()) throw new Exception("No me pude conectar a Steam: tiene que estar abierto y con tu cuenta iniciada.");
        var shutdown = F<D_Void>("SteamAPI_Shutdown");
        try {
            IntPtr mm = F<D_Iface>("SteamAPI_SteamMatchmaking_v009")();
            IntPtr ut = F<D_Iface>("SteamAPI_SteamUtils_v010")();
            if (mm == IntPtr.Zero || ut == IntPtr.Zero) throw new Exception("interfaces de Steam no disponibles");
            var run = F<D_Void>("SteamAPI_RunCallbacks");
            var strFilter = F<D_StrFilter>("SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter");
            var distFilter = F<D_IntArg>("SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter");
            var countFilter = F<D_IntArg>("SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter");
            var slotFilter = F<D_IntArg>("SteamAPI_ISteamMatchmaking_AddRequestLobbyListFilterSlotsAvailable");
            var request = F<D_Call>("SteamAPI_ISteamMatchmaking_RequestLobbyList");
            var isDone = F<D_IsDone>("SteamAPI_ISteamUtils_IsAPICallCompleted");
            var result = F<D_Result>("SteamAPI_ISteamUtils_GetAPICallResult");
            var byIndex = F<D_ByIndex>("SteamAPI_ISteamMatchmaking_GetLobbyByIndex");
            var dataCount = F<D_LobbyInt>("SteamAPI_ISteamMatchmaking_GetLobbyDataCount");
            var dataByIndex = F<D_DataByIndex>("SteamAPI_ISteamMatchmaking_GetLobbyDataByIndex");
            var members = F<D_LobbyInt>("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers");
            var limit = F<D_LobbyInt>("SteamAPI_ISteamMatchmaking_GetLobbyMemberLimit");
            var owner = F<D_LobbyId>("SteamAPI_ISteamMatchmaking_GetLobbyOwner");

            var list = new List<Dictionary<string, string>>();
            var seen = new HashSet<ulong>();
            for (int di = 0; di < passFilters.Length; di++) {
                // Los filtros se reinician despues de cada pedido: hay que volver a ponerlos
                distFilter(mm, passDist[di]);
                countFilter(mm, 50);
                if (passSlots[di] > 0) slotFilter(mm, passSlots[di]);
                foreach (string fl in passFilters[di].Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) {
                    int eq = fl.IndexOf('=');
                    if (eq > 0) strFilter(mm, fl.Substring(0, eq), fl.Substring(eq + 1), 0);   // 0 = igual a
                }
                ulong call = request(mm);
                if (call == 0) throw new Exception("Steam rechazo el pedido de lobbies");
                bool failed;
                int waited = 0;
                while (!isDone(ut, call, out failed)) {
                    run();
                    System.Threading.Thread.Sleep(50);
                    waited += 50;
                    if (waited > timeoutMs) throw new Exception("Steam no respondio a tiempo");
                }
                uint count;
                IntPtr buf = Marshal.AllocHGlobal(16);
                try {
                    // 510 = LobbyMatchList_t { uint32 m_nLobbiesMatching }
                    if (!result(ut, call, buf, 4, 510, out failed) || failed) throw new Exception("Steam no devolvio la lista de lobbies");
                    count = (uint)Marshal.ReadInt32(buf);
                } finally { Marshal.FreeHGlobal(buf); }

                for (int i = 0; i < count; i++) {
                    ulong id = byIndex(mm, i);
                    if (id == 0 || !seen.Add(id)) continue;
                    var d = new Dictionary<string, string>();
                    d["_id"] = id.ToString();
                    d["_members"] = members(mm, id).ToString();
                    d["_limit"] = limit(mm, id).ToString();
                    d["_owner"] = owner(mm, id).ToString();
                    d["_near"] = passTags[di] == "near" ? "1" : "0";
                    d["_extra"] = passTags[di] == "extra" ? "1" : "0";
                    d["_pass"] = di.ToString();
                    int n = dataCount(mm, id);
                    for (int k = 0; k < n; k++) {
                        var key = new StringBuilder(256); var val = new StringBuilder(8192);
                        if (dataByIndex(mm, id, k, key, 256, val, 8192)) d[key.ToString()] = val.ToString();
                    }
                    list.Add(d);
                }
            }
            return list;
        } finally { shutdown(); }
    }
}
'@
}

$pf = @(); $pd = @(); $ps = @(); $pt = @()
if ($Passes) {
    foreach ($spec in ($Passes -split ';' | Where-Object { $_.Trim() })) {
        $d, $s, $fl = $spec -split '\|', 3
        $pf += "$fl"; $pd += [int]$d; $ps += [int]$s; $pt += 'pass'
    }
} else {
    $base = (@($Filter | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) -join ','
    $first = $true
    foreach ($d in ($Distance -split ',' | Where-Object { $_ })) {
        $pf += $base; $pd += [int]$d; $ps += $Slots; $pt += $(if ($first) { 'near' } else { 'far' }); $first = $false
    }
    $extra = (@($ExtraFilter | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) -join ','
    if ($extra) { $pf += $extra; $pd += 3; $ps += 0; $pt += 'extra' }   # mundial y sin minimo de lugares
}
try {
    $list = [L4dLobbies2]::Fetch($Dll, [string[]]$pf, [int[]]$pd, [int[]]$ps, [string[]]$pt, 15000)
} catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    [Console]::Out.Write("ERROR: $($e.Message)")
    exit 1
}
$out = foreach ($d in $list) { $o = [ordered]@{}; foreach ($k in $d.Keys) { $o[$k] = $d[$k] }; [pscustomobject]$o }
if ($Dump) { $out | Format-List | Out-String -Width 300 }
else { [Console]::Out.Write((ConvertTo-Json -InputObject @($out) -Depth 3 -Compress)) }

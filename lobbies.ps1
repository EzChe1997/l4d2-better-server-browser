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
    [switch]$Dump
)

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 4) { throw 'Hay que correrlo con PowerShell de 32 bits' }
$env:SteamAppId = $AppId
$env:SteamGameId = $AppId

if (-not ('L4dLobbies' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class L4dLobbies {
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

    public static List<Dictionary<string, string>> Fetch(string dll, string[] filters, int slots, int[] distances, string[] extra, int timeoutMs) {
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
            // Un pedido por distancia; y si hay filtros extra, uno mas en todo el mundo solo con esos
            int passes = distances.Length + (extra.Length > 0 ? 1 : 0);
            for (int di = 0; di < passes; di++) {
                bool isExtra = di >= distances.Length;
                // Los filtros se reinician despues de cada pedido: hay que volver a ponerlos
                distFilter(mm, isExtra ? 3 : distances[di]);
                countFilter(mm, 50);
                if (slots > 0 && !isExtra) slotFilter(mm, slots);
                foreach (string fl in (isExtra ? extra : filters)) {
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
                    d["_near"] = di == 0 ? "1" : "0";
                    d["_extra"] = isExtra ? "1" : "0";
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

$filters = [string[]]@($Filter | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
try {
    $list = [L4dLobbies]::Fetch($Dll, $filters, $Slots, [int[]]@($Distance -split ',' | Where-Object { $_ } | ForEach-Object { [int]$_ }), [string[]]@($ExtraFilter | ForEach-Object { $_ -split ',' } | Where-Object { $_ }), 15000)
} catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    [Console]::Out.Write("ERROR: $($e.Message)")
    exit 1
}
$out = foreach ($d in $list) { $o = [ordered]@{}; foreach ($k in $d.Keys) { $o[$k] = $d[$k] }; [pscustomobject]$o }
if ($Dump) { $out | Format-List | Out-String -Width 300 }
else { [Console]::Out.Write((ConvertTo-Json -InputObject @($out) -Depth 3 -Compress)) }

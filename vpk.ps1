# vpk.ps1 - lector minimo de archivos VPK de Source (v1/v2) + conversion de las imagenes
# de mapas del lobby (VTF DXT1/DXT5) a PNG. Se usa con dot-sourcing: . .\vpk.ps1

Add-Type -AssemblyName System.Drawing
if (-not ('L4dVtf' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class L4dVtf {
    static int C565(int c) {
        int r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
        return ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2));
    }
    static int Mix(int a, int b, int wa, int wb, int div) {
        int r = (((a >> 16) & 255) * wa + ((b >> 16) & 255) * wb) / div;
        int g = (((a >> 8) & 255) * wa + ((b >> 8) & 255) * wb) / div;
        int bl = ((a & 255) * wa + (b & 255) * wb) / div;
        return (r << 16) | (g << 8) | bl;
    }

    // Decodifica el mip mas grande (que en los VTF esta al final del archivo).
    public static Bitmap Decode(byte[] d) {
        int w = BitConverter.ToUInt16(d, 16), h = BitConverter.ToUInt16(d, 18);
        int fmt = BitConverter.ToInt32(d, 52);
        bool dxt5 = fmt == 15;
        if (fmt != 13 && fmt != 15) throw new NotSupportedException("formato VTF " + fmt);
        int bw = Math.Max(1, (w + 3) / 4), bh = Math.Max(1, (h + 3) / 4);
        int blockSize = dxt5 ? 16 : 8;
        int off = d.Length - bw * bh * blockSize;
        int[] px = new int[w * h];
        int[] col = new int[4];
        int[] alpha = new int[8];
        for (int by = 0; by < bh; by++) for (int bx = 0; bx < bw; bx++) {
            int p = off + (by * bw + bx) * blockSize;
            ulong aBits = 0;
            if (dxt5) {
                alpha[0] = d[p]; alpha[1] = d[p + 1];
                if (alpha[0] > alpha[1]) for (int i = 1; i < 7; i++) alpha[i + 1] = ((7 - i) * alpha[0] + i * alpha[1]) / 7;
                else { for (int i = 1; i < 5; i++) alpha[i + 1] = ((5 - i) * alpha[0] + i * alpha[1]) / 5; alpha[6] = 0; alpha[7] = 255; }
                for (int i = 0; i < 6; i++) aBits |= (ulong)d[p + 2 + i] << (8 * i);
                p += 8;
            }
            int c0 = BitConverter.ToUInt16(d, p), c1 = BitConverter.ToUInt16(d, p + 2);
            uint idx = BitConverter.ToUInt32(d, p + 4);
            col[0] = C565(c0); col[1] = C565(c1);
            bool four = dxt5 || c0 > c1;
            if (four) { col[2] = Mix(col[0], col[1], 2, 1, 3); col[3] = Mix(col[0], col[1], 1, 2, 3); }
            else { col[2] = Mix(col[0], col[1], 1, 1, 2); col[3] = 0; }
            for (int i = 0; i < 16; i++) {
                int x = bx * 4 + (i & 3), y = by * 4 + (i >> 2);
                if (x >= w || y >= h) continue;
                int ci = (int)((idx >> (2 * i)) & 3);
                int a = dxt5 ? alpha[(int)((aBits >> (3 * i)) & 7)] : (!four && ci == 3 ? 0 : 255);
                px[y * w + x] = (a << 24) | col[ci];
            }
        }
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        for (int y = 0; y < h; y++) Marshal.Copy(px, y * w, bd.Scan0 + y * bd.Stride, w);
        bmp.UnlockBits(bd);
        return bmp;
    }
}
'@
}

function Find-L4D2Path {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $libs += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
    }
    foreach ($l in $libs | Select-Object -Unique) {
        $p = Join-Path $l 'steamapps\common\Left 4 Dead 2'
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Exporta materials/vgui/maps/*.vtf de los VPK del juego a PNGs en $outDir. Devuelve cuantas exporto.
function Export-MapImages([string]$gameDir, [string]$outDir) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $n = 0
    foreach ($v in Get-ChildItem $gameDir -Recurse -Filter 'pak01_dir.vpk') {
        foreach ($e in (Read-VpkIndex $v.FullName)) {
            if ($e.Path -notlike 'materials/vgui/maps/*.vtf') { continue }
            $name = [IO.Path]::GetFileNameWithoutExtension($e.Path)
            try {
                $bmp = [L4dVtf]::Decode((Read-VpkFile $e))
                $bmp.Save((Join-Path $outDir "$name.png"), [Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $n++
            } catch {}
        }
    }
    return $n
}

function Read-VpkIndex([string]$dirFile) {
    $fs = [IO.File]::OpenRead($dirFile)
    $br = New-Object IO.BinaryReader($fs)
    try {
        if ($br.ReadUInt32() -ne 0x55AA1234) { throw "No es un VPK: $dirFile" }
        $ver = $br.ReadUInt32()
        $treeSize = $br.ReadUInt32()
        if ($ver -eq 2) { [void]$br.ReadBytes(16) }
        $treeStart = $fs.Position
        $dataStart = $treeStart + $treeSize

        $readStr = {
            $sb = New-Object Text.StringBuilder
            while (($b = $br.ReadByte()) -ne 0) { [void]$sb.Append([char]$b) }
            $sb.ToString()
        }
        $entries = New-Object System.Collections.Generic.List[object]
        while ($true) {
            $ext = & $readStr; if ($ext -eq '') { break }
            while ($true) {
                $path = & $readStr; if ($path -eq '') { break }
                while ($true) {
                    $name = & $readStr; if ($name -eq '') { break }
                    [void]$br.ReadUInt32()                  # crc
                    $preload = $br.ReadUInt16()
                    $archive = $br.ReadUInt16()
                    $offset = $br.ReadUInt32()
                    $length = $br.ReadUInt32()
                    [void]$br.ReadUInt16()                  # terminador
                    $preloadPos = $fs.Position
                    if ($preload) { $fs.Position += $preload }
                    $full = if ($path -eq ' ') { "$name.$ext" } else { "$path/$name.$ext" }
                    $entries.Add([pscustomobject]@{
                            Path = $full.ToLower(); Archive = $archive; Offset = $offset; Length = $length
                            Preload = $preload; PreloadPos = $preloadPos; DataStart = $dataStart; DirFile = $dirFile
                        })
                }
            }
        }
        return $entries
    } finally { $br.Close() }
}

function Read-VpkFile($entry) {
    $ms = New-Object IO.MemoryStream
    if ($entry.Preload) {
        $fs = [IO.File]::OpenRead($entry.DirFile)
        try { $fs.Position = $entry.PreloadPos; $buf = New-Object byte[] $entry.Preload; [void]$fs.Read($buf, 0, $buf.Length); $ms.Write($buf, 0, $buf.Length) } finally { $fs.Close() }
    }
    if ($entry.Length) {
        if ($entry.Archive -eq 0x7FFF) { $file = $entry.DirFile; $pos = $entry.DataStart + $entry.Offset }
        else { $file = $entry.DirFile -replace '_dir\.vpk$', ('_{0:D3}.vpk' -f $entry.Archive); $pos = $entry.Offset }
        $fs = [IO.File]::OpenRead($file)
        try { $fs.Position = $pos; $buf = New-Object byte[] $entry.Length; [void]$fs.Read($buf, 0, $buf.Length); $ms.Write($buf, 0, $buf.Length) } finally { $fs.Close() }
    }
    return , $ms.ToArray()
}

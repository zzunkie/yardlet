# Gives the Windows app's executable Yardlet's icon, which its taskbar button, Start menu shortcut and entry in
# Settings > Apps take from it, and writes the same icon as an .ico file for Velopack's installer. The window's
# title bar keeps the default icon. The icon is Packaging/YardletIcon-master.png drawn at Windows' icon sizes, each
# kept as PNG inside the icon. It changes the executable it is given, so pack.ps1 runs it on its own copy, before
# anything is signed.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $Icon
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class ExecutableIcon {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr update, bool discard);

    const int RT_ICON = 3, RT_GROUP_ICON = 14;

    // An .ico file: its header, a 16-byte entry for each image, then the images.
    public static byte[] IconFile(int[] sizes, byte[][] images) {
        var file = new MemoryStream();
        var writer = new BinaryWriter(file);
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)images.Length);
        int offset = 6 + 16 * images.Length;
        for (int i = 0; i < images.Length; i++) {
            Entry(writer, sizes[i], images[i].Length);
            writer.Write(offset);
            offset += images[i].Length;
        }
        foreach (var image in images) writer.Write(image);
        return file.ToArray();
    }

    // Each image as an RT_ICON resource numbered from 1, and the group that lists them as RT_GROUP_ICON 1, the
    // icon Windows shows for the executable.
    public static void Set(string executable, int[] sizes, byte[][] images) {
        IntPtr update = BeginUpdateResource(executable, false);
        if (update == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        var group = new MemoryStream();
        var writer = new BinaryWriter(group);
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)images.Length);
        for (int i = 0; i < images.Length; i++) {
            if (!UpdateResource(update, (IntPtr)RT_ICON, (IntPtr)(i + 1), 0, images[i], (uint)images[i].Length)) {
                EndUpdateResource(update, true);
                throw new System.ComponentModel.Win32Exception();
            }
            Entry(writer, sizes[i], images[i].Length);
            writer.Write((ushort)(i + 1));
        }
        byte[] directory = group.ToArray();
        if (!UpdateResource(update, (IntPtr)RT_GROUP_ICON, (IntPtr)1, 0, directory, (uint)directory.Length)) {
            EndUpdateResource(update, true);
            throw new System.ComponentModel.Win32Exception();
        }
        if (!EndUpdateResource(update, false)) throw new System.ComponentModel.Win32Exception();
    }

    // Width and height (0 for 256), no palette, one plane, 32 bits, and the image's length.
    static void Entry(BinaryWriter writer, int size, int length) {
        writer.Write((byte)(size >= 256 ? 0 : size)); writer.Write((byte)(size >= 256 ? 0 : size));
        writer.Write((byte)0); writer.Write((byte)0);
        writer.Write((ushort)1); writer.Write((ushort)32);
        writer.Write(length);
    }
}
'@

$master = [System.Drawing.Image]::FromFile((Join-Path $root 'Packaging/YardletIcon-master.png'))
$sizes = @(256, 64, 48, 40, 32, 24, 20, 16)
$images = foreach ($size in $sizes) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($master, 0, 0, $size, $size)
    $graphics.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    , $stream.ToArray()
}
$master.Dispose()
[System.IO.File]::WriteAllBytes($Icon, [ExecutableIcon]::IconFile([int[]]$sizes, [byte[][]]$images))
[ExecutableIcon]::Set((Resolve-Path $Executable).Path, [int[]]$sizes, [byte[][]]$images)
"Icon: $($sizes -join ', ') px, in $(Split-Path $Executable -Leaf) and $(Split-Path $Icon -Leaf)"

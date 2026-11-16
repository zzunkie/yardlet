# Gives the Windows app's executable Yardlet's name, pack version and icon. Windows reads the name and version from
# VS_VERSIONINFO; the taskbar button, Start menu shortcut and entry in Settings > Apps take its icon. It writes the
# same icon as an .ico file for Velopack's installer and the app's notification registration. The window's
# title bar keeps the default icon. The icon is Packaging/YardletIcon-master.png drawn at Windows' icon sizes, each
# kept as PNG inside the icon. It changes the executable it is given, so pack.ps1 runs it on its own copy, before
# anything is signed.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $Icon,
    [Parameter(Mandatory)] [string] $Version
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class ExecutableIcon {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr update, bool discard);

    const int RT_ICON = 3, RT_GROUP_ICON = 14, RT_VERSION = 16;

    // Version-resource blocks have UTF-16 keys and DWORD-aligned values and children. Text value lengths count
    // UTF-16 code units, including the terminator; binary lengths count bytes.
    static byte[] Block(string key, ushort type, byte[] value, params byte[][] children) {
        var stream = new MemoryStream();
        var writer = new BinaryWriter(stream);
        writer.Write((ushort)0);
        writer.Write(checked((ushort)(type == 1 ? value.Length / 2 : value.Length)));
        writer.Write(type);
        writer.Write(Encoding.Unicode.GetBytes(key + "\0"));
        while (stream.Position % 4 != 0) writer.Write((byte)0);
        writer.Write(value);
        foreach (var child in children) {
            while (stream.Position % 4 != 0) writer.Write((byte)0);
            writer.Write(child);
        }
        long length = stream.Length;
        stream.Position = 0;
        writer.Write(checked((ushort)length));
        return stream.ToArray();
    }

    static byte[] Text(string key, string value) {
        return Block(key, 1, Encoding.Unicode.GetBytes(value + "\0"));
    }

    static byte[] VersionInfo(string version) {
        // The fixed structure has four WORDs; the strings keep the pack's full version, including prerelease.
        var numeric = Version.Parse(version.Split('-', '+')[0]);
        uint major = checked((ushort)numeric.Major), minor = checked((ushort)numeric.Minor);
        uint build = checked((ushort)Math.Max(0, numeric.Build)), revision = checked((ushort)Math.Max(0, numeric.Revision));
        var stream = new MemoryStream();
        var writer = new BinaryWriter(stream);
        writer.Write(0xFEEF04BDu); writer.Write(0x00010000u); // Signature and structure version.
        writer.Write((major << 16) | minor); writer.Write((build << 16) | revision); // File version.
        writer.Write((major << 16) | minor); writer.Write((build << 16) | revision); // Product version.
        writer.Write(0x3Fu); writer.Write(0u); // Flags mask, no flags.
        writer.Write(0x00040004u); writer.Write(1u); // VOS_NT_WINDOWS32, VFT_APP.
        writer.Write(0u); writer.Write(0u); writer.Write(0u); // Subtype and file date.
        byte[] strings = Block("StringFileInfo", 1, new byte[0],
            Block("040904b0", 1, new byte[0], // English (US), Unicode (1200).
                Text("FileDescription", "Yardlet"), Text("ProductName", "Yardlet"),
                Text("FileVersion", version), Text("ProductVersion", version)));
        byte[] translation = Block("VarFileInfo", 1, new byte[0],
            Block("Translation", 0, new byte[] { 0x09, 0x04, 0xB0, 0x04 }));
        return Block("VS_VERSION_INFO", 0, stream.ToArray(), strings, translation);
    }

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
    // icon Windows shows for the executable, plus its version information in English (US).
    public static void Set(string executable, int[] sizes, byte[][] images, string version) {
        byte[] versionInfo = VersionInfo(version);
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
        if (!UpdateResource(update, (IntPtr)RT_VERSION, (IntPtr)1, 0x0409, versionInfo, (uint)versionInfo.Length)) {
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
[ExecutableIcon]::Set((Resolve-Path $Executable).Path, [int[]]$sizes, [byte[][]]$images, $Version)
"Version: Yardlet $Version in $(Split-Path $Executable -Leaf)"
"Icon: $($sizes -join ', ') px, in $(Split-Path $Executable -Leaf) and $(Split-Path $Icon -Leaf)"

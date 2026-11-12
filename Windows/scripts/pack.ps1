# Packs the Windows app with Velopack (docs/PLATFORM_PORTABILITY.md, "Installing and updating the Windows app").
# It gathers what the app runs with into one folder: its executable with Yardlet's icon (set-app-icon.ps1), the
# libraries and resource folder the build made beside it, the Windows App SDK's bootstrapper (place-bootstrapper.ps1
# put it there), the Swift runtime, the relay the build carries (place-relay.ps1), Velopack's library, the update
# feed, and the license and third-party notices. No other executable goes in, so a test program the build made,
# such as yardlet-remote-fixture.exe, stays out.
# `vpk pack` then writes to -OutDirectory the installer (YardletApp-win-Setup.exe), the portable zip, the package
# and the feed an installed app reads its updates from (releases.win.json).
#
# The pack id is YardletApp, not Yardlet: Velopack installs into %LOCALAPPDATA%\<pack id>, replaces a folder it
# finds there and empties it when the app is removed, and %LOCALAPPDATA%\Yardlet holds the app's own data.
#
# -UpdateFeed: where the installed app looks for updates, written to YardletUpdateFeed beside the executable: a
#   GitHub repository whose releases carry these files (https://github.com/<owner>/<repo>), or another Velopack
#   feed's address or folder. Without it the app has no updater.
# -SignTemplate: the command that signs one file, with {{file}} where its path goes, which vpk runs on every
#   executable and library it packs before it builds the installer; YARDLET_WINDOWS_SIGN_TEMPLATE by default.
#   Without it nothing is signed.
param(
    [Parameter(Mandatory)] [string] $Binaries,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Version,
    [string] $UpdateFeed,
    [string] $SignTemplate = $env:YARDLET_WINDOWS_SIGN_TEMPLATE
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$work = Join-Path $root 'Windows/.work'
New-Item -ItemType Directory -Force $work | Out-Null

# Velopack's packer and its C library, at one version: the library's functions are the ones
# Platform/Windows/WindowsUpdates.swift calls, and the packer writes what that library reads.
$velopack = '1.2.161'
$libraryHash = '31de8f2cf05a47bd5328a9f98b0c41aec1582156f6075f1058b26941f7f17c20'
$tools = Join-Path $work "vpk-$velopack"
$vpk = Join-Path $tools 'vpk.exe'
if (-not (Test-Path $vpk)) {
    dotnet tool install vpk --version $velopack --tool-path $tools | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool install vpk ended with $LASTEXITCODE" }
}
$library = Join-Path $work "velopack_libc_$velopack"
if (-not (Test-Path (Join-Path $library 'lib'))) {
    $zip = Join-Path $work "velopack_libc_$velopack.zip"
    Invoke-WebRequest -Uri "https://github.com/velopack/velopack/releases/download/$velopack/velopack_libc_$velopack.zip" -OutFile $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $libraryHash) { throw "velopack_libc_$velopack.zip has SHA-256 $hash, not $libraryHash" }
    Expand-Archive $zip $library -Force
}

if (-not $Version) {
    $plist = [xml](Get-Content (Join-Path $root 'Packaging/Info.plist') -Raw)
    $keys = $plist.plist.dict.ChildNodes
    for ($i = 0; $i -lt $keys.Count; $i++) {
        if ($keys[$i].InnerText -eq 'CFBundleShortVersionString') { $Version = $keys[$i + 1].InnerText; break }
    }
    if (-not $Version) { throw 'No version given, and none in Packaging/Info.plist' }
}

# The app's folder: its executable, then what the build put beside it.
$stage = Join-Path $work 'pack'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
$main = 'NativeHarnessClient.exe'
Copy-Item (Join-Path $Binaries $main) $stage
Get-ChildItem $Binaries -File | Where-Object { $_.Extension -in '.dll', '.pri', '.winmd' } | Copy-Item -Destination $stage
Get-ChildItem $Binaries -Directory | Where-Object Name -match 'resources|bundle' | Copy-Item -Destination $stage -Recurse
if (-not (Test-Path (Join-Path $stage 'Microsoft.WindowsAppRuntime.Bootstrap.dll'))) {
    throw "No Windows App SDK bootstrapper in $Binaries; run place-bootstrapper.ps1 first"
}
$runtime = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" -Directory | Select-Object -First 1
if (-not $runtime) { throw 'No Swift runtime under %LOCALAPPDATA%\Programs\Swift\Runtimes' }
Copy-Item "$runtime\*.dll" $stage
& (Join-Path $PSScriptRoot 'place-relay.ps1') -Destination $stage
Copy-Item (Join-Path $library 'lib/velopack_libc_win_x64_msvc.dll') $stage
# The notices for what the app carries, as the Mac's bundle has them.
Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'THIRD_PARTY_NOTICES.md') $stage
if ($UpdateFeed) {
    Set-Content -Path (Join-Path $stage 'YardletUpdateFeed') -Value $UpdateFeed -NoNewline -Encoding ascii
    'Updates: from the feed given'
} else {
    'Updates: none, no feed given'
}
$icon = Join-Path $work 'Yardlet.ico'
& (Join-Path $PSScriptRoot 'set-app-icon.ps1') -Executable (Join-Path $stage $main) -Icon $icon
$executables = @(Get-ChildItem $stage -Recurse -File -Filter '*.exe' | ForEach-Object Name)
if ($executables.Count -ne 1 -or $executables[0] -ne $main) { throw "The app's folder has other executables: $executables" }
Get-ChildItem $stage -Recurse -File | Measure-Object -Property Length -Sum |
    ForEach-Object { "Packed: $($_.Count) files, $([math]::Round($_.Sum / 1MB, 1)) MB, version $Version" }

$arguments = @(
    'pack', '--packId', 'YardletApp', '--packVersion', $Version, '--packTitle', 'Yardlet', '--packAuthors', 'Yardlet',
    '--packDir', $stage, '--mainExe', $main, '--runtime', 'win-x64', '--icon', $icon, '--shortcuts', 'StartMenuRoot',
    '--outputDir', $OutDirectory
)
if ($SignTemplate) {
    $arguments += @('--signTemplate', $SignTemplate)
    'Signing: with the template given'
} else {
    'Signing: none'
}
& $vpk @arguments
if ($LASTEXITCODE -ne 0) { throw "vpk pack ended with $LASTEXITCODE" }
Get-ChildItem $OutDirectory -File | ForEach-Object { "$($_.Name), $([math]::Round($_.Length / 1MB, 1)) MB" }

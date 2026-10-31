# Builds swift-winrt at the pinned commit with the patches -Patches names, as its own CI does (its CMake
# presets, the C++ test component and the Swift test app), runs its test app, and writes the test
# bindings the build regenerated as a patch to -Regenerated. Needs Visual Studio's C++ tools and Swift.
param(
    [string[]] $Patches = @(),
    [Parameter(Mandatory)] [string] $Regenerated
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Regenerated = [IO.Path]::GetFullPath($Regenerated)

$bindings = Join-Path (Split-Path $PSScriptRoot -Parent) 'Bindings'
$generator = Get-Content (Join-Path $bindings 'swift-winrt.json') -Raw | ConvertFrom-Json
$source = Join-Path $env:RUNNER_TEMP 'swift-winrt'
git init -q $source
git -C $source config core.autocrlf false
git -C $source remote add origin $generator.repository
git -C $source fetch -q --depth 1 origin $generator.commit
git -C $source checkout -q --detach FETCH_HEAD
git -C $source submodule update -q --init --recursive --depth 1
foreach ($patch in $Patches) {
    git -C $source apply (Join-Path $bindings "swift-winrt-patches\$patch")
    Write-Output "Applied $patch"
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
cmd /c "`"$(Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat')`" >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) }
}

Push-Location $source
try {
    $swift = (Get-Command swift).Source
    $version = ((swift --version 2>&1 | Select-String -Pattern 'Swift version (\d+\.\d+(\.\d+)?)').Matches[0].Groups[1].Value)
    # swift-winrt's CMake installs the test app from where SwiftPM's native build system puts it; Swift
    # Build, the default since Swift 6.4, puts it elsewhere.
    cmake --preset release "-DSWIFT_VERSION=$version" "-DSWIFT_EXE=$swift" "-DSWIFT_BUILD_ARGS=--build-system;native"
    cmake --build --preset release
    cmake --build --preset release --target install
    git add -N .
    # Written by git itself, so each file keeps its own line endings.
    git diff --binary --output=$Regenerated -- tests/test_component/Sources
    # swift-winrt installs the test app with test_component.dll; with Swift 6.4 the modules that DLL uses
    # are DLLs of their own, beside it where SwiftPM built them.
    $built = Join-Path $source 'build\release\tests\x86_64-unknown-windows-msvc\release'
    Get-ChildItem $built -Filter *.dll | Where-Object { -not (Test-Path (Join-Path 'out\release\bin' $_.Name)) } | ForEach-Object {
        Copy-Item $_.FullName 'out\release\bin'
        Write-Output "Copied $($_.Name)"
    }
    # The test app links XCTest, which swift.org's installer leaves off PATH (swift test adds it), and
    # Swift 6.4's XCTest loads _TestingInterop.dll from Swift Testing's folder.
    $swiftRoot = $swift -replace '\\Toolchains\\.*$', ''
    foreach ($library in 'XCTest.dll', '_TestingInterop.dll') {
        $found = Get-ChildItem (Join-Path $swiftRoot 'Platforms') -Recurse -Filter $library |
            Where-Object { $_.DirectoryName -notmatch 'arm64|aarch64|bin32' } | Select-Object -First 1
        if ($found) { $env:Path = "$($found.DirectoryName);$env:Path"; Write-Output "$library from $($found.DirectoryName)" }
    }
    $PSNativeCommandUseErrorActionPreference = $false
    # What the installed files load that cannot be found, for a test app that does not start.
    $bin = Resolve-Path 'out\release\bin'
    Write-Output "Installed: $((Get-ChildItem $bin | ForEach-Object Name) -join ', ')"
    foreach ($image in Get-ChildItem $bin -Include *.exe, *.dll -Recurse) {
        $dependents = dumpbin /nologo /dependents $image.FullName | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
        $missing = $dependents | Where-Object {
            -not (Test-Path (Join-Path $bin $_)) -and -not (Get-Command $_ -ErrorAction SilentlyContinue) -and
            -not (Test-Path (Join-Path $env:SystemRoot "System32\$_")) -and $_ -notmatch '^api-ms-|^ext-ms-'
        }
        if ($missing) { Write-Output "$($image.Name) cannot find: $($missing -join ', ')" }
    }
    & .\out\release\bin\test_app.exe
    $tests = $LASTEXITCODE
} finally {
    Pop-Location
}
Write-Output "test_app exit $tests"
exit $tests

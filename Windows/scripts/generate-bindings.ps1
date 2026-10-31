# Generates the WinUI bindings of the Windows app into Windows/Bindings/Generated, which git ignores
# (docs/PLATFORM_PORTABILITY.md, "The Windows app"): swift-winrt at the commit Windows/Bindings/
# swift-winrt.json pins projects the types Windows/Bindings/projections.json includes and every type
# their members reach.
#
# The inputs are Microsoft's NuGet packages at the versions and SHA-512 hashes projections.json pins,
# restored as packages.config lists them: the Windows App SDK's, the Windows SDK's and WebView2's
# metadata (.winmd), and, from the Windows App SDK package, the x64 bootstrapper with its import library
# and header, which Bindings/Package.swift links as CWindowsAppSDK. Building swift-winrt needs Visual
# Studio's C++ tools.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$windows = Split-Path $PSScriptRoot -Parent
$bindings = Join-Path $windows 'Bindings'
$projections = Get-Content (Join-Path $bindings 'projections.json') -Raw | ConvertFrom-Json
$generator = Get-Content (Join-Path $bindings 'swift-winrt.json') -Raw | ConvertFrom-Json
$commit = $generator.commit
$work = Join-Path $bindings '.work'
$packages = Join-Path $work 'packages'
$generated = Join-Path $bindings 'Generated'
New-Item -ItemType Directory -Force $work, $packages | Out-Null

function Import-DeveloperEnvironment {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) }
    }
}

# swift-winrt publishes its builds to a package feed that needs signing in, so it is built from source.
$tool = Join-Path $work "swift-winrt-$commit\swiftwinrt.exe"
if (-not (Test-Path $tool)) {
    $source = Join-Path $work 'generator-source'
    if (Test-Path $source) { Remove-Item -Recurse -Force $source }
    git init -q $source
    git -C $source remote add origin $generator.repository
    git -C $source fetch -q --depth 1 origin $commit
    git -C $source checkout -q --detach FETCH_HEAD
    $fetched = git -C $source rev-parse HEAD
    if ($fetched -ne $commit) { throw "swift-winrt is at $fetched, not the pinned $commit" }
    git -C $source submodule update -q --init --depth 1
    Import-DeveloperEnvironment
    # The generator's own folder, without the repository's tests; CMake 4 wants the minimum version
    # stated at the top, which the folder's file leaves to the repository's.
    $wrapper = Join-Path $work 'generator-project'
    New-Item -ItemType Directory -Force $wrapper | Out-Null
    @(
        'cmake_minimum_required(VERSION 3.15.1)',
        'project(swiftwinrt_generator LANGUAGES C CXX)',
        "add_subdirectory(`"$((Join-Path $source 'swiftwinrt') -replace '\\', '/')`" swiftwinrt)"
    ) | Set-Content (Join-Path $wrapper 'CMakeLists.txt') -Encoding ascii
    $build = Join-Path $work 'generator-build'
    cmake -S $wrapper -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
    cmake --build $build --target swiftwinrt
    New-Item -ItemType Directory -Force (Split-Path $tool) | Out-Null
    Copy-Item (Join-Path $build 'swiftwinrt\swiftwinrt.exe') $tool
}
Write-Output "swift-winrt $commit"

# Microsoft's packages, as a native project restores them.
$nuget = (Get-Command nuget -ErrorAction SilentlyContinue).Source
if (-not $nuget) {
    $nuget = Join-Path $work 'nuget.exe'
    Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/v6.14.0/nuget.exe' -OutFile $nuget
    if ((Get-AuthenticodeSignature $nuget).Status -ne 'Valid') { throw 'nuget.exe is not validly signed' }
}
$config = Join-Path $work 'packages.config'
$lines = @('<?xml version="1.0" encoding="utf-8"?>', '<packages>')
$lines += $projections.packages | ForEach-Object { "  <package id=`"$($_.id)`" version=`"$($_.version)`" />" }
$lines += '</packages>'
$lines | Set-Content $config -Encoding ascii
& $nuget restore $config -PackagesDirectory $packages -NonInteractive | Out-Null
function Get-Package([string] $id) {
    $package = $projections.packages | Where-Object id -eq $id
    Join-Path $packages "$($package.id).$($package.version)"
}
foreach ($package in $projections.packages) {
    $file = Join-Path (Get-Package $package.id) "$($package.id).$($package.version).nupkg"
    $hash = [Convert]::ToBase64String([Convert]::FromHexString((Get-FileHash $file -Algorithm SHA512).Hash))
    if ($hash -ne $package.sha512) { throw "$($package.id) $($package.version) has SHA-512 $hash, not the pinned $($package.sha512)" }
}
$appSdk = Get-Package 'Microsoft.WindowsAppSDK'

# The metadata: the Windows App SDK's for its newest target, the Windows SDK's contracts, WebView2's.
$inputs = @()
$inputs += Get-ChildItem (Join-Path $appSdk 'lib\uap10.0') -Filter *.winmd
$inputs += Get-ChildItem (Join-Path $appSdk 'lib\uap10.0.18362') -Filter *.winmd
$inputs += Get-ChildItem (Get-Package 'Microsoft.Windows.SDK.Contracts') -Recurse -Filter *.winmd
$inputs += Get-ChildItem (Get-Package 'Microsoft.Web.WebView2') -Recurse -Filter *.winmd |
    Where-Object { $_.DirectoryName -notmatch '\\(arm64|x86)\\' } | Select-Object -First 1

$output = Join-Path $work 'output'
if (Test-Path $output) { Remove-Item -Recurse -Force $output }
$arguments = @("-output $output")
$arguments += $projections.include | ForEach-Object { "-include $_" }
$arguments += $projections.exclude | ForEach-Object { "-exclude $_" }
$arguments += $inputs | ForEach-Object { "-input $($_.FullName)" }
$response = Join-Path $work 'swift-winrt.rsp'
$arguments | Set-Content $response -Encoding ascii
& $tool "@$response"

if (Test-Path $generated) { Remove-Item -Recurse -Force $generated }
New-Item -ItemType Directory -Force $generated | Out-Null
foreach ($module in Get-ChildItem (Join-Path $output 'Sources') -Directory) {
    Copy-Item -Recurse $module.FullName (Join-Path $generated $module.Name)
}
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $generated 'CWinRT\Package.swift')

# The bootstrapper: its header, its x64 import library and DLL from the Windows App SDK package.
$bootstrap = Join-Path $generated 'CWindowsAppSDK'
New-Item -ItemType Directory -Force "$bootstrap\include", "$bootstrap\lib", "$bootstrap\bin" | Out-Null
Copy-Item (Join-Path $appSdk 'include\MddBootstrap.h'), (Join-Path $appSdk 'include\WindowsAppSDK-VersionInfo.h') "$bootstrap\include"
Copy-Item (Join-Path $appSdk 'lib\win10-x64\Microsoft.WindowsAppRuntime.Bootstrap.lib') "$bootstrap\lib"
Copy-Item (Join-Path $appSdk 'runtimes\win-x64\native\Microsoft.WindowsAppRuntime.Bootstrap.dll') "$bootstrap\bin"
@'
#pragma once
#include <windows.h>
#include <appmodel.h>
#include <roapi.h>
#include "MddBootstrap.h"
#include "WindowsAppSDK-VersionInfo.h"
'@ | Set-Content "$bootstrap\include\CWindowsAppSDK.h" -Encoding ascii
@'
module CWindowsAppSDK {
    header "CWindowsAppSDK.h"
    export *
}
'@ | Set-Content "$bootstrap\include\module.modulemap" -Encoding ascii
'// The bootstrapper is linked from its import library; this file gives the C target a source.' |
    Set-Content "$bootstrap\CWindowsAppSDK.c" -Encoding ascii

# What was generated, by module and namespace, for the run's annotations.
foreach ($module in Get-ChildItem $generated -Directory | Where-Object Name -notin 'CWinRT', 'CWindowsAppSDK') {
    $files = Get-ChildItem $module.FullName -Recurse -Filter *.swift
    $bytes = ($files | Measure-Object Length -Sum).Sum
    Write-Output ("{0}: {1:N1} MB of Swift in {2} files" -f $module.Name, ($bytes / 1MB), $files.Count)
}

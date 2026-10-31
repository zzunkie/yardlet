# Writes a window build's results to the run's annotations, which can be read without signing in
# (the check run's annotations in the API): the build time, the binaries, the window check's summary,
# and the build's errors when it failed.
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $BuildLog,
    [string] $Seconds,
    [string] $OutDirectory,
    [string] $Binaries
)

function Report([string] $title, [string[]] $lines) {
    $text = ($lines -join "`n") -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Output "::notice title=$title::$text"
}

if ($Seconds) { Report "$Name build time" "$Seconds seconds" }

if ($Binaries -and (Test-Path $Binaries)) {
    $files = Get-ChildItem $Binaries -File | Where-Object { $_.Extension -in '.exe', '.dll', '.pri', '.winmd' }
    $total = ($files | Measure-Object Length -Sum).Sum
    $lines = @("Executables and libraries: $([math]::Round($total / 1MB, 1)) MB in $($files.Count) files")
    $lines += $files | Sort-Object Length -Descending | Select-Object -First 25 |
        ForEach-Object { "$([math]::Round($_.Length / 1KB)) KB $($_.Name)" }
    $lines += "Resource indexes: " + ((Get-ChildItem $Binaries -File -Filter *.pri | ForEach-Object Name) -join ', ')
    $lines += "Resource folders: " + ((Get-ChildItem $Binaries -Directory | Where-Object Name -match 'resources|bundle' | ForEach-Object Name) -join ', ')
    Report "$Name binaries" $lines
}

$summary = if ($OutDirectory) { Join-Path $OutDirectory "$Name-summary.json" }
if ($summary -and (Test-Path $summary)) {
    Report "$Name window check" (Get-Content $summary -Encoding utf8)
}

if ($BuildLog -and (Test-Path $BuildLog)) {
    $errors = Select-String -Path $BuildLog -Pattern 'error:|: error ' | ForEach-Object { $_.Line.Trim() } | Sort-Object -Unique
    if ($errors) {
        Report "$Name build errors" ($errors | Select-Object -First 150)
        Report "$Name build log" (Get-Content $BuildLog -Tail 60)
    }
}

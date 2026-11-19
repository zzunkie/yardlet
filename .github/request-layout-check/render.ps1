$Pass="render"
$ErrorActionPreference='Stop'
$root=$env:QA_ROOT
$out=Join-Path $root $Pass
New-Item -ItemType Directory $out -Force | Out-Null
$proc=$null
try {
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class QaWindow {
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after,int x,int y,int w,int h,uint flags);
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 public struct Rect { public int Left, Top, Right, Bottom; }
}
'@
[void][QaWindow]::SetProcessDpiAwarenessContext([IntPtr](-4))
$screen=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$local=Join-Path $out 'local'
Expand-Archive -LiteralPath (Join-Path $root 'fixtures.zip') -DestinationPath $local -Force
$binary=Join-Path $root 'bin\NativeHarnessClient.exe'
$info=[Diagnostics.ProcessStartInfo]::new($binary)
$info.UseShellExecute=$false
$info.WorkingDirectory=Split-Path -LiteralPath $binary
$info.EnvironmentVariables['LOCALAPPDATA']=$local
$info.EnvironmentVariables['APPDATA']=Join-Path $out 'roaming'
$info.EnvironmentVariables['USERPROFILE']=Join-Path $out 'profile'

$mock=Join-Path $root 'mock'
$info.Arguments='-runtime.claude-code.executablePath "'+(Join-Path $mock 'claude.exe')+'"'
$info.EnvironmentVariables['PATH']="$mock;$env:SystemRoot\System32;$env:SystemRoot"
$info.EnvironmentVariables['CLAUDE_CONFIG_DIR']=Join-Path $out 'claude-scratch'
$info.EnvironmentVariables['ANTHROPIC_BASE_URL']='http://127.0.0.1:1'
$info.EnvironmentVariables['HTTPS_PROXY']='http://127.0.0.1:1'
$info.EnvironmentVariables['HTTP_PROXY']='http://127.0.0.1:1'
$info.EnvironmentVariables['YARDLET_QA_HARNESS_CHECK']='claude-code'

$info.EnvironmentVariables['YARDLET_QA_EVENT_LOG']=Join-Path $out 'events.log'
$proc=[Diagnostics.Process]::Start($info)
for ($i=0; $i -lt 70; $i++) {
    $proc.Refresh()
    if ($proc.HasExited) {throw "App exited ($($proc.ExitCode))"}
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 300
}
$hwnd=$proc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) {throw 'No app window'}
function Resize([int]$width,[int]$height) {
    [void][QaWindow]::SetWindowPos($hwnd,[IntPtr]::Zero,$screen.Left+8,$screen.Top+8,[Math]::Min($width,$screen.Width-16),[Math]::Min($height,$screen.Height-16),0x0014)
    Start-Sleep -Milliseconds 500
}
Resize 1130 760
$tree=[System.Windows.Automation.TreeScope]::Descendants
$AE=[System.Windows.Automation.AutomationElement]
$ct=[System.Windows.Automation.ControlType]
$main=$AE::FromHandle($hwnd)
function Items { return $main.FindAll($tree,[System.Windows.Automation.Condition]::TrueCondition) }
function Choose($name) {
    for ($attempt=0;$attempt -lt 15;$attempt++) {
        $option=@(Items | Where-Object { $_.Current.ControlType -eq $ct::ListItem -and $_.Current.Name -like "*$name*" })[0]
        if ($option) { $option.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Milliseconds 500;return }
        $more=@(Items | Where-Object {$_.Current.ControlType -eq $ct::Button -and $_.Current.Name -in 'Show more','더 보기'})[0]
        if ($more) {$more.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}
        Start-Sleep -Milliseconds 250
    }
    throw "No QA sidebar item $name"
}
function Shot($name) {
    $rect=New-Object QaWindow+Rect
    [void][QaWindow]::GetWindowRect($hwnd,[ref]$rect)
    if ($rect.Left -lt ($screen.Left-9) -or $rect.Right -gt ($screen.Right+9)) {throw 'Window is outside the runner display'}
    $bmp=New-Object Drawing.Bitmap ($rect.Right-$rect.Left),($rect.Bottom-$rect.Top)
    $g=[Drawing.Graphics]::FromImage($bmp); $dc=$g.GetHdc()
    try {$ok=[QaWindow]::PrintWindow($hwnd,$dc,2)} finally {$g.ReleaseHdc($dc);$g.Dispose()}
    if (-not $ok) {throw 'PrintWindow failed'}
    $bmp.Save((Join-Path $out ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose()
    $lines=foreach ($node in (Items)) {
        $r=$node.Current.BoundingRectangle
        $label=$node.Current.Name
        if ($label.Length -gt 170) {$label=$label.Substring(0,170)}
        if ($label -or $node.Current.ControlType -in $ct::Edit,$ct::SplitButton,$ct::ScrollBar) {
            '{0} {1} ({2},{3}; {4}x{5})' -f $node.Current.ControlType.ProgrammaticName,$label,($r.Left-$rect.Left),($r.Top-$rect.Top),$r.Width,$r.Height
        }
    }
    $lines | Set-Content (Join-Path $out ($name+'.txt')) -Encoding UTF8
}
function Find-Control($type, $names) {
    @(Items | Where-Object {$_.Current.ControlType -eq $type -and $_.Current.Name -in $names})[0]
}
function History-Ids {
    $map=@{}
    foreach ($n in (Items)) {
        if ($n.Current.Name -like 'Fixture history *') { $map[$n.Current.Name]=($n.GetRuntimeId() -join ',') }
    }
    return $map
}
function Start-Request($prompt) {
    # Only the scratch index points to this offline executable; the app's PATH contains no provider runtime.
    if (-not (Test-Path (Join-Path $root 'mock\claude.exe'))) {throw 'Missing local fixture executable'}
    $wanted='harness found: claude-code '+(Join-Path $root 'mock\claude.exe')
    $log=Join-Path $out 'events.log'
    if (-not ((Get-Content $log -Encoding UTF8) -contains $wanted)) {throw 'The app did not select the isolated fixture runtime'}
    $field=@(Items | Where-Object {$_.Current.ControlType -eq $ct::Edit -and $_.Current.Name -notin '작업 검색','Search tasks'})[-1]
    if (-not $field) {throw 'No task composer'}
    $field.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($prompt)
    Start-Sleep -Milliseconds 200
    $send=Find-Control $ct::Button @('보내기','Send')
    if (-not $send -or -not $send.Current.IsEnabled) {throw 'Fixture composer cannot send'}
    $send.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    for ($n=0; $n -lt 30; $n++) {
        if ((Find-Control $ct::Button @('거부','Deny','허용','Allow','답변 제출','Submit answers','제출','건너뛰기','Skip')) -or
             @(Items | Where-Object {$_.Current.ControlType -eq $ct::RadioButton}).Count) {return}
        Start-Sleep -Milliseconds 330
    }
    Shot ('fixture-error-'+($prompt -replace ' ','-'))
    throw "Mock request never appeared for $prompt"
}
Choose 'QA Empty';Shot 'empty'
Choose 'QA Failed';Shot 'failed'
Choose 'QA Answered';Shot 'answered'
Choose 'QA Korean';Resize 700 720
$editor=@(Items | Where-Object {$_.Current.ControlType -eq $ct::Edit})[-1]
if ($editor) {
    $sample=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-Content -LiteralPath (Join-Path $root 'sample.txt') -Raw)))
    $editor.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($sample)
}
Start-Sleep -Milliseconds 500
Shot 'narrow-korean'
Resize 540 620; Shot 'narrow-send'
Resize 1130 760

$nameKR=([string][char]0xC124)+([string][char]0xC815)
$settings=@(Items | Where-Object {$_.Current.ControlType -in $ct::ListItem,$ct::Button -and $_.Current.Name -in 'Settings',$nameKR})[0]
if ($settings) {
    if ($settings.Current.ControlType -eq $ct::ListItem) {$settings.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()}
    else {$settings.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}
    Start-Sleep -Milliseconds 700
    Shot 'settings'
}
Choose 'QA Stacked'
$old=History-Ids
Start-Request 'QA STACK'
$new=History-Ids
$kept=@($old.Keys | Where-Object { $new.ContainsKey($_) })
$same=@($kept | Where-Object { $old[$_] -eq $new[$_] })
("300 history turns. Before: "+$old.Count+", after: "+$new.Count+", shared: "+$kept.Count+", identical UIA elements: "+$same.Count) | Set-Content (Join-Path $out 'history-counts.txt') -Encoding UTF8
Shot 'stacked'
Resize 940 470;Shot 'dock-overflow'
$denial=Find-Control $ct::Button @('거부','Deny')
$bounds=$denial.Current.BoundingRectangle
if (-not $denial -or $bounds.IsEmpty -or $denial.Current.IsOffscreen) {throw 'Dock answers offscreen after resize'}
Resize 1130 760
$denial=Find-Control $ct::Button @('거부','Deny')
if ($denial) {
    $denial.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 700
    Shot 'next-in-stack'
    $afterAnswer=History-Ids
    $still=@($new.Keys | Where-Object {$afterAnswer.ContainsKey($_) -and $afterAnswer[$_] -eq $new[$_]})
    ("After the first answer: "+$afterAnswer.Count+" history labels, "+$still.Count+" retained their UIA ids") | Add-Content (Join-Path $out 'history-counts.txt') -Encoding UTF8
}
Choose 'QA Scope';Start-Request 'QA SCOPE';Shot 'scope'
Resize 540 620; Shot 'narrow-stop'; Resize 1130 760
$split=@(Items | Where-Object {$_.Current.ControlType -eq $ct::SplitButton})[0]
if ($split) {
    try {
        $p=$split.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $p.Expand();Start-Sleep -Milliseconds 450;Shot 'scope-menu'
        $item=@(Items | Where-Object {$_.Current.ControlType -eq $ct::MenuItem})[0]
        if ($item) {
            $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
            $current=$item
            while ($current -and $current.Current.ProcessId -eq $proc.Id) {
                $handle=[IntPtr]$current.Current.NativeWindowHandle
                if ($handle -ne [IntPtr]::Zero -and $handle -ne $hwnd) {
                    $pr=New-Object QaWindow+Rect
                    [void][QaWindow]::GetWindowRect($handle,[ref]$pr)
                    if ($pr.Right -gt $pr.Left -and ($pr.Right-$pr.Left) -lt 550 -and ($pr.Bottom-$pr.Top) -lt 400) {
                        $bmp=[Drawing.Bitmap]::new($pr.Right-$pr.Left,$pr.Bottom-$pr.Top)
                        $g=[Drawing.Graphics]::FromImage($bmp);$dc=$g.GetHdc()
                        try {$ok=[QaWindow]::PrintWindow($handle,$dc,2)} finally {$g.ReleaseHdc($dc);$g.Dispose()}
                        if ($ok) {$bmp.Save((Join-Path $out 'scope-menu-popup.png'),[Drawing.Imaging.ImageFormat]::Png)}
                        $bmp.Dispose(); break
                    }
                }
                $current=$walker.GetParent($current)
            }
        }
        $p.Collapse()
    } catch {}
}
$once=Find-Control $ct::Button @('허용','Allow')
if ($once) {
    $once.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 800
    Shot 'local-scope'
    $nextSplit=@(Items | Where-Object {$_.Current.ControlType -eq $ct::SplitButton})[0]
    if ($nextSplit) {
        $menu=$nextSplit.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $menu.Expand();Start-Sleep -Milliseconds 400;Shot 'local-scope-menu';$menu.Collapse()
    }
}
Choose 'QA Question';Start-Request 'QA QUESTION';Shot 'question'
$hover=Find-Control $ct::RadioButton @('Detailed')
if ($hover) {
    $b=$hover.Current.BoundingRectangle
    [void][QaWindow]::SetCursorPos([int]($b.Left+$b.Width/2),[int]($b.Top+$b.Height/2))
    Start-Sleep -Milliseconds 550
    Shot 'question-hover'
}
$detail=Find-Control $ct::RadioButton @('Detailed')
if ($detail) {$detail.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Milliseconds 300;Shot 'question-selected'}
$submit=Find-Control $ct::Button @('답변 제출','Submit answers','제출')
if ($submit -and $submit.Current.IsEnabled) {
    $submit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke();Start-Sleep -Seconds 1;Shot 'question-answered'
}
"Complete" | Set-Content (Join-Path $out 'result.txt')
} catch {
    ($_.Exception.Message + " at line " + $_.InvocationInfo.ScriptLineNumber) | Set-Content (Join-Path $out 'result.txt')
} finally {
    if ($proc -and -not $proc.HasExited) { [void]$proc.CloseMainWindow(); if (-not $proc.WaitForExit(8000)) {$proc.Kill()} }
}

if ((Get-Content (Join-Path $out 'result.txt')) -ne 'Complete') { throw (Get-Content (Join-Path $out 'result.txt')) }

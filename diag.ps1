$ErrorActionPreference = "SilentlyContinue"
$out    = Join-Path $PSScriptRoot "诊断结果.txt"
$lines  = New-Object System.Collections.ArrayList
$issues = New-Object System.Collections.ArrayList
function W($t)   { [void]$lines.Add($t); Write-Host $t }
function BAD($t) { [void]$issues.Add($t); W ("  !! " + $t) }
function KillUV4 { Get-Process UV4 -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 800 }

KillUV4

W "STM32 环境诊断"
W ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
W ("电脑: " + $env:COMPUTERNAME + "   用户: " + $env:USERNAME)
W ("系统: " + (Get-CimInstance Win32_OperatingSystem).Caption)
W ""

# ---------- 先找他自己的工程，后面编译和烧录都用这个 ----------
$mine = @()
$mine += Get-ChildItem $PSScriptRoot -Filter *.uvprojx -Recurse -Depth 3 -EA SilentlyContinue
if ($mine.Count -eq 0) {
    foreach ($r in @("$env:USERPROFILE\Desktop","$env:USERPROFILE\Documents","C:\stm32","D:\stm32","D:\","E:\")) {
        if (Test-Path $r) { $mine += Get-ChildItem $r -Filter *.uvprojx -Recurse -Depth 4 -EA SilentlyContinue }
    }
}
$mine = $mine | Where-Object { $_.FullName -notlike "*03-工程模板*" } |
        Sort-Object @{Expression={
            $a = Get-ChildItem (Join-Path $_.DirectoryName "Objects") -Include *.axf -Recurse -EA SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($a) { $a.LastWriteTime } else { $_.LastWriteTime }
        }} -Descending
$prj = $mine | Select-Object -First 1
if (-not $prj) {
    $t = Join-Path (Split-Path $PSScriptRoot -Parent) "03-工程模板\Project01\Project01.uvprojx"
    if (Test-Path $t) { $prj = Get-Item $t }
}

W "== 1. Keil 安装 =="
$keil = $null; $root = $null; $rte = $null
foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Keil\Products\MDK','HKLM:\SOFTWARE\Keil\Products\MDK') {
    $v = Get-ItemProperty $k
    if ($v.Path) { $keil = $v.Path.TrimEnd('\'); W ("  安装路径: " + $keil); W ("  版本: " + $v.Version); break }
}
if (-not $keil) { BAD "没找到 Keil，要么还没装，要么装的时候出错了" }
else {
    $root = Split-Path $keil -Parent
    W ("  根目录: " + $root)
    foreach ($c in @{n="Arm Compiler 5";f="$keil\ARMCC\bin\armcc.exe";a="--vsn"},
                   @{n="Arm Compiler 6";f="$keil\ARMCLANG\bin\armclang.exe";a="--version"}) {
        if (Test-Path $c.f) {
            $ver = (& $c.f $c.a 2>&1 | Select-String "Component:" | Select-Object -First 1) -replace '.*Component:\s*',''
            W ("  [有] " + $c.n + "   " + $ver)
        } else { W ("  [无] " + $c.n) }
    }
    if (Test-Path "$root\UV4\UV4.exe") { W "  [有] uVision" } else { W "  [无] uVision" }
    if (-not (Test-Path "$keil\ARMCC\bin\armcc.exe")) {
        BAD "没有 Arm Compiler 5。教程的标准库工程编不过，要卸掉换装 MDK 5.36"
    }
    $ini = "$root\TOOLS.INI"
    if (Test-Path $ini) {
        $rte = ((Get-Content $ini | Select-String '^RTEPATH=') -replace 'RTEPATH=','').Trim('"').TrimEnd('\')
        W ("  器件包目录: " + $rte)
    }
}
W ""

W "== 2. 器件包 =="
# 以 TOOLS.INI 里的 RTEPATH 为准，各人装法不同目录名可能不一样，写死会误报
$roots = @()
if ($rte)  { $roots += $rte }
if ($root) { $roots += "$root\ARM\PACK"; $roots += "$root\Arm\Packs" }
$roots += "$env:LOCALAPPDATA\Arm\Packs"
$foundF1 = $false
foreach ($r in ($roots | Select-Object -Unique)) {
    if (-not (Test-Path $r)) { continue }
    $dfp = @(Get-ChildItem "$r\Keil\STM32F1xx_DFP" -Directory)
    $web = "$r\.Web"; $hasWeb = Test-Path $web
    if ($dfp.Count -eq 0 -and -not $hasWeb) { continue }
    W ("  目录: " + $r)
    foreach ($d in $dfp) { W ("    [有] STM32F1xx_DFP " + $d.Name); $foundF1 = $true }
    if ($hasWeb) {
        $n   = @(Get-ChildItem $web -File).Count
        $bad = @(Get-ChildItem $web -Filter *.pdsc | Where-Object { $_.Length -lt 200 }).Count
        W ("    .Web 在线缓存 " + $n + " 个文件，其中可疑的小文件 " + $bad + " 个")
        if ($bad -gt 0) { BAD ("有下坏的索引文件，就是它导致 Cannot load PDSC Files。关掉 Keil 把 " + $web + " 里的文件全删") }
    }
}
if (-not $foundF1) { W "  几个常见位置都没找到 STM32F1xx_DFP。如果工程能正常编译就不用管，说明装在别处了" }
W ""

W "== 3. ST-Link 下载器 =="
$hasStlink = $false
$usb = @(Get-PnpDevice | Where-Object { $_.FriendlyName -match 'ST-?Link|STMicro' })
if ($usb.Count -gt 0) {
    foreach ($d in $usb) { W ("  " + $d.Status + "   " + $d.FriendlyName) }
    $hasStlink = @($usb | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
    if (-not $hasStlink) { BAD "ST-Link 状态不是 OK。多半是没插上，或者驱动没装好" }
} else { BAD "没有检测到 ST-Link 设备。下载器没插上、USB 线只能充电、或者驱动没装" }
$drv = @(pnputil /enum-drivers 2>$null | Select-String -Pattern 'stlink' -SimpleMatch)
if ($drv.Count -gt 0) { W ("  系统驱动库里有 " + $drv.Count + " 条 ST-Link 相关记录") }
else { BAD ("系统驱动库里没有 ST-Link 驱动。去 " + $root + "\ARM\STLink\USBDriver 运行 dpinst_amd64.exe") }
W ""

W "== 4. 编译测试 =="
if (-not $prj)       { BAD "找不到任何工程。把本文件夹复制到你的工程目录里再跑一次" }
elseif (-not $keil)  { W "  Keil 没装，跳过" }
else {
    $uv = "$root\UV4\UV4.exe"
    $blog = Join-Path $env:TEMP "stm32_build.log"
    W ("  工程: " + $prj.FullName)
    KillUV4
    Remove-Item $blog -Force -EA SilentlyContinue
    $p = Start-Process $uv -ArgumentList @("-b", $prj.FullName, "-j0", "-o", $blog) -PassThru -NoNewWindow -Wait
    W ("  退出码: " + $p.ExitCode + "    0=成功 1=有警告 2以上=失败")
    if ($p.ExitCode -ge 2) { BAD "编译失败，看下面的报错" }
    if (Test-Path $blog) {
        $key = Get-Content $blog -Encoding Default | Select-String "Program Size|Error\(s\)|error:|warning:" | Select-Object -First 10
        if ($key) { foreach ($x in $key) { W ("    " + $x) } } else { W ("    日志无关键行，完整日志 " + $blog) }
    }
    KillUV4
}
W ""

W "== 5. 烧录测试 =="
if (-not $prj -or -not $keil) { W "  没工程或 Keil 没装，跳过" }
elseif (-not $hasStlink) {
    W "  ST-Link 不是 OK 状态，跳过烧录测试"
    W "  把下载器和板子都插好、保持连接，再跑一次这个脚本，才能测到烧录"
} else {
    $uv = "$root\UV4\UV4.exe"
    $flog = Join-Path $env:TEMP "stm32_flash.log"
    Remove-Item $flog -Force -EA SilentlyContinue
    W ("  正在烧录: " + $prj.Name + "   最多等 90 秒")
    $p = Start-Process $uv -ArgumentList @("-f", $prj.FullName, "-o", $flog) -PassThru -NoNewWindow
    # 烧录失败时 Keil 会弹模态框等人点，后台盯着自动回车关掉
    $killer = Start-Job {
        Add-Type -AssemblyName System.Windows.Forms
        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Seconds 1
            if (Get-Process UV4 -EA SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Error|Cortex-M|ULINK|μVision' }) {
                [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            }
        }
    }
    if ($p.WaitForExit(90000)) { W ("  退出码: " + $p.ExitCode) }
    else { Stop-Process -Id $p.Id -Force; BAD "烧录 90 秒没结束，弹了对话框在等确认" }
    Stop-Job $killer -EA SilentlyContinue; Remove-Job $killer -Force -EA SilentlyContinue
    if (Test-Path $flog) {
        $fl = Get-Content $flog -Encoding Default
        foreach ($x in ($fl | Select-Object -First 20)) { W ("    " + $x) }
        if ($fl -match "Verify OK|Application running") { W "  烧录成功" }
        elseif ($fl -match "error|Error|failed|Failed|No .* found") { BAD "烧录失败，报错见上面" }
    } else { BAD "没有生成烧录日志" }
    KillUV4
}
W ""

W "== 6. 工程配置与代码 =="
if (-not $prj) { W "  没找到工程" }
else {
  foreach ($f in ($mine | Select-Object -First 2)) {
    W ""
    W ("  ---- " + $f.FullName)
    $x = Get-Content $f.FullName -Raw -Encoding UTF8
    foreach ($tag in "Device","uAC6","CreateHexFile") {
        $m = [regex]::Match($x, "<$tag>(.*?)</$tag>", "Singleline")
        if ($m.Success) { W ("       " + $tag + " = " + $m.Groups[1].Value.Trim()) }
    }
    foreach ($tag in "Define","IncludePath") {
        $m = [regex]::Matches($x, "<$tag>(.*?)</$tag>", "Singleline") | Where-Object { $_.Groups[1].Value.Trim() } | Select-Object -First 1
        if ($m) { W ("       " + $tag + " = " + $m.Groups[1].Value.Trim()) }
    }
    if ($x -notmatch "USE_STDPERIPH_DRIVER") { BAD "工程没定义 USE_STDPERIPH_DRIVER，编译会报几十上百个错" }
    if ([regex]::Match($x,"<uAC6>(.*?)</uAC6>","Singleline").Groups[1].Value.Trim() -eq "1") {
        BAD "工程选的是 Arm Compiler 6，标准库编不过，要在魔术棒 Target 标签里改回 AC5"
    }
    $opt = [IO.Path]::ChangeExtension($f.FullName, ".uvoptx")
    if (Test-Path $opt) {
        $o = Get-Content $opt -Raw -Encoding UTF8
        $mon = [regex]::Match($o, "<pMon>(.*?)</pMon>", "Singleline").Groups[1].Value.Trim()
        W ("       调试器 = " + $(if ($mon) { $mon } else { "没选，还是默认的" }))
        if ($mon -notmatch "STLink") { BAD "工程没选 ST-Link Debugger，点下载会报找不到设备" }
        $fo = [regex]::Match($o, "-FO(\d+)").Groups[1].Value
        if ($fo) {
            $v = [int]$fo
            W ("       烧录选项 -FO" + $v + "   擦除=" + [bool]($v -band 1) + " 编程=" + [bool]($v -band 2) + " 校验=" + [bool]($v -band 4) + " 烧完复位运行=" + [bool]($v -band 8))
            if (-not ($v -band 8)) { BAD "没勾 Reset and Run，烧完芯片不会自动运行，看起来就像没反应" }
        }
    } else { W "       没有 .uvoptx，这个工程还没在 Keil 里打开配置过" }
    $obj = Join-Path $f.DirectoryName "Objects"
    $art = Get-ChildItem $obj -Include *.hex,*.axf -Recurse -EA SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($art) { foreach ($a in ($art | Select-Object -First 2)) { W ("       产物 " + $a.Name + "   " + $a.Length + " 字节   " + $a.LastWriteTime) } }
    else { BAD "Objects 里没有 hex 或 axf，这个工程还没编译成功过" }

    # 只取他自己写的代码。ST 官方模板文件全是空函数和注释，是噪音
    $skip = @("stm32f10x_it.c","system_stm32f10x.c","core_cm3.c")
    $srcs = @()
    foreach ($d in @((Join-Path $f.DirectoryName "User"), $f.DirectoryName)) {
        if (Test-Path $d) { $srcs += Get-ChildItem $d -Filter *.c -EA SilentlyContinue | Where-Object { $skip -notcontains $_.Name } }
    }
    foreach ($s in ($srcs | Sort-Object LastWriteTime -Descending | Select-Object -First 4)) {
        W ""
        W ("       ==== " + $s.Name + "   " + $s.LastWriteTime + " ====")
        $all = Get-Content $s.FullName -Encoding Default
        foreach ($ln in ($all | Select-Object -First 100)) { W ("       | " + $ln) }
        if ($all.Count -gt 100) { W ("       | ...（共 " + $all.Count + " 行，只列前 100 行）") }
    }
  }
}
W ""
W "== 诊断结束 =="

# ---------- 问题摘要放到文件最前面，省得从头读 ----------
$head = New-Object System.Collections.ArrayList
if ($issues.Count -eq 0) {
    [void]$head.Add("【摘要】没发现异常。环境和工程配置都正常。")
    [void]$head.Add("如果实际现象还是不对，问题多半在硬件：跳线位置、接线、板子本身。")
} else {
    [void]$head.Add("【摘要】发现 " + $issues.Count + " 处问题，按顺序处理：")
    $i = 1
    foreach ($x in $issues) { [void]$head.Add("  " + $i + ". " + $x); $i++ }
}
[void]$head.Add("")
[void]$head.Add(("=" * 56))
[void]$head.Add("")

($head + $lines) | Out-File -FilePath $out -Encoding utf8
Write-Host ""
Write-Host ("结果已保存到: " + $out) -ForegroundColor Green
if ($issues.Count -gt 0) { Write-Host ("发现 " + $issues.Count + " 处问题，详见文件开头的摘要") -ForegroundColor Yellow }
Write-Host "按回车键关闭" -ForegroundColor Yellow
[void](Read-Host)

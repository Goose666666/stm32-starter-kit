$ErrorActionPreference = "SilentlyContinue"
$out = Join-Path $PSScriptRoot "诊断结果.txt"
$lines = New-Object System.Collections.ArrayList
function W($t) { [void]$lines.Add($t); Write-Host $t }
function KillUV4 { Get-Process UV4 -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 800 }

KillUV4

W "STM32 环境诊断"
W ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
W ("电脑: " + $env:COMPUTERNAME + "   用户: " + $env:USERNAME)
W ("系统: " + (Get-CimInstance Win32_OperatingSystem).Caption)
W ""

W "== 1. Keil 安装 =="
$keil = $null; $root = $null
foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Keil\Products\MDK','HKLM:\SOFTWARE\Keil\Products\MDK') {
    $v = Get-ItemProperty $k
    if ($v.Path) { $keil = $v.Path.TrimEnd('\'); W ("  安装路径: " + $keil); W ("  版本: " + $v.Version); break }
}
if (-not $keil) {
    W "  没找到 Keil。要么还没装，要么装的时候出错了"
} else {
    $root = Split-Path $keil -Parent
    W ("  根目录: " + $root)
    # 只对编译器取版本号。UV4.exe 不认 --version，硬跑会把图形界面拉起来把脚本卡死
    foreach ($c in @{n="Arm Compiler 5";f="$keil\ARMCC\bin\armcc.exe";a="--vsn"},
                   @{n="Arm Compiler 6";f="$keil\ARMCLANG\bin\armclang.exe";a="--version"}) {
        if (Test-Path $c.f) {
            $ver = (& $c.f $c.a 2>&1 | Select-String "Component:" | Select-Object -First 1) -replace '.*Component:\s*',''
            W ("  [有] " + $c.n + "   " + $ver)
        } else { W ("  [无] " + $c.n) }
    }
    if (Test-Path "$root\UV4\UV4.exe") { W "  [有] uVision" } else { W "  [无] uVision" }
    if (-not (Test-Path "$keil\ARMCC\bin\armcc.exe")) {
        W ""
        W "  !!!! 没有 Arm Compiler 5 !!!!"
        W "  教程的标准库工程默认就是 AC5 编的，缺了它一编译就报几百个错。"
        W "  说明装的是 5.37 或更新的版本。卸掉，换装 MDK 5.36。"
    }
    $ini = "$root\TOOLS.INI"
    if (Test-Path $ini) {
        $script:rtePath = ((Get-Content $ini | Select-String '^RTEPATH=') -replace 'RTEPATH=','').Trim('"').TrimEnd('\')
        W ("  器件包目录: " + $script:rtePath)
    }
}
W ""

W "== 2. 器件包 =="
$packRoots = @()
# 以配置文件里的 RTEPATH 为准。各人装法不同，目录名可能是 ARM\PACK 也可能是 Arm\Packs，写死会误报
if ($script:rtePath) { $packRoots += $script:rtePath }
if ($root) { $packRoots += "$root\ARM\PACK"; $packRoots += "$root\Arm\Packs" }
$packRoots += "$env:LOCALAPPDATA\Arm\Packs"
$foundF1 = $false
foreach ($r in ($packRoots | Select-Object -Unique)) {
    if (-not (Test-Path $r)) { continue }
    $dfp = @(Get-ChildItem "$r\Keil\STM32F1xx_DFP" -Directory)
    $web = "$r\.Web"
    $hasWeb = Test-Path $web
    if ($dfp.Count -eq 0 -and -not $hasWeb) { W ("  目录: " + $r + "   空的，忽略"); continue }
    W ("  目录: " + $r)
    foreach ($d in $dfp) { W ("    [有] STM32F1xx_DFP " + $d.Name); $foundF1 = $true }
    if ($dfp.Count -eq 0) { W "    [无] STM32F1xx_DFP" }
    if ($hasWeb) {
        $n = @(Get-ChildItem $web -File).Count
        $bad = @(Get-ChildItem $web -Filter *.pdsc | Where-Object { $_.Length -lt 200 }).Count
        W ("    .Web 在线缓存 " + $n + " 个文件，其中可疑的小文件 " + $bad + " 个")
        if ($bad -gt 0) {
            W "    !! 有下坏的索引文件，就是它导致 Cannot load PDSC Files"
            W ("    !! 关掉 Keil，把 " + $web + " 里的文件全删，再用离线包装")
        }
    }
}
if (-not $foundF1) { W "  !! 没装 STM32F1xx_DFP，新建工程时芯片列表会是空的" }
W ""

W "== 3. ST-Link 下载器 =="
$hasStlink = $false
$usb = @(Get-PnpDevice | Where-Object { $_.FriendlyName -match 'ST-?Link|STMicro' })
if ($usb.Count -gt 0) {
    $hasStlink = @($usb | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
    foreach ($d in $usb) { W ("  " + $d.Status + "   " + $d.FriendlyName) }
    if (@($usb | Where-Object { $_.Status -ne 'OK' }).Count -gt 0) { W "  !! 有设备状态不是 OK，多半是驱动没装好" }
} else {
    W "  没有检测到 ST-Link 设备"
    W "  可能原因：下载器没插上、USB 线只能充电不能传数据、驱动没装"
}
$drv = @(pnputil /enum-drivers 2>$null | Select-String -Pattern 'stlink' -SimpleMatch)
if ($drv.Count -gt 0) { W ("  系统驱动库里有 " + $drv.Count + " 条 ST-Link 相关记录") }
else {
    W "  !! 系统驱动库里没有 ST-Link 驱动"
    if ($root) { W ("  !! 去 " + $root + "\ARM\STLink\USBDriver 运行 dpinst_amd64.exe") }
}
W ""

# 优先用本包自带的工程模板，找不到再在附近搜
$kit = Split-Path $PSScriptRoot -Parent
$prj = $null
$fixed = Join-Path $kit "03-工程模板\Project01\Project01.uvprojx"
if (Test-Path $fixed) { $prj = Get-Item $fixed }
if (-not $prj) { $prj = Get-ChildItem $PSScriptRoot -Filter *.uvprojx -Recurse -Depth 3 | Select-Object -First 1 }
if (-not $prj) { $prj = Get-ChildItem $kit -Filter *.uvprojx -Recurse -Depth 4 | Select-Object -First 1 }

W "== 4. 编译测试 =="
if (-not $prj)  { W "  找不到工程文件，跳过" }
elseif (-not $keil) { W "  Keil 没装，跳过" }
else {
    $uv = "$root\UV4\UV4.exe"
    $blog = Join-Path $env:TEMP "stm32_build.log"
    W ("  工程: " + $prj.FullName)
    KillUV4
    Remove-Item $blog -Force -EA SilentlyContinue
    $p = Start-Process $uv -ArgumentList @("-b", $prj.FullName, "-j0", "-o", $blog) -PassThru -NoNewWindow -Wait
    W ("  退出码: " + $p.ExitCode + "    0=成功 1=有警告 2以上=失败")
    if (Test-Path $blog) {
        $bl = Get-Content $blog -Encoding Default
        $key = $bl | Select-String "Program Size|Error\(s\)|error:|warning:" | Select-Object -First 10
        if ($key) { foreach ($x in $key) { W ("    " + $x) } } else { W "    日志里没有关键行，完整日志见 $blog" }
    } else { W "    没有生成编译日志" }
    KillUV4
}
W ""

W "== 5. 烧录测试 =="
if (-not $hasStlink) {
    W "  没检测到 ST-Link，跳过烧录测试。"
    W "  先把下载器插上、驱动装好，再跑一次这个脚本，才能测烧录。"
} elseif ($prj -and $keil) {
    $uv = "$root\UV4\UV4.exe"
    $flog = Join-Path $env:TEMP "stm32_flash.log"
    Remove-Item $flog -Force -EA SilentlyContinue
    $p = Start-Process $uv -ArgumentList @("-f", $prj.FullName, "-o", $flog) -PassThru -NoNewWindow
    # 烧录失败时 Keil 会弹模态框等人点，这里后台盯着自动点掉
    $killer = Start-Job {
        Add-Type -AssemblyName System.Windows.Forms
        for ($i=0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            $w = Get-Process -Name UV4 -EA SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Error|Cortex-M|ULINK|Vision' }
            if ($w) { [System.Windows.Forms.SendKeys]::SendWait("{ENTER}") }
        }
    }
    if ($p.WaitForExit(90000)) { W ("  退出码: " + $p.ExitCode) }
    else {
        Stop-Process -Id $p.Id -Force
        W "  90 秒没结束，说明弹了对话框在等人确认"
        W "  这种情况通常就是找不到下载器或者板子没连上"
    }
    Stop-Job $killer -EA SilentlyContinue; Remove-Job $killer -Force -EA SilentlyContinue
    if (Test-Path $flog) { Get-Content $flog -Encoding Default | Select-Object -First 12 | ForEach-Object { W ("    " + $_) } }
    else { W "    没有生成烧录日志" }
    KillUV4
} else { W "  没找到工程或 Keil 没装，跳过" }
W ""

W "== 6. 当前工程情况 =="
# 找他最近在弄的工程。优先本脚本所在目录往下找，找不到再扫几个常见位置
$mine = @()
$mine += Get-ChildItem $PSScriptRoot -Filter *.uvprojx -Recurse -Depth 3 -EA SilentlyContinue
if ($mine.Count -eq 0) {
    $roots = @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "D:\", "E:\", "C:\stm32", "D:\stm32")
    foreach ($r in $roots) {
        if (Test-Path $r) { $mine += Get-ChildItem $r -Filter *.uvprojx -Recurse -Depth 4 -EA SilentlyContinue }
    }
}
# 排除本包自带的模板，那不是他在写的
$mine = $mine | Where-Object { $_.FullName -notlike "*03-工程模板*" } |
        Sort-Object @{Expression={
            $axf = Get-ChildItem (Join-Path $_.DirectoryName "Objects") -Include *.axf -Recurse -EA SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($axf) { $axf.LastWriteTime } else { $_.LastWriteTime }
        }} -Descending | Select-Object -First 3

if ($mine.Count -eq 0) {
    W "  没找到他自己的工程。把本文件夹整个复制到工程目录里再跑一次，就能采到。"
} else {
    foreach ($f in $mine) {
        W ""
        W ("  ---- 工程: " + $f.FullName)
        W ("       最后修改: " + $f.LastWriteTime)
        $x = Get-Content $f.FullName -Raw -Encoding UTF8
        foreach ($tag in "Device","uAC6","CreateHexFile") {
            $m = [regex]::Match($x, "<$tag>(.*?)</$tag>", "Singleline")
            if ($m.Success) { W ("       " + $tag + " = " + $m.Groups[1].Value.Trim()) }
        }
        # Define 和 IncludePath 要取 Cads 段里的，直接全文匹配会拿到汇编器那份空值
        $cads = [regex]::Match($x, "<Cads>.*?</Cads>", "Singleline").Value
        if (-not $cads) { $cads = $x }
        foreach ($tag in "Define","IncludePath") {
            $m = [regex]::Match($cads, "<$tag>(.*?)</$tag>", "Singleline")
            $val = $m.Groups[1].Value.Trim()
            W ("       " + $tag + " = " + $(if ($val) { $val } else { "空" }))
        }
        if ($x -notmatch "USE_STDPERIPH_DRIVER") { W "       !! Define 里没有 USE_STDPERIPH_DRIVER，编译会报几十上百个错" }
        if ([regex]::Match($x,"<uAC6>(.*?)</uAC6>","Singleline").Groups[1].Value.Trim() -eq "1") {
            W "       !! 这个工程选的是 Arm Compiler 6，标准库编不过，要改回 AC5"
        }

        # 调试器与烧录设置在 uvoptx 里
        $opt = [IO.Path]::ChangeExtension($f.FullName, ".uvoptx")
        if (Test-Path $opt) {
            $o = Get-Content $opt -Raw -Encoding UTF8
            $mon = [regex]::Match($o, "<pMon>(.*?)</pMon>", "Singleline").Groups[1].Value.Trim()
            W ("       调试器 = " + $(if ($mon) { $mon } else { "没选，还是默认的" }))
            if ($mon -notmatch "STLink") { W "       !! 没选 ST-Link Debugger，点下载会报找不到设备" }
            $flags = [regex]::Matches($o, "<Name>(-[^<]*)</Name>") | ForEach-Object { $_.Groups[1].Value }
            if ($flags) { W ("       烧录参数 = " + ($flags -join " | ")) }
        } else { W "       没有 .uvoptx，说明这个工程还没在 Keil 里打开配置过" }

        # 编译产物在不在，什么时候生成的
        $obj = Join-Path $f.DirectoryName "Objects"
        if (Test-Path $obj) {
            $art = Get-ChildItem $obj -Include *.hex,*.axf -Recurse -EA SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($art) { foreach ($a in $art | Select-Object -First 2) { W ("       产物 " + $a.Name + "   " + $a.Length + " 字节   " + $a.LastWriteTime) } }
            else { W "       !! Objects 目录里没有 hex 或 axf，说明还没编译成功过" }
        } else { W "       !! 没有 Objects 目录，还没编译过" }

        # 他写的代码。只取 User 目录和根目录下的 .c，掐掉太长的
        $srcs = @()
        foreach ($d in @((Join-Path $f.DirectoryName "User"), $f.DirectoryName)) {
            if (Test-Path $d) { $srcs += Get-ChildItem $d -Filter *.c -EA SilentlyContinue }
        }
        $srcs = $srcs | Sort-Object @{Expression={ if ($_.Name -ieq "main.c") { 0 } else { 1 } }},
                                    @{Expression={ $_.LastWriteTime }; Descending=$true} |
                Select-Object -First 3
        foreach ($s in $srcs) {
            W ""
            W ("       ==== " + $s.Name + "   " + $s.LastWriteTime + " ====")
            $body = Get-Content $s.FullName -Encoding Default -TotalCount 120
            foreach ($ln in $body) { W ("       | " + $ln) }
            if ((Get-Content $s.FullName -Encoding Default).Count -gt 120) { W "       | ...（后面省略）" }
        }
    }
}
W ""

W "== 环境正常时应该是什么样 =="
W "  Keil 版本            V5.36"
W "  Arm Compiler 5       有，5.06 update 7"
W "  STM32F1xx_DFP        有"
W "  .Web 可疑小文件      0 个"
W "  ST-Link              状态 OK，插上板子后能看到"
W "  编译退出码           0，日志里有 Program Size 和 0 Error(s)"
W "  烧录退出码           0，日志里有 Verify OK 或 Application running"
W ""
W "== 诊断结束 =="
W "把本文件夹里的「诊断结果.txt」发回去即可"

$lines | Out-File -FilePath $out -Encoding utf8
Write-Host ""
Write-Host ("结果已保存到: " + $out) -ForegroundColor Green
Write-Host "按回车键关闭" -ForegroundColor Yellow
[void](Read-Host)

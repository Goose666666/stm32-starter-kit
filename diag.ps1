$ErrorActionPreference = "SilentlyContinue"
$out    = Join-Path $PSScriptRoot "诊断结果.txt"
$lines  = New-Object System.Collections.ArrayList
$issues = New-Object System.Collections.ArrayList
function W($t) { [void]$lines.Add($t); Write-Host $t }
function BAD($what, $how) {
    [void]$issues.Add(@{ what = $what; how = $how })
    W ("  !! " + $what)
    if ($how) { W ("     怎么办：" + $how) }
}
$script:mayKill = $true
function KillUV4 {
    if (-not $script:mayKill) { return }
    Get-Process UV4 -EA SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

# Keil 是单实例程序，命令行编译要求它没在运行。开跑前先征得同意，别把没保存的代码弄丢
$script:closedKeil = $false
if (Get-Process UV4 -EA SilentlyContinue) {
    Write-Host ""
    Write-Host "  检测到 Keil 正在运行" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  要测编译和烧录，必须先关掉 Keil，否则测不了。"
    Write-Host "  请先切到 Keil 按 Ctrl+S 保存你的代码。"
    Write-Host ""
    Write-Host "  保存好了就直接按回车，脚本会关掉 Keil 再继续。"
    Write-Host "  不想关的话，输入 N 再按回车，跳过编译和烧录这两项检查。"
    Write-Host ""
    $ans = Read-Host "  按回车继续，或输入 N 跳过"
    if ($ans -match '^\s*[Nn]') {
        $script:mayKill = $false
        Write-Host "  好，保留 Keil 不动，跳过编译和烧录测试" -ForegroundColor Yellow
    } else {
        $script:closedKeil = $true
        Write-Host "  正在关闭 Keil" -ForegroundColor Yellow
    }
    Write-Host ""
}

KillUV4

W "STM32 环境诊断"
W ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
W ("电脑: " + $env:COMPUTERNAME + "   用户: " + $env:USERNAME)
W ("系统: " + (Get-CimInstance Win32_OperatingSystem).Caption)
W ""

# ---------- 先找工程，后面编译烧录代码检查都用它 ----------
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
if (-not $keil) { BAD "没找到 Keil" "按安装说明装 MDK 5.36" }
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
        BAD "没有 Arm Compiler 5，教程的标准库工程编不过" "卸掉现在这个 Keil，换装 MDK 5.36，安装包在发的那个链接里"
    }
    $ini = "$root\TOOLS.INI"
    if (Test-Path $ini) {
        $rte = ((Get-Content $ini | Select-String '^RTEPATH=') -replace 'RTEPATH=','').Trim('"').TrimEnd('\')
        W ("  器件包目录: " + $rte)
    }
}
W ""

W "== 2. 器件包 =="
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
        if ($bad -gt 0) { BAD "器件包在线缓存里有下坏的文件，会报 Cannot load PDSC Files" ("关掉 Keil，把 " + $web + " 里的文件全删，然后双击离线包重装") }
    }
}
if (-not $foundF1) { W "  常见位置没找到 STM32F1xx_DFP。工程能正常编译就不用管" }
W ""

W "== 3. ST-Link 下载器 =="
$hasStlink = $false
$usb = @(Get-PnpDevice | Where-Object { $_.FriendlyName -match 'ST-?Link|STMicro' })
if ($usb.Count -gt 0) {
    foreach ($d in $usb) { W ("  " + $d.Status + "   " + $d.FriendlyName) }
    $hasStlink = @($usb | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
    if (-not $hasStlink) { BAD "ST-Link 状态不是 OK" "把 ST-Link 重新插一次电脑 USB。还不行就换根数据线，有些线只能充电" }
} else { BAD "没检测到 ST-Link 下载器" "把 ST-Link 插到电脑 USB 上。已经插了就换根数据线试试，或者装驱动" }
$drv = @(pnputil /enum-drivers 2>$null | Select-String -Pattern 'stlink' -SimpleMatch)
if ($drv.Count -gt 0) { W ("  系统驱动库里有 " + $drv.Count + " 条 ST-Link 相关记录") }
else { BAD "系统里没装 ST-Link 驱动" ("打开 " + $root + "\ARM\STLink\USBDriver，运行 dpinst_amd64.exe") }
W ""

W "== 4. 编译测试 =="
$buildOK = $false
if (-not $script:mayKill) { W "  你选了保留 Keil 不关，这项跳过" }
elseif (-not $prj)  { BAD "找不到任何 Keil 工程" "把这个「诊断工具」文件夹整个复制到你的工程目录里，再双击运行一次" }
elseif (-not $keil) { W "  Keil 没装，跳过" }
else {
    $uv = "$root\UV4\UV4.exe"
    $blog = Join-Path $env:TEMP "stm32_build.log"
    W ("  工程: " + $prj.FullName)
    KillUV4
    Remove-Item $blog -Force -EA SilentlyContinue
    $p = Start-Process $uv -ArgumentList @("-b", $prj.FullName, "-j0", "-o", $blog) -PassThru -NoNewWindow -Wait
    W ("  退出码: " + $p.ExitCode + "    0=成功 1=有警告 2以上=失败")
    if ($p.ExitCode -lt 2) { $buildOK = $true }
    else { BAD "编译不通过" "看下面几行报错。多半是宏没定义或者头文件路径漏了，详见安装说明的排查章节" }
    if (Test-Path $blog) {
        $key = Get-Content $blog -Encoding Default | Select-String "Program Size|Error\(s\)|error:|warning:" | Select-Object -First 10
        foreach ($x in $key) { W ("    " + $x) }
    }
    KillUV4
}
W ""

W "== 5. 烧录测试 =="
$flashOK = $false
if (-not $script:mayKill) { W "  你选了保留 Keil 不关，这项跳过" }
elseif (-not $prj -or -not $keil) { W "  没工程或 Keil 没装，跳过" }
elseif (-not $hasStlink) {
    W "  ST-Link 不是 OK 状态，跳过烧录测试"
    W "  把下载器和板子都接好、保持连接，再跑一次这个脚本才能测烧录"
} else {
    $uv = "$root\UV4\UV4.exe"
    $flog = Join-Path $env:TEMP "stm32_flash.log"
    Remove-Item $flog -Force -EA SilentlyContinue
    W ("  正在烧录 " + $prj.Name + "，最多等 90 秒")
    $p = Start-Process $uv -ArgumentList @("-f", $prj.FullName, "-o", $flog) -PassThru -NoNewWindow
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
    else { Stop-Process -Id $p.Id -Force; BAD "烧录卡住 90 秒没结束" "多半弹了对话框。检查板子有没有通电、四根杜邦线接牢没有" }
    Stop-Job $killer -EA SilentlyContinue; Remove-Job $killer -Force -EA SilentlyContinue
    if (Test-Path $flog) {
        $fl = Get-Content $flog -Encoding Default
        foreach ($x in ($fl | Select-Object -First 20)) { W ("    " + $x) }
        if ($fl -match "Verify OK|Application running") { $flashOK = $true; W "  烧录成功" }
        elseif ($fl -match "No .*Device found") { BAD "烧录时找不到调试器" "工程里选的调试器不对。魔术棒 -> Debug 标签 -> 右上角下拉选 ST-Link Debugger" }
        elseif ($fl -match "Cannot access|not connected|No target") { BAD "连不上芯片" "查四根杜邦线：SWDIO SWCLK GND 3.3V 有没有接错或松动。再确认板子上电源灯亮着" }
        elseif ($fl -match "error|Error|failed|Failed") { BAD "烧录失败" "报错原文在上面几行，发给能帮你的人看" }
    } else { BAD "没有生成烧录日志" "Keil 可能没正常启动，重跑一次脚本" }
    KillUV4
}
W ""

W "== 6. 工程配置 =="
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
    if ($x -notmatch "USE_STDPERIPH_DRIVER") {
        BAD "工程没定义 USE_STDPERIPH_DRIVER" "魔术棒 -> C/C++ 标签 -> Define 输入框里填 USE_STDPERIPH_DRIVER"
    }
    if ([regex]::Match($x,"<uAC6>(.*?)</uAC6>","Singleline").Groups[1].Value.Trim() -eq "1") {
        BAD "工程选的是 Arm Compiler 6，标准库编不过" "魔术棒 -> Target 标签 -> ARM Compiler 那一栏改成 Version 5"
    }
    $opt = [IO.Path]::ChangeExtension($f.FullName, ".uvoptx")
    if (Test-Path $opt) {
        $o = Get-Content $opt -Raw -Encoding UTF8
        $mon = [regex]::Match($o, "<pMon>(.*?)</pMon>", "Singleline").Groups[1].Value.Trim()
        W ("       调试器 = " + $(if ($mon) { $mon } else { "没选" }))
        if ($mon -notmatch "STLink") { BAD "工程没选 ST-Link Debugger" "魔术棒 -> Debug 标签 -> 右上角下拉选 ST-Link Debugger" }
        $fo = [regex]::Match($o, "-FO(\d+)").Groups[1].Value
        if ($fo) {
            $v = [int]$fo
            W ("       烧录选项 -FO" + $v + "   擦除=" + [bool]($v -band 1) + " 编程=" + [bool]($v -band 2) + " 校验=" + [bool]($v -band 4) + " 烧完复位运行=" + [bool]($v -band 8))
            if (-not ($v -band 8)) { BAD "没勾 Reset and Run，烧完芯片不自动跑，看着就像没反应" "魔术棒 -> Flash Download 标签 -> 勾上 Reset and Run" }
        }
    } else { W "       没有 .uvoptx，这个工程还没在 Keil 里打开配置过" }
    $art = Get-ChildItem (Join-Path $f.DirectoryName "Objects") -Include *.hex,*.axf -Recurse -EA SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($art) { foreach ($a in ($art | Select-Object -First 2)) { W ("       产物 " + $a.Name + "   " + $a.Length + " 字节   " + $a.LastWriteTime) } }
    else { BAD "从来没编译成功过，Objects 里没有产物" "在 Keil 里点编译按钮，把报错解决掉" }
  }
}
W ""

W "== 7. 代码检查 =="
# 针对江协科技教程前十集的典型写法错误
if (-not $prj) { W "  没找到工程，跳过" }
else {
    $skip = @("stm32f10x_it.c","system_stm32f10x.c","core_cm3.c")
    $srcs = @()
    foreach ($d in @((Join-Path $prj.DirectoryName "User"), $prj.DirectoryName, (Join-Path $prj.DirectoryName "Hardware"))) {
        if (Test-Path $d) { $srcs += Get-ChildItem $d -Filter *.c -EA SilentlyContinue | Where-Object { $skip -notcontains $_.Name } }
    }
    if ($srcs.Count -eq 0) { W "  没找到你写的 .c 文件" }
    foreach ($s in ($srcs | Sort-Object LastWriteTime -Descending | Select-Object -First 4)) {
        $code = (Get-Content $s.FullName -Encoding Default) -join "`n"
        W ""
        W ("  ==== " + $s.Name + "   " + $s.LastWriteTime + " ====")

        # 用了某个 GPIO 口却没开它的时钟，这是最常见的错
        foreach ($port in "A","B","C","D","E") {
            if ($code -match ("GPIO" + $port + "\s*,") -and $code -notmatch ("RCC_APB2Periph_GPIO" + $port)) {
                BAD ($s.Name + " 里用了 GPIO" + $port + " 但没开它的时钟，这个口不会工作") ("在 GPIO_Init 之前加一行：RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIO" + $port + ", ENABLE);")
            }
        }
        # PC13 是板载灯，低电平点亮，而且限速 2MHz
        if ($code -match "GPIO_Pin_13" -and $code -match "GPIOC") {
            if ($code -match "GPIO_Speed_50MHz") {
                BAD ($s.Name + " 里 PC13 用了 GPIO_Speed_50MHz，超出这个引脚 2MHz 的上限") "把 GPIO_Speed_50MHz 改成 GPIO_Speed_2MHz"
            }
            if ($code -match "GPIO_SetBits\s*\(\s*GPIOC\s*,\s*GPIO_Pin_13" -and $code -notmatch "GPIO_ResetBits\s*\(\s*GPIOC\s*,\s*GPIO_Pin_13") {
                BAD ($s.Name + " 里想点亮板载灯却用了 GPIO_SetBits。PC13 是低电平点亮，SetBits 是熄灭") "把 GPIO_SetBits 改成 GPIO_ResetBits"
            }
        }
        # main 里没有死循环，程序跑完就飞了
        if ($s.Name -eq "main.c" -and $code -match "int\s+main" -and $code -notmatch "while\s*\(\s*1\s*\)" -and $code -notmatch "for\s*\(\s*;\s*;\s*\)") {
            BAD "main.c 里没有 while(1) 死循环，程序执行完会跑飞，现象是灯闪一下就没了" "在 main 函数末尾加上 while(1){}"
        }
        # 空循环延时被编译器优化掉
        if ($code -match "for\s*\(\s*\w+\s*=\s*0\s*;[^;]*;\s*\w+\s*\+\+\s*\)\s*;" -and $code -notmatch "volatile") {
            BAD ($s.Name + " 里用空 for 循环做延时，但变量没加 volatile，可能被编译器优化掉导致延时无效") "把延时变量声明成 volatile，或者直接用教程给的 Delay 模块"
        }
        W "  检查完毕"
    }
}
W ""
W "== 诊断结束 =="

# ---------- 结论和摘要放最前面 ----------
$head = New-Object System.Collections.ArrayList
if ($issues.Count -eq 0) {
    [void]$head.Add("【结论】没查出问题。环境、工程配置、代码都正常。")
    if ($flashOK) { [void]$head.Add("烧录也成功了。如果板子上还是没反应，问题在硬件：") }
    else          { [void]$head.Add("如果板子上没反应，先看这几条硬件问题：") }
    [void]$head.Add("  · 板子有没有电。板子只能有一路电源，要么 ST-Link 的 3.3V 线，要么板子自己的 USB，不能两个都接")
    [void]$head.Add("  · 板子上的电源灯亮不亮，不亮就是没通电")
    [void]$head.Add("  · 两个黄色跳线帽都要在 0 的位置，BOOT0 拨到 1 的话芯片不执行你的程序")
    [void]$head.Add("  · 四根杜邦线有没有插牢、有没有插错位")
} else {
    [void]$head.Add("【结论】发现 " + $issues.Count + " 处问题，从上到下依次解决：")
    [void]$head.Add("")
    $i = 1
    foreach ($x in $issues) {
        [void]$head.Add("  " + $i + ". " + $x.what)
        if ($x.how) { [void]$head.Add("     怎么办：" + $x.how) }
        [void]$head.Add("")
        $i++
    }
    [void]$head.Add("解决完再跑一次这个脚本，看问题还在不在。")
}
[void]$head.Add("")
[void]$head.Add(("=" * 58))
[void]$head.Add("")

($head + $lines) | Out-File -FilePath $out -Encoding utf8
Write-Host ""
if ($issues.Count -eq 0) { Write-Host "没查出问题，详见文件开头的结论" -ForegroundColor Green }
else { Write-Host ("发现 " + $issues.Count + " 处问题，打开文件看开头的结论，一条条解决") -ForegroundColor Yellow }
Write-Host ("结果已保存到: " + $out) -ForegroundColor Green
if ($script:closedKeil) {
    Write-Host ""
    Write-Host "刚才为了测编译，脚本把 Keil 关掉了，现在可以重新打开继续用" -ForegroundColor Yellow
}
Write-Host "按回车键关闭" -ForegroundColor Yellow
[void](Read-Host)

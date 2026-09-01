# STM32 入门环境安装包

配合江协科技《STM32入门教程-2023版》的环境安装资料。芯片 STM32F103C8T6，用标准库，不是 HAL 库。

## 先看这个

**[安装说明（网页版）](https://goose666666.github.io/stm32-starter-kit/)**

6 步装完环境，带出错排查。手机电脑都能看。

## 下载完整安装包

**[从 Releases 下载 STM32入门环境包.zip](https://github.com/Goose666666/stm32-starter-kit/releases/latest)**

约 114 MB，里面有：

| 内容 | 说明 |
| --- | --- |
| `01-器件包/` | Keil 芯片支持包，双击离线安装，不用联网 |
| `02-标准库/` | STM32F10x_StdPeriph_Lib_V3.5.0，新建工程要用 |
| `安装说明.html` | 完整步骤，双击用浏览器打开 |
| `README.txt` | 纯文本速查版 |

## 这个包里没有什么

**Keil MDK 本体。**它是 Arm 的商业软件，需要自己去官网注册账号后下载。

**江协科技官方资料包。**里面有全部例程、原理图和模块手册。

- 网盘 `pan.baidu.com/s/1h_UjuQKDX9IpP-U1Effbsw`
- 提取码 `dspb`
- 解压密码 `32`
- 官网最新链接 [jiangxiekeji.com/download.html](https://jiangxiekeji.com/download.html)

## 三个最常见的坑

**Vendor / Device / Toolset 显示 unknown。**这不是错误，只是还没在下面的树里选中芯片。点中一个具体型号，三行会自动填好。

**Pack Installer 顶上出现红色 ERRORS，Cannot load PDSC Files。**在线目录缓存下坏了。关掉 Keil，把 `C:\Keil_v5\ARM\PACK\.Web` 里的文件全删，然后改用离线方式装包。

**编译报几十上百个错，找不到头文件。**多半是宏 `USE_STDPERIPH_DRIVER` 没定义，位置在魔术棒图标的 C/C++ 标签里。也可能是 Include Paths 漏加了放头文件的文件夹。

## 来源

器件包取自 Keil 官方源 `keil.com/pack`，标准库为 ST 官方 V3.5.0 版，均已校验完整并做过编译测试。

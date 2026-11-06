平台官方图标不入库（注册商标）。

跑一次即可取到，界面就是手机版那种真实图标：

    powershell -NoProfile -ExecutionPolicy Bypass -File tools/fetch-platform-icons.ps1

本目录内 *.png 已在 .gitignore 中；缺失时应用自动改用
自绘的「品牌色块 + 首字」兜底（lib/ui/widgets/platform_logo.dart），
功能与识别度等价，构建也不会失败。

; 闪取 SnapFetch 安装包脚本（Inno Setup 6/7）
; 产物: release\SnapFetch-<版本>-setup.exe
; 安装为每用户（无需管理员）：{autopf}\SnapFetch
; 用户数据落在**安装目录内**的 SnapFetch-data（实测未签名 exe 写 %APPDATA%
; 会被部分国产杀软按进程拦截，程序自己的目录则放行）；卸载时保留。

#define MyAppName "闪取 SnapFetch"
#define MyAppNameEn "SnapFetch"
; ★ 版本唯一来源是 pubspec.yaml：由 tools/build-installer.ps1 读出后用
;   /DMyAppVersion=x.y.z 传进来。下面这行只是「直接在 IDE 里编译」的兜底默认值，
;   不要在这里维护版本（test/app_info_test.dart 会检查覆盖机制仍在）。
#ifdef MyAppVersion
  #define AppVersion MyAppVersion
#else
  #define AppVersion "0.2.0"
#endif
#define MyAppPublisher "SnapFetch (independent, non-official)"
#define MyAppExeName "SnapFetch.exe"

[Setup]
AppId={{8EB667EE-17E6-4EC3-8605-86F03B1F82EF}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppNameEn}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
OutputDir=..\release
OutputBaseFilename=SnapFetch-{#AppVersion}-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
Uninstallable=yes
; setup.exe 自身的文件属性：不写的话「属性→详细信息」里文件版本是空的，
; 既不像正规软件，也容易触发杀软的启发式关注。
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} 安装程序

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Excludes 两组，缺一不可：
;  1) 运行时数据（SnapFetch-data / *.WebView2 / downloads）—— 用户凭证与任务
;     绝不能进任何分发包。
;  2) assets\icons\platforms\*.png —— 各平台 logo 是注册商标，不随分发包传播。
;     剔除后应用启动时 Image.asset 失败 → errorBuilder 自动改用自绘品牌色块，
;     界面不留空洞（见 lib/ui/widgets/platform_logo.dart）。
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "SnapFetch-data,SnapFetch-data\*,*.WebView2,*.WebView2\*,downloads,downloads\*,.snapfetch_write_test,assets\icons\platforms\*.png"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\packaging\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\DISTRIBUTION.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 保留用户数据（%APPDATA%\SnapFetch），卸载不删凭证/任务 —— 如需清除请手动删除该目录

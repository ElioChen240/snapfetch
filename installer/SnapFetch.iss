; 闪取 SnapFetch 安装包脚本（Inno Setup 6）
; 产物: release\SnapFetch-<版本>-setup.exe
; 安装为每用户（无需管理员）：%LOCALAPPDATA%\Programs\SnapFetch
; 用户数据（任务/凭证/设置）在 %APPDATA%\SnapFetch\snapfetch，卸载时保留

#define MyAppName "闪取 SnapFetch"
#define MyAppNameEn "SnapFetch"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "SnapFetch (independent, non-official)"
#define MyAppExeName "SnapFetch.exe"

[Setup]
AppId={{8EB667EE-17E6-4EC3-8605-86F03B1F82EF}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppNameEn}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
OutputDir=..\release
OutputBaseFilename=SnapFetch-{#MyAppVersion}-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
Uninstallable=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Excludes 必须写：Release 目录里可能有运行时生成的 SnapFetch-data（用户凭证/任务），
; 绝不能打进安装包。
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "SnapFetch-data,SnapFetch-data\*,*.WebView2,*.WebView2\*,downloads,downloads\*,.snapfetch_write_test"; Flags: recursesubdirs createallsubdirs ignoreversion
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

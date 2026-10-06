; Mahabbat Setup — Inno Setup 7 script.
; One Mahabbat-Setup.exe: installs runtime, starts the wizard, registers tray.
; Build: installer\build\build-installer.ps1 -NodeExe <path-to-node-24.16.0-node.exe> [-NodeSha256 <hash>]
; (downloads the official nodejs.org release when -NodeExe is omitted; see installer/build/NODE_SOURCE.md).
; The setup binary is NOT code-signed: Windows SmartScreen shows an "unknown
; publisher" warning. Do NOT bypass it unless the file came from the venue
; owner on this PC. Details: installer/UNLICENSED-SMARTSCREEN-NOTE.md.

; Stage E: real distinguishable versions (F14). Build passes /DAppVersion + /DFileVersion;
; defaults below are ONLY the 1.0.0 fallback for a bare ISCC run without defines.
#ifndef AppVersion
#define AppVersion "1.0.0"
#endif
#ifndef FileVersion
#define FileVersion "1.0.0.0"
#endif
#define AppName "Mahabbat"
#define DeployRoot ".."
#define NodeSource "..\app\runtime\node.exe"

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
VersionInfoVersion={#FileVersion}
; Product identity is explicit (not Inno-defaulted): Product carries the
; visible candidate label (1.1.0-rc.1), File carries the numeric quad
; (1.1.0.1). Transitional 1.0.1/1.0.1.0 vs candidate 1.1.0-rc.1/1.1.0.1
; stay distinguishable in Explorer, Add/Remove Programs, and Get-Item
; .VersionInfo (see release/EXE_SHA256.txt version proof).
VersionInfoProductVersion={#AppVersion}
VersionInfoTextVersion={#AppVersion}
VersionInfoProductTextVersion=Mahabbat {#AppVersion}
VersionInfoProductName=Mahabbat
DefaultDirName={autopf}\Mahabbat
DefaultGroupName=Mahabbat
OutputDir=..\build\output
OutputBaseFilename=Mahabbat-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
MinVersion=10.0
WizardStyle=modern
DisableProgramGroupPage=yes
UninstallDisplayName=Mahabbat {#AppVersion}

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
; Deployment tree (scripts, compose, installer app, docs). Secrets excluded by source layout (.env/backups never in repo).
; Backups live OUTSIDE {app} (%ProgramData%\Mahabbat\backups, or MAHABBAT_BACKUP_ROOT):
; uninstall keeps them. Never add a [Files] entry that copies a backups tree.
; E5 lesson: scripts/lib (validator + crypto) MUST ship inside the EXE —
; the first 1.0.1 build lost it. `recursesubdirs` below is load-bearing:
; never scope this entry to top-level files only.
Source: "..\..\scripts\*"; DestDir: "{app}\scripts"; Flags: recursesubdirs
Source: "..\..\deploy\*"; DestDir: "{app}\deploy"; Flags: recursesubdirs; Excludes: "*.draft"
Source: "..\app\*"; DestDir: "{app}\installer\app"; Excludes: "runtime\node.exe"
Source: "..\..\docker-compose.yml"; DestDir: "{app}"
Source: "..\..\.env.example"; DestDir: "{app}"
Source: "..\..\.dockerignore"; DestDir: "{app}"
Source: "..\..\mahabbat-inner.lock.json"; DestDir: "{app}"
Source: "..\..\upstream-twenty.lock.json"; DestDir: "{app}"
Source: "..\..\image-digests.lock.json"; DestDir: "{app}"
Source: "..\..\release\mahabbat-release.json"; DestDir: "{app}\release"
; Release identity rides with the EXE: schema + changelog + EXE hashes.
; installed {app}\release without these is NOT a complete kit (E5).
Source: "..\..\release\mahabbat-release.schema.json"; DestDir: "{app}\release"
Source: "..\..\release\CHANGELOG.md"; DestDir: "{app}\release"
Source: "..\..\release\EXE_SHA256.txt"; DestDir: "{app}\release"
Source: "..\..\legacy-data-status.json"; DestDir: "{app}"
Source: "..\..\docs\RUNNING_MAHABBAT.md"; DestDir: "{app}\docs"
; Fresh-install guide for the second PC / venue owner (G5).
Source: "..\..\docs\SECOND_PC_INSTALL.md"; DestDir: "{app}\docs"
Source: "..\UNLICENSED-SMARTSCREEN-NOTE.md"; DestDir: "{app}\installer"
; Bundled Node 24 runtime for setup-api + tray (no system Node required).
; Staged by installer\build\build-installer.ps1 from a controlled source with
; SHA256 verification (official nodejs.org release, default v24.16.0, see
; installer/app/runtime/NODE_VERSION.txt). Never hardcode a personal path here.
Source: "{#NodeSource}"; DestDir: "{app}\installer\app\runtime"
Source: "..\app\runtime\*.txt"; DestDir: "{app}\installer\app\runtime"

[Icons]
Name: "{group}\Mahabbat — установка"; Filename: "{app}\installer\app\Mahabbat-Setup.vbs"
Name: "{group}\Mahabbat Касса"; Filename: "http://localhost:3100/"
Name: "{group}\Mahabbat CRM"; Filename: "http://localhost:3000/"
Name: "{autodesktop}\Mahabbat Касса"; Filename: "http://localhost:3100/"
Name: "{autodesktop}\Mahabbat CRM"; Filename: "http://localhost:3000/"
Name: "{userstartup}\Mahabbat"; Filename: "{app}\installer\app\Mahabbat-Tray.vbs"

[Run]
Filename: "{app}\installer\app\runtime\node.exe"; Parameters: """{app}\installer\app\setup-api.mjs"" --port 3119 --root ""{app}"""; Flags: nowait runhidden skipifsilent; Description: "Запустить мастер установки"
Filename: "http://127.0.0.1:3119/"; Flags: shellexec skipifsilent postinstall; Description: "Открыть мастер установки"
Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\app\Mahabbat-Tray.vbs"""; Flags: nowait runhidden; Description: "Запустить значок Mahabbat"

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\mahabbat-stop.ps1"""; Flags: runhidden; RunOnceId: "StopMahabbat"
[UninstallDelete]
; Backups are outside {app} and are intentionally NOT deleted here.
Type: files; Name: "{app}\installer\app\runtime\node.exe"

[Code]
var
  DockerPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin
  DockerPage := CreateInputOptionPage(wpWelcome,
    'Проверка требований', 'Docker Desktop',
    'Mahabbat работает в изолированных контейнерах. Нужен бесплатный Docker Desktop (устанавливается один раз).',
    True, False);
  DockerPage.Add('Docker Desktop уже установлен');
  DockerPage.Add('Установить Docker Desktop позже (мастер подскажет)');
  DockerPage.SelectedValueIndex := 0;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
end;

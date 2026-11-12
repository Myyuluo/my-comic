// my_comic/windows/installer/process_control.iss
// 安装器的进程控制：全部直接调 Win32 API，**不拉起任何子进程**。
//
// 根因（2026-10-16，Kaspersky PDM:Trojan.Win32.Generic 行为误报）：应用内更新时，
// 一个刚下载进 %APPDATA%\...\updates 的 exe 被静默拉起，随后它自己又拉起隐藏窗口的
// PowerShell（`Get-Process | Stop-Process -Force`，还经 {sysnative} 从 32 位跨到 64 位）
// 和 `taskkill /F /IM ...` —— 这串行为与木马 dropper 的画像逐项重合，带有效签名也被
// 行为引擎判成木马。原先那几条命令行能做的事，这里用同一组 API 原生做掉：
//   - 进程枚举：CreateToolhelp32Snapshot / Process32FirstW / Process32NextW；
//   - 镜像路径：QueryFullProcessImageNameW（32 位安装器读 64 位进程的路径也可靠——
//     BUG-1786 里 32 位 PowerShell 读不到的是 MainModule，这个 API 不走那条路）；
//   - 结束进程：TerminateProcess，并等内核真正回收（镜像文件锁随之释放）；
//   - 温和关闭：EnumWindows + PostMessage(WM_CLOSE)，与 `taskkill /IM`（不带 /F）同义。
// 守卫：my_comic/test/build/windows_installer_no_child_process_guard_test.dart。
//
// 本文件只放在 [Code] 段内被 #include；不依赖 mycomic.iss 里的任何声明，探针脚本可单独引用。

const
  MyComicTh32csSnapProcess = $00000002;
  MyComicProcessTerminate = $00000001;
  MyComicProcessQueryLimitedInformation = $00001000;
  MyComicProcessSynchronize = $00100000;
  MyComicWmClose = $0010;
  { PROCESSENTRY32W 在 32 位进程里的大小：9 个 4 字节字段 + 260 个 WCHAR。
    Setup 运行时恒为 32 位（Inno 6.7 也是），ULONG_PTR 即 4 字节。 }
  MyComicProcessEntry32WSize = 556;
  { 结束进程后等它真正退出的上限。镜像文件的锁要等进程对象被回收才放。 }
  MyComicTerminateWaitMs = 5000;
  MyComicInvalidHandle = $FFFFFFFF;
  { 安装器本身经它拉起、且必须活到安装结束（BUG-1708）。按**前缀**认：
    改名让路留下的 my_comic_update_launcher.old*.exe 是同一份映像，同样要放过（BUG-1831）。 }
  MyComicUpdateLauncherImagePrefix = 'my_comic_update_launcher';

type
  TMyComicProcessEntry32W = record
    dwSize: Cardinal;
    cntUsage: Cardinal;
    th32ProcessID: Cardinal;
    th32DefaultHeapID: Cardinal;
    th32ModuleID: Cardinal;
    cntThreads: Cardinal;
    th32ParentProcessID: Cardinal;
    pcPriClassBase: Longint;
    dwFlags: Cardinal;
    szExeFile: array[0..259] of Char;
  end;
  TMyComicCardinalArray = array of Cardinal;

function MyComicCreateToolhelp32Snapshot(dwFlags: Cardinal; th32ProcessID: Cardinal): THandle;
  external 'CreateToolhelp32Snapshot@kernel32.dll stdcall';
function MyComicProcess32FirstW(hSnapshot: THandle; var lppe: TMyComicProcessEntry32W): Boolean;
  external 'Process32FirstW@kernel32.dll stdcall';
function MyComicProcess32NextW(hSnapshot: THandle; var lppe: TMyComicProcessEntry32W): Boolean;
  external 'Process32NextW@kernel32.dll stdcall';
function MyComicOpenProcess(dwDesiredAccess: Cardinal; bInheritHandle: Boolean;
  dwProcessId: Cardinal): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function MyComicQueryFullProcessImageNameW(hProcess: THandle; dwFlags: Cardinal;
  lpExeName: String; var lpdwSize: Cardinal): Boolean;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function MyComicTerminateProcess(hProcess: THandle; uExitCode: Cardinal): Boolean;
  external 'TerminateProcess@kernel32.dll stdcall';
function MyComicWaitForSingleObject(hHandle: THandle; dwMilliseconds: Cardinal): Cardinal;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function MyComicCloseHandle(hObject: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function MyComicGetCurrentProcessId(): Cardinal;
  external 'GetCurrentProcessId@kernel32.dll stdcall';
function MyComicEnumWindows(lpEnumFunc: Longword; lParam: Longint): Boolean;
  external 'EnumWindows@user32.dll stdcall';
function MyComicGetWindowThreadProcessId(hWnd: HWND; var lpdwProcessId: Cardinal): Cardinal;
  external 'GetWindowThreadProcessId@user32.dll stdcall';

var
  { EnumWindows 回调读的目标 PID 集（回调拿不到闭包，只能走全局）。 }
  MyComicWmCloseTargets: TMyComicCardinalArray;

function MyComicEntryExeName(const Entry: TMyComicProcessEntry32W): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to 259 do
  begin
    if Entry.szExeFile[I] = #0 then
      Break;
    Result := Result + Entry.szExeFile[I];
  end;
end;

{ 一次快照拿到全部进程的 PID / 父 PID / 镜像名（小写）。三个数组同下标对齐。 }
procedure MyComicSnapshotProcesses(var Pids, ParentPids: TMyComicCardinalArray;
  var Names: TArrayOfString);
var
  Snapshot: THandle;
  Entry: TMyComicProcessEntry32W;
  Count: Integer;
  More: Boolean;
begin
  SetArrayLength(Pids, 0);
  SetArrayLength(ParentPids, 0);
  SetArrayLength(Names, 0);
  Snapshot := MyComicCreateToolhelp32Snapshot(MyComicTh32csSnapProcess, 0);
  if (Snapshot = 0) or (Snapshot = MyComicInvalidHandle) then
  begin
    Log('process_control: CreateToolhelp32Snapshot failed');
    Exit;
  end;
  try
    Count := 0;
    Entry.dwSize := MyComicProcessEntry32WSize;
    More := MyComicProcess32FirstW(Snapshot, Entry);
    while More do
    begin
      SetArrayLength(Pids, Count + 1);
      SetArrayLength(ParentPids, Count + 1);
      SetArrayLength(Names, Count + 1);
      Pids[Count] := Entry.th32ProcessID;
      ParentPids[Count] := Entry.th32ParentProcessID;
      Names[Count] := Lowercase(MyComicEntryExeName(Entry));
      Count := Count + 1;
      Entry.dwSize := MyComicProcessEntry32WSize;
      More := MyComicProcess32NextW(Snapshot, Entry);
    end;
  finally
    MyComicCloseHandle(Snapshot);
  end;
end;

function MyComicPidInList(const Pid: Cardinal; const List: TMyComicCardinalArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to GetArrayLength(List) - 1 do
    if List[I] = Pid then
    begin
      Result := True;
      Exit;
    end;
end;

procedure MyComicAppendPid(var List: TMyComicCardinalArray; const Pid: Cardinal);
var
  N: Integer;
begin
  if MyComicPidInList(Pid, List) then
    Exit;
  N := GetArrayLength(List);
  SetArrayLength(List, N + 1);
  List[N] := Pid;
end;

{ 进程的完整镜像路径；打不开（受保护进程 / 别的用户 / 已退出）返回空串。 }
function MyComicProcessImagePath(const Pid: Cardinal): String;
var
  Handle: THandle;
  Size: Cardinal;
  Buffer: String;
begin
  Result := '';
  Handle := MyComicOpenProcess(MyComicProcessQueryLimitedInformation, False, Pid);
  if Handle = 0 then
    Exit;
  try
    Size := 32768;
    SetLength(Buffer, Size);
    if MyComicQueryFullProcessImageNameW(Handle, 0, Buffer, Size) then
      Result := Copy(Buffer, 1, Size);
  finally
    MyComicCloseHandle(Handle);
  end;
end;

{ 结束一个进程并等它真正退出（镜像文件锁要等进程对象回收才释放）。 }
function MyComicTerminatePid(const Pid: Cardinal): Boolean;
var
  Handle: THandle;
begin
  Result := False;
  Handle := MyComicOpenProcess(MyComicProcessTerminate or MyComicProcessSynchronize, False, Pid);
  if Handle = 0 then
  begin
    Log(Format('process_control: OpenProcess(terminate) failed pid=%d', [Pid]));
    Exit;
  end;
  try
    Result := MyComicTerminateProcess(Handle, 1);
    if Result then
      MyComicWaitForSingleObject(Handle, MyComicTerminateWaitMs);
    Log(Format('process_control: TerminateProcess pid=%d ok=%d', [Pid, Ord(Result)]));
  finally
    MyComicCloseHandle(Handle);
  end;
end;

function MyComicIsUpdateLauncherImage(const LowerName: String): Boolean;
begin
  Result := Pos(MyComicUpdateLauncherImagePrefix, LowerName) = 1;
end;

{ 按镜像名（整名、大小写不敏感）找出 MyComic 主进程：MyComic.exe 与改名前的 hibiki.exe。
  与 `taskkill /IM` 同义——机器上任何位置的同名实例都算（它们都可能持有单实例互斥量）。 }
procedure MyComicCollectAppPids(var Targets: TMyComicCardinalArray);
var
  Pids, ParentPids: TMyComicCardinalArray;
  Names: TArrayOfString;
  I: Integer;
begin
  SetArrayLength(Targets, 0);
  MyComicSnapshotProcesses(Pids, ParentPids, Names);
  for I := 0 to GetArrayLength(Pids) - 1 do
    if (Names[I] = 'MyComic.exe') or (Names[I] = 'hibiki.exe') then
      MyComicAppendPid(Targets, Pids[I]);
end;

function MyComicPostCloseToTargetWindow(Wnd: HWND; Param: Longint): Boolean;
var
  Pid: Cardinal;
begin
  Result := True; { 继续枚举 }
  Pid := 0;
  MyComicGetWindowThreadProcessId(Wnd, Pid);
  if (Pid <> 0) and MyComicPidInList(Pid, MyComicWmCloseTargets) then
    PostMessage(Wnd, MyComicWmClose, 0, 0);
end;

{ 温和关闭：给 MyComic.exe / hibiki.exe 的每个顶层窗口投递 WM_CLOSE，让它自己落盘、
  释放互斥量后退出。等价于旧的 `taskkill /IM <名>`（不带 /F）。 }
procedure MyComicCloseAppWindows();
begin
  MyComicCollectAppPids(MyComicWmCloseTargets);
  if GetArrayLength(MyComicWmCloseTargets) = 0 then
    Exit;
  { 实参数组不能换行起头：Inno 把以 `[` 开头的行当段标签（即使在 [Code] 里）。 }
  Log(Format('process_control: WM_CLOSE -> %d MyComic process(es)', [GetArrayLength(MyComicWmCloseTargets)]));
  MyComicEnumWindows(CreateCallback(@MyComicPostCloseToTargetWindow), 0);
  SetArrayLength(MyComicWmCloseTargets, 0);
end;

{ 强制结束 MyComic.exe / hibiki.exe，以及**它们名下的** WebView2 进程。
  BUG-2203：绝不能按进程树一路往下杀——应用内更新时本安装器就是 MyComic.exe 的孙进程
  （MyComic.exe → my_comic_update_launcher.exe → setup）。所以往下只沿 msedgewebview2.exe
  这一种镜像名扩展：launcher、安装器自己都不叫这个名字，永远进不了目标集。
  旧实现是 `taskkill /F /IM msedgewebview2.exe`，会把机器上**别的应用**（Teams、新版
  Outlook、小组件……）的 WebView2 一起杀掉；这里只认父链挂在 MyComic 主进程上的那些。
  目标集必须在杀任何进程之前一次算好：主进程一死，子进程的父 PID 就失去意义。 }
procedure MyComicTerminateAppProcessTree();
var
  Pids, ParentPids: TMyComicCardinalArray;
  Names: TArrayOfString;
  Targets: TMyComicCardinalArray;
  OwnPid: Cardinal;
  I: Integer;
  Grew: Boolean;
begin
  OwnPid := MyComicGetCurrentProcessId();
  MyComicSnapshotProcesses(Pids, ParentPids, Names);
  SetArrayLength(Targets, 0);
  for I := 0 to GetArrayLength(Pids) - 1 do
    if (Names[I] = 'MyComic.exe') or (Names[I] = 'hibiki.exe') then
      MyComicAppendPid(Targets, Pids[I]);
  if GetArrayLength(Targets) = 0 then
    Exit;
  repeat
    Grew := False;
    for I := 0 to GetArrayLength(Pids) - 1 do
      if (Names[I] = 'msedgewebview2.exe') and
         (not MyComicPidInList(Pids[I], Targets)) and
         MyComicPidInList(ParentPids[I], Targets) then
      begin
        MyComicAppendPid(Targets, Pids[I]);
        Grew := True;
      end;
  until not Grew;
  for I := 0 to GetArrayLength(Targets) - 1 do
    if Targets[I] <> OwnPid then
      MyComicTerminatePid(Targets[I]);
end;

{ BUG-1459: the mutex layer only proves the main exe exited. Helper processes
  launched from the install dir (ffmpeg.exe audio jobs, galgame helper) can
  outlive it and keep their image files locked, so the file-copy phase dies
  with "could not replace ...\ffmpeg.exe (DeleteFile code 5)". Sweep by image
  PATH under the target dir (not by name) so unrelated same-named processes
  elsewhere on the machine are untouched.
  launcher 被显式排除：它是拉起本安装器的进程，且要活到安装结束才能在失败时把 app
  拉回来（BUG-1708）。它自己占住的文件由 MakeWayForRunningLauncher 改名让路解决。 }
procedure KillProcessesUnderDir(const Dir: String);
var
  Pids, ParentPids: TMyComicCardinalArray;
  Names: TArrayOfString;
  Prefix: String;
  Path: String;
  OwnPid: Cardinal;
  I: Integer;
begin
  Prefix := Lowercase(AddBackslash(Dir));
  OwnPid := MyComicGetCurrentProcessId();
  MyComicSnapshotProcesses(Pids, ParentPids, Names);
  for I := 0 to GetArrayLength(Pids) - 1 do
  begin
    if (Pids[I] = 0) or (Pids[I] = OwnPid) then
      Continue;
    if MyComicIsUpdateLauncherImage(Names[I]) then
      Continue;
    Path := MyComicProcessImagePath(Pids[I]);
    if Path = '' then
      Continue;
    if Pos(Prefix, Lowercase(Path)) = 1 then
    begin
      Log(Format('process_control: sweeping %s (pid=%d)', [Path, Pids[I]]));
      MyComicTerminatePid(Pids[I]);
    end;
  end;
end;

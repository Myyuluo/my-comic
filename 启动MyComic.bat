@echo off
setlocal
rem Builds my-comic when the checkout changed, bundles the Mihon extension
rem runtime into the Release directory, then launches:
rem   fushi\build\windows\x64\runner\Release\fushi.exe
set "ROOT=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%script\build_and_run.ps1" %*
if errorlevel 1 (
  echo.
  echo my-comic failed to start. Review the messages above.
  pause
)
endlocal

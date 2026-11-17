@echo off
rem CG Interativa: instala no Windows para o seu usuario (sem administrador).
rem   instalar.bat            copia para %LOCALAPPDATA%\Programs\CG Interativa
rem                           e cria o atalho no Menu Iniciar
rem   instalar.bat /remover   desinstala
rem Installs CG Interativa for the current user (no admin needed).
rem Use "instalar.bat /uninstall" to remove it.
setlocal
set "DESTINO=%LOCALAPPDATA%\Programs\CG Interativa"
set "ATALHO=%APPDATA%\Microsoft\Windows\Start Menu\Programs\CG Interativa.lnk"

if /i "%~1"=="/remover" goto remover
if /i "%~1"=="/uninstall" goto remover

if not exist "%~dp0cg-interativa.exe" (
    echo cg-interativa.exe nao encontrado ao lado deste arquivo. / not found next to this file.
    exit /b 1
)
if not exist "%DESTINO%" mkdir "%DESTINO%"
copy /y "%~dp0cg-interativa.exe" "%DESTINO%\cg-interativa.exe" >nul || exit /b 1
if exist "%~dp0LICENSE.txt" copy /y "%~dp0LICENSE.txt" "%DESTINO%\LICENSE.txt" >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:ATALHO); $s.TargetPath=$env:DESTINO+'\cg-interativa.exe'; $s.WorkingDirectory=$env:DESTINO; $s.Description='CG Interativa'; $s.Save()" >nul 2>&1
if exist "%ATALHO%" (
    echo CG Interativa instalada. Abra pelo Menu Iniciar.
    echo CG Interativa installed. Open it from the Start menu.
) else (
    echo CG Interativa instalada em "%DESTINO%" ^(sem atalho no Menu Iniciar^).
    echo Installed to "%DESTINO%" ^(could not create the Start menu shortcut^).
)
exit /b 0

:remover
if exist "%ATALHO%" del /q "%ATALHO%"
if exist "%DESTINO%" rmdir /s /q "%DESTINO%"
echo CG Interativa removida. / removed.
exit /b 0

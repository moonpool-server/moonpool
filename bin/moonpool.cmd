@echo off
rem bin\moonpool from PowerShell or cmd. It needs Python 3; the WSL shell Docker Desktop uses works without it.
python -c "import sys; sys.exit(sys.version_info < (3, 8))" >nul 2>nul || (echo moonpool needs Python 3 on Windows, or run it from the WSL shell Docker Desktop uses 1>&2 & exit /b 9009)
python "%~dp0moonpool" %*

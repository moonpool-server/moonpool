@echo off
rem One-time setup for moonpool. Downloads the launcher from this project's GitHub release and
rem installs it for this Windows user: no admin rights.
setlocal
set "D=%TEMP%\moonpool-setup"
if not exist "%D%" mkdir "%D%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://github.com/moonpool-server/moonpool/releases/latest/download/moonpool.ps1' -OutFile '%D%\moonpool.ps1'; Invoke-WebRequest -UseBasicParsing 'https://github.com/moonpool-server/moonpool/releases/latest/download/moonpool.ps1.sig' -OutFile '%D%\moonpool.ps1.sig'; $k=New-Object Security.Cryptography.RSAParameters; $k.Modulus=[Convert]::FromBase64String('tSJdxcTDEY2AmF7xE0F5YN4V5XWk3nwuMlH5QXoVf4IgLuHVCl12SajOCwcWxS5wluItvHzJnprs01Gq5FY3/wLNPhQa5YIVsV9b1RzoybzR8s8fkzGaadANmcRQm39RMafxQppjeg5UP8jh1BHqNZvxTVQBAvBjWRI3tfJe8uqcoL6HAPdUM1xb8xc+pkb2E2UFcxGlcbrYMmRBrzjGLgTcye17gTo7bja0gjIa3/8kPG7ECwoH7MYhVKzJm8SdRSfz09lqbLtFfEG86/UBxoDPIhaLz+iYLx/gdsy9lpD78P3gN250cu2IcZE0/xmeyQSggfHOVuvNSWTQkyEsQwhYnF5HnZXnDNEg4mCqh2o/v06EljAe2JOrVZPiEoqT52uXtRh6prF6OmAoVidxS2FUVnIs2DGQDMf/RGM6GVXPd4bgqeXZGvjp8noklRk1qIE32i4RzHYsS3iD/UiHrfiXZacJ7DKWaN8FyVGXJFduyVYxZbmvE9XAl7LPFmwf'); $k.Exponent=[Convert]::FromBase64String('AQAB'); $r=New-Object Security.Cryptography.RSACryptoServiceProvider; $r.ImportParameters($k); if (-not $r.VerifyData([IO.File]::ReadAllBytes('%D%\moonpool.ps1'),[Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'),[IO.File]::ReadAllBytes('%D%\moonpool.ps1.sig'))) { Remove-Item '%D%\moonpool.ps1'; throw 'The launcher failed its signature check, so it was not run.' }; & '%D%\moonpool.ps1' -Install"
echo.
pause

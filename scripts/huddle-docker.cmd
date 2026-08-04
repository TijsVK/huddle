@echo off
REM Docker CLI shim: forwards every docker command to the Huddle ENGINE HOST (a
REM WSL2 distro), so Windows tools that shell out to `docker` - notably the VS Code
REM Dev Containers extension - see the devcontainers running there instead of
REM Docker Desktop's or Rancher Desktop's.
REM
REM   "dev.containers.dockerPath": "C:\\path\\to\\scripts\\huddle-docker.cmd"
REM
REM Notes:
REM   /usr/bin/docker : absolute path on purpose. With appendWindowsPath=true the
REM              distro's PATH also holds the Windows entries, so Rancher/Docker
REM              Desktop could otherwise shadow the engine's own CLI.
REM   --cd /   : do not translate the caller's Windows working directory (a UNC or
REM              network path makes wsl.exe warn, and that warning lands in stdout
REM              where the extension is parsing JSON).
REM   no -u    : run as the distro's default user (in the docker group), because
REM              -u root makes WSL print "Failed to start the systemd user session".
REM
REM Debug: set HUDDLE_DOCKER_DEBUG=1 to append every invocation, its exit code and
REM its first line of output to %TEMP%\huddle-docker.log.
setlocal
if "%HUDDLE_ENGINE_DISTRO%"=="" set HUDDLE_ENGINE_DISTRO=huddle-engine

if not defined HUDDLE_DOCKER_DEBUG goto :run
>>"%TEMP%\huddle-docker.log" echo === %DATE% %TIME% cwd=%CD%
>>"%TEMP%\huddle-docker.log" echo args: %*
wsl.exe -d %HUDDLE_ENGINE_DISTRO% --cd / -- /usr/bin/docker %* > "%TEMP%\huddle-docker.tmp" 2>&1
set RC=%ERRORLEVEL%
>>"%TEMP%\huddle-docker.log" echo exit: %RC%
>>"%TEMP%\huddle-docker.log" echo out : 
type "%TEMP%\huddle-docker.tmp" >>"%TEMP%\huddle-docker.log"
type "%TEMP%\huddle-docker.tmp"
exit /b %RC%

:run
wsl.exe -d %HUDDLE_ENGINE_DISTRO% --cd / -- /usr/bin/docker %*
exit /b %ERRORLEVEL%

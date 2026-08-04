@echo off
REM Docker CLI shim: forwards every docker command to the Huddle ENGINE HOST (a
REM WSL2 distro), so Windows tools that shell out to `docker` - notably the VS Code
REM Dev Containers extension - see the devcontainers running there instead of
REM Docker Desktop's.
REM
REM   "dev.containers.dockerPath": "C:\\path\\to\\scripts\\huddle-docker.cmd"
REM
REM Notes:
REM   --cd /   : do not translate the caller's Windows working directory (a UNC or
REM              network path makes wsl.exe print a warning, and that warning ends
REM              up in stdout where the extension is parsing JSON).
REM   no -u    : run as the distro's default user (added to the docker group by
REM              scripts/huddle-engine-install.sh). Forcing -u root makes WSL emit
REM              "Failed to start the systemd user session for 'root'", which also
REM              corrupts the JSON the extension reads.
setlocal
if "%HUDDLE_ENGINE_DISTRO%"=="" set HUDDLE_ENGINE_DISTRO=huddle-engine
wsl.exe -d %HUDDLE_ENGINE_DISTRO% --cd / -- docker %*

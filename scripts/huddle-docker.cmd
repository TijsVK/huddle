@echo off
REM Docker CLI shim: forwards every docker command to the Huddle ENGINE HOST
REM (a WSL2 distro), so tools on Windows that shell out to `docker` - notably the
REM VS Code Dev Containers extension - see the devcontainers that run there
REM instead of Docker Desktop's containers.
REM
REM Point VS Code at it:
REM   "dev.containers.dockerPath": "C:\\path\\to\\scripts\\huddle-docker.cmd"
setlocal
if "%HUDDLE_ENGINE_DISTRO%"=="" set HUDDLE_ENGINE_DISTRO=huddle-engine
wsl.exe -d %HUDDLE_ENGINE_DISTRO% -u root -- docker %*

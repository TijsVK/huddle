@echo off
REM Docker CLI shim: forwards every docker command to the Huddle ENGINE HOST (a
REM WSL2 distro), so Windows tools that shell out to `docker` - notably the VS Code
REM Dev Containers extension - see the devcontainers running there instead of
REM Docker Desktop's or Rancher Desktop's.
REM
REM   "dev.containers.dockerPath": "C:\\path\\to\\scripts\\huddle-docker.cmd"
REM
REM Why the flags:
REM   /usr/bin/docker : absolute, so a Windows docker on the distro's PATH
REM                     (Rancher/Docker Desktop) can never shadow the engine's CLI.
REM   --cd /          : never translate the caller's Windows working directory -
REM                     that both warns on UNC paths and fails with
REM                     "chdir(2) failed.: Permission denied" for a non-root user.
REM   no -u           : run as the distro's default user (in the docker group);
REM                     a root session makes WSL print a systemd-user-session
REM                     warning, and stray text breaks callers parsing JSON.
REM
REM Logging: every invocation is appended to %TEMP%\huddle-docker.log (args, cwd,
REM exit code) - no output buffering, so `docker exec -it` still streams. Set
REM HUDDLE_DOCKER_DEBUG=1 to also capture the full output, or HUDDLE_DOCKER_NOLOG=1
REM to disable logging entirely.
setlocal
if "%HUDDLE_ENGINE_DISTRO%"=="" set HUDDLE_ENGINE_DISTRO=huddle-engine
set LOG=%TEMP%\huddle-docker.log

if defined HUDDLE_DOCKER_DEBUG goto :debug
if not defined HUDDLE_DOCKER_NOLOG >>"%LOG%" echo %DATE% %TIME% cwd=%CD% args: %*
wsl.exe -d %HUDDLE_ENGINE_DISTRO% --cd / -- /usr/bin/docker %*
set RC=%ERRORLEVEL%
if not defined HUDDLE_DOCKER_NOLOG >>"%LOG%" echo %DATE% %TIME% exit=%RC%
exit /b %RC%

:debug
>>"%LOG%" echo === %DATE% %TIME% cwd=%CD%
>>"%LOG%" echo args: %*
wsl.exe -d %HUDDLE_ENGINE_DISTRO% --cd / -- /usr/bin/docker %* > "%TEMP%\huddle-docker.tmp" 2>&1
set RC=%ERRORLEVEL%
>>"%LOG%" echo exit: %RC%
type "%TEMP%\huddle-docker.tmp" >>"%LOG%"
type "%TEMP%\huddle-docker.tmp"
exit /b %RC%

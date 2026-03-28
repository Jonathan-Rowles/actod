@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

set DEV_FLAGS=-vet -strict-style -microarch:native
set RELEASE_FLAGS=-o:aggressive -no-bounds-check -disable-assert -microarch:native
set TEST_FLAGS=-define:ODIN_TEST_SHORT_LOGS=true -define:ODIN_TEST_LOG_LEVEL=warning

if "%~1"=="" goto usage
if "%~1"=="test" goto test
if "%~1"=="test-unit" goto test-unit
if "%~1"=="test-integration" goto test-integration
if "%~1"=="bench-single" goto bench-single
if "%~1"=="bench-network" goto bench-network
if "%~1"=="gen-hot-api" goto gen-hot-api
if "%~1"=="clean" goto clean
echo Unknown target: %~1
goto usage

:usage
echo Usage: build.bat [target]
echo.
echo Targets:
echo   test              Run all tests (unit + integration)
echo   test-unit         Run unit tests (discovers *_test.odin dirs)
echo   test-integration  Build and run integration tests
echo   bench-single      Build and run single-process benchmark
echo   bench-network     Build and run network benchmark
echo   gen-hot-api       Generate hot-reload API
echo   clean             Remove bin/ directory
exit /b 1

:test
call :test-unit
if errorlevel 1 exit /b 1
call :test-integration
exit /b %errorlevel%

:test-unit
set "TESTED_DIRS="
set "TEST_UNIT_ERR=0"
for /r %%f in (*_test.odin) do call :test-unit-one "%%f" "%%~dpf"
exit /b !TEST_UNIT_ERR!

:test-unit-one
if !TEST_UNIT_ERR! neq 0 exit /b
set "FPATH=%~1"
set "DPATH=%~2"
echo !FPATH! | findstr /i "\\pkgs\\" >nul && exit /b
echo !FPATH! | findstr /i "\\integration_test\\" >nul && exit /b
set "RELPATH=%~2"
set "RELPATH=!RELPATH:%CD%\=!"
if "!RELPATH:~-1!"=="\" set "RELPATH=!RELPATH:~0,-1!"
set "RELPATH=!RELPATH:\=/!"
echo !TESTED_DIRS! | findstr /i /c:"!RELPATH!" >nul && exit /b
set "TESTED_DIRS=!TESTED_DIRS! !RELPATH!"
for %%d in ("!RELPATH!") do set "DIRNAME=%%~nxd"
set "OUTDIR=bin\!RELPATH:/=\!"
if not exist "!OUTDIR!" mkdir "!OUTDIR!"
odin test ./!RELPATH! -out:!OUTDIR!\!DIRNAME!.exe %DEV_FLAGS% %TEST_FLAGS%
if errorlevel 1 set "TEST_UNIT_ERR=1"
exit /b

:test-integration
if not exist bin mkdir bin
echo building integration tests
odin test ./src/integration_test -out:bin/integration_test.exe %DEV_FLAGS% %TEST_FLAGS%
exit /b %errorlevel%

:bench-single
if not exist bin mkdir bin
odin build ./benchmarks/single_proccess/ -out:bin/benchmark.exe %RELEASE_FLAGS%
if errorlevel 1 exit /b 1
bin\benchmark.exe
exit /b %errorlevel%

:bench-network
if not exist bin mkdir bin
odin build ./benchmarks/network -out:bin/network_benchmark.exe %RELEASE_FLAGS%
if errorlevel 1 exit /b 1
bin\network_benchmark.exe
exit /b %errorlevel%

:gen-hot-api
if not exist bin mkdir bin
odin run ./src/pkgs/hot_reload/generator %DEV_FLAGS%
exit /b %errorlevel%

:clean
if exist bin rmdir /s /q bin
echo cleaned
exit /b 0

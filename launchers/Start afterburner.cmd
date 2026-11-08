@echo off
rem Start afterburner: everything this Bitburner scripts project needs, running
rem in this window. Double-click it in Explorer; close the window (or press
rem Ctrl-C) to stop. Keep it in your project folder, next to your Gemfile.
rem
rem It installs anything missing (bundle install, and npm install for the
rem TypeScript template), then runs "npm run watch" if package.json has a watch
rem script (the TypeScript template: compiler, file sync, and afterburner), or
rem else "afterburner watch".
setlocal

rem The folder whose files become the game's home folder. With src,
rem src\hello.rb runs in the game as "run hello.js".
set "SCRIPTS=src"

cd /d "%~dp0"
title afterburner - %CD%

where bundle >nul 2>nul
if errorlevel 1 goto :no_ruby
ruby -e "exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.4'))" 2>nul
if errorlevel 1 goto :no_ruby

echo Starting afterburner in %CD% ^(scripts in %SCRIPTS%^)
call bundle check >nul 2>nul || call bundle install || goto goto :stopped

:no_ruby
echo afterburner needs Ruby 3.4 or newer, with bundler: https://rubyinstaller.org

:stopped

findstr /c:"\"watch\"" package.json >nul 2>nul
if not errorlevel 1 (
  if not exist node_modules (call npm install || goto :stopped)
  set "AFTERBURNER_SRC=%SCRIPTS%"
  call npm run watch
) else (
  call bundle exec afterburner watch --src "%SCRIPTS%"
)

:stopped
echo.
echo afterburner has stopped.
pause

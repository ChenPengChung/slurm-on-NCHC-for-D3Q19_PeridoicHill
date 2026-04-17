@echo off
:: ================================================================
:: SSH_ASKPASS helper for NCHC keyboard-interactive authentication
:: Called by OpenSSH when SSH_ASKPASS_REQUIRE=force
::
:: Uses state-file approach (avoids parsing prompt text which may
:: contain parentheses/special chars that break CMD):
::   Call 1 (no state file) -> return NCHC_TWOFA ("2" = PUSH)
::   Call 2 (state file exists) -> return NCHC_PASS (password)
:: State file is cleaned up by the caller (PS1) before SSH starts.
:: ================================================================
setlocal EnableDelayedExpansion
set "SF=%TEMP%\nchc_askpass_step"
if exist "!SF!" (
    del "!SF!" >nul 2>&1
    echo !NCHC_PASS!
) else (
    echo.>"!SF!"
    echo !NCHC_TWOFA!
)
endlocal
exit /b 0

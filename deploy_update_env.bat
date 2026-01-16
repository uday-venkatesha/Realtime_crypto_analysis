@echo off
REM ============================================
REM Update Lambda Environment Variables (FIXED)
REM Properly escapes JSON values
REM ============================================

SETLOCAL EnableDelayedExpansion

SET AWS_REGION=us-east-1
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline

REM Check if .env file exists
IF NOT EXIST .env (
    echo Error: .env file not found
    echo Please create a .env file with your configuration
    exit /b 1
)

echo Loading environment variables from .env file...

REM Load variables from .env
FOR /F "usebackq tokens=1,* delims==" %%A IN (".env") DO (
    SET "line=%%A"
    IF NOT "!line:~0,1!"=="#" (
        IF "%%A"=="DB_HOST" SET "DB_HOST=%%B"
        IF "%%A"=="DB_PORT" SET "DB_PORT=%%B"
        IF "%%A"=="DB_NAME" SET "DB_NAME=%%B"
        IF "%%A"=="DB_USER" SET "DB_USER=%%B"
        IF "%%A"=="DB_PASSWORD" SET "DB_PASSWORD=%%B"
        IF "%%A"=="NEWSAPI_KEY" SET "NEWSAPI_KEY=%%B"
        IF "%%A"=="CRYPTO_SYMBOLS" SET "CRYPTO_SYMBOLS=%%B"
        IF "%%A"=="NEWS_QUERY" SET "NEWS_QUERY=%%B"
    )
)

echo.
echo Loaded values:
echo   DB_HOST: %DB_HOST%
echo   DB_PORT: %DB_PORT%
echo   DB_NAME: %DB_NAME%
echo   DB_USER: %DB_USER%
echo   DB_PASSWORD: ********
echo   NEWSAPI_KEY: ********
echo   CRYPTO_SYMBOLS: %CRYPTO_SYMBOLS%

REM Create JSON file (safer than inline JSON)
echo Creating environment configuration...

(
echo {
echo   "Variables": {
echo     "DB_HOST": "%DB_HOST%",
echo     "DB_PORT": "%DB_PORT%",
echo     "DB_NAME": "%DB_NAME%",
echo     "DB_USER": "%DB_USER%",
echo     "DB_PASSWORD": "%DB_PASSWORD%",
echo     "NEWSAPI_KEY": "%NEWSAPI_KEY%",
echo     "CRYPTO_SYMBOLS": "%CRYPTO_SYMBOLS%",
echo     "NEWS_SEARCH_QUERY": "%NEWS_QUERY%"
echo   }
echo }
) > lambda-env-config.json

echo.
echo Updating Lambda environment variables...

aws lambda update-function-configuration ^
    --function-name %LAMBDA_FUNCTION_NAME% ^
    --region %AWS_REGION% ^
    --environment file://lambda-env-config.json

IF %ERRORLEVEL% NEQ 0 (
    echo.
    echo Error: Failed to update environment variables
    echo Check lambda-env-config.json for details
    exit /b 1
)

echo   OK - Environment variables updated successfully!
echo   Waiting for function update to complete...

aws lambda wait function-updated ^
    --function-name %LAMBDA_FUNCTION_NAME% ^
    --region %AWS_REGION%

echo   OK - Lambda function ready!

REM Clean up
del lambda-env-config.json 2>nul

echo.
echo ======================================
echo Environment Variables Updated
echo ======================================
echo.
echo Next step: Test the function
echo   aws lambda invoke --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% response.json
echo.

ENDLOCAL
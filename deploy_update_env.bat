@echo off
REM ============================================
REM Update Lambda Environment Variables (Windows)
REM Use this to update secrets without redeploying
REM ============================================

SETLOCAL EnableDelayedExpansion

REM Configuration
SET AWS_REGION=us-east-1
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline

REM Check if .env file exists
IF NOT EXIST .env (
    echo Error: .env file not found
    echo Please create a .env file with your configuration
    exit /b 1
)

echo Loading environment variables from .env file...

REM Load variables from .env (simplified for Windows)
FOR /F "usebackq tokens=1,* delims==" %%A IN (".env") DO (
    SET "line=%%A"
    IF NOT "!line:~0,1!"=="#" (
        IF "%%A"=="DB_HOST" SET DB_HOST=%%B
        IF "%%A"=="DB_PORT" SET DB_PORT=%%B
        IF "%%A"=="DB_NAME" SET DB_NAME=%%B
        IF "%%A"=="DB_USER" SET DB_USER=%%B
        IF "%%A"=="DB_PASSWORD" SET DB_PASSWORD=%%B
        IF "%%A"=="NEWSAPI_KEY" SET NEWSAPI_KEY=%%B
        IF "%%A"=="CRYPTO_SYMBOLS" SET CRYPTO_SYMBOLS=%%B
        IF "%%A"=="NEWS_SEARCH_QUERY" SET NEWS_SEARCH_QUERY=%%B
    )
)

echo Updating Lambda environment variables...

REM Build JSON for environment variables
SET ENV_JSON={"DB_HOST":"%DB_HOST%","DB_PORT":"%DB_PORT%","DB_NAME":"%DB_NAME%","DB_USER":"%DB_USER%","DB_PASSWORD":"%DB_PASSWORD%","NEWSAPI_KEY":"%NEWSAPI_KEY%","CRYPTO_SYMBOLS":"%CRYPTO_SYMBOLS%"}

aws lambda update-function-configuration --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% --environment "Variables=%ENV_JSON%"

IF %ERRORLEVEL% NEQ 0 (
    echo Error: Failed to update environment variables
    exit /b 1
)

echo   OK - Environment variables updated successfully!
echo   Waiting for function update to complete...

aws lambda wait function-updated --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION%

echo   OK - Lambda function ready!

ENDLOCAL
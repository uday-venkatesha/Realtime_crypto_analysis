@echo off
REM ============================================
REM Update Existing Lambda Function Code
REM ============================================

SETLOCAL EnableDelayedExpansion

SET AWS_REGION=us-east-1
SET AWS_ACCOUNT_ID=587234333121
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline

echo ======================================
echo Updating Lambda Function Code
echo ======================================

SET DOCKER_BUILDKIT=0

echo.
echo [1/5] Cleaning old images...
docker rmi %ECR_REPOSITORY_NAME%:latest -f 2>nul
docker rmi %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest -f 2>nul

echo.
echo [2/5] Logging into ECR...
FOR /F "tokens=*" %%A IN ('aws ecr get-login-password --region %AWS_REGION%') DO SET ECR_PASSWORD=%%A
echo %ECR_PASSWORD% | docker login --username AWS --password-stdin %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com

echo.
echo [3/5] Building new image with fixed code...
SET IMAGE_URI=%AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest

docker build -f Dockerfile.simple --no-cache -t %IMAGE_URI% .

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Build failed
    exit /b 1
)

echo.
echo [4/5] Pushing to ECR...
docker push %IMAGE_URI%

echo   Waiting 5 seconds...
timeout /t 5 /nobreak >nul

echo.
echo [5/5] Updating Lambda function code...
aws lambda update-function-code ^
    --function-name %LAMBDA_FUNCTION_NAME% ^
    --image-uri %IMAGE_URI% ^
    --region %AWS_REGION%

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Update failed
    exit /b 1
)

echo   Waiting for function update...
aws lambda wait function-updated ^
    --function-name %LAMBDA_FUNCTION_NAME% ^
    --region %AWS_REGION%

echo.
echo ======================================
echo Update Complete!
echo ======================================
echo.
echo Test with:
echo   aws lambda invoke --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% response.json
echo   type response.json
echo.

ENDLOCAL
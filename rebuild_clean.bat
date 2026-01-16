@echo off
REM ============================================
REM NUCLEAR OPTION - Complete Clean Rebuild
REM Fixes: Image manifest not supported error
REM ============================================

SETLOCAL EnableDelayedExpansion

SET AWS_REGION=us-east-1
SET AWS_ACCOUNT_ID=587234333121
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline
SET LAMBDA_ROLE_NAME=CryptoSentimentLambdaRole

echo ======================================
echo COMPLETE CLEAN REBUILD
echo This will fix the manifest issue
echo ======================================
echo.
echo This script will:
echo 1. Delete ALL local Docker images
echo 2. Delete and recreate ECR repository
echo 3. Pull fresh AWS Lambda base image
echo 4. Build with explicit platform
echo 5. Push using Docker manifest
echo 6. Create Lambda function
echo.
pause

REM ===== STEP 1: NUCLEAR CLEANUP =====
echo.
echo [1/10] NUCLEAR CLEANUP - Removing all traces...

echo   Removing local Docker images...
docker rmi %ECR_REPOSITORY_NAME%:latest -f 2>nul
docker rmi %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest -f 2>nul
docker rmi public.ecr.aws/lambda/python:3.11 -f 2>nul

echo   Pruning Docker system...
docker system prune -f >nul 2>&1

echo   Deleting ECR repository...
aws ecr delete-repository --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --force >nul 2>&1

echo   OK - Everything cleaned

REM ===== STEP 2: FRESH START =====
echo.
echo [2/10] Creating fresh ECR repository...
aws ecr create-repository ^
    --repository-name %ECR_REPOSITORY_NAME% ^
    --region %AWS_REGION% ^
    --image-scanning-configuration scanOnPush=true

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Failed to create repository
    exit /b 1
)
echo   OK - Fresh repository created

REM ===== STEP 3: PULL BASE IMAGE =====
echo.
echo [3/10] Pulling AWS Lambda Python base image...
docker pull --platform linux/amd64 public.ecr.aws/lambda/python:3.11

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Failed to pull base image
    exit /b 1
)
echo   OK - Base image pulled

REM ===== STEP 4: VERIFY BASE IMAGE =====
echo.
echo [4/10] Verifying base image architecture...
FOR /F "tokens=*" %%A IN ('docker inspect public.ecr.aws/lambda/python:3.11 --format="{{.Architecture}}"') DO SET BASE_ARCH=%%A
echo   Architecture: %BASE_ARCH%

IF NOT "%BASE_ARCH%"=="amd64" (
    echo   ERROR - Base image is not amd64!
    exit /b 1
)
echo   OK - Base image is amd64

REM ===== STEP 5: LOGIN TO ECR =====
echo.
echo [5/10] Logging into ECR...
FOR /F "tokens=*" %%A IN ('aws ecr get-login-password --region %AWS_REGION%') DO SET ECR_PASSWORD=%%A
echo %ECR_PASSWORD% | docker login --username AWS --password-stdin %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - ECR login failed
    exit /b 1
)
echo   OK - Logged into ECR

REM ===== STEP 6: BUILD IMAGE =====
echo.
echo [6/10] Building Docker image with EXPLICIT platform...
SET IMAGE_URI=%AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest

docker build ^
    --platform linux/amd64 ^
    --pull ^
    --no-cache ^
    -t %ECR_REPOSITORY_NAME%:latest ^
    -t %IMAGE_URI% ^
    .

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Build failed
    exit /b 1
)
echo   OK - Image built successfully

REM ===== STEP 7: VERIFY LOCAL IMAGE =====
echo.
echo [7/10] Verifying built image...
FOR /F "tokens=*" %%A IN ('docker inspect %ECR_REPOSITORY_NAME%:latest --format="{{.Architecture}}"') DO SET IMG_ARCH=%%A
echo   Built image architecture: %IMG_ARCH%

IF NOT "%IMG_ARCH%"=="amd64" (
    echo   ERROR - Built image is not amd64!
    echo   Your Docker might not support --platform flag properly
    exit /b 1
)
echo   OK - Built image is amd64

REM ===== STEP 8: PUSH TO ECR =====
echo.
echo [8/10] Pushing to ECR (this may take a few minutes)...
docker push %IMAGE_URI%

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Push failed
    exit /b 1
)
echo   OK - Image pushed successfully

REM ===== STEP 9: VERIFY ECR IMAGE =====
echo.
echo [9/10] Verifying image in ECR...
timeout /t 3 /nobreak >nul

aws ecr describe-images --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --output table

echo.
echo   Checking image manifest...
aws ecr batch-get-image ^
    --repository-name %ECR_REPOSITORY_NAME% ^
    --image-ids imageTag=latest ^
    --region %AWS_REGION% ^
    --query "images[0].imageId" ^
    --output table

echo   OK - Image verified in ECR

REM ===== STEP 10: CREATE LAMBDA =====
echo.
echo [10/10] Creating Lambda function...

REM Check if role exists
aws iam get-role --role-name %LAMBDA_ROLE_NAME% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   Creating IAM role...
    echo {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]} > trust-policy.json
    
    aws iam create-role --role-name %LAMBDA_ROLE_NAME% --assume-role-policy-document file://trust-policy.json
    aws iam attach-role-policy --role-name %LAMBDA_ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    del trust-policy.json
    echo   Waiting 20 seconds for IAM role propagation...
    timeout /t 20 /nobreak >nul
)

FOR /F "tokens=*" %%A IN ('aws iam get-role --role-name %LAMBDA_ROLE_NAME% --query "Role.Arn" --output text') DO SET LAMBDA_ROLE_ARN=%%A

echo   Creating Lambda function with verified image...
echo   Image: %IMAGE_URI%
echo   Role: %LAMBDA_ROLE_ARN%

aws lambda create-function ^
    --function-name %LAMBDA_FUNCTION_NAME% ^
    --package-type Image ^
    --code ImageUri=%IMAGE_URI% ^
    --role %LAMBDA_ROLE_ARN% ^
    --architectures x86_64 ^
    --timeout 900 ^
    --memory-size 512 ^
    --region %AWS_REGION%

IF %ERRORLEVEL% NEQ 0 (
    echo.
    echo   ERROR - Lambda creation still failed!
    echo.
    echo   Let's try one more diagnostic:
    aws ecr describe-images --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --output json > ecr-details.json
    echo   ECR details saved to ecr-details.json
    echo.
    echo   This might be an AWS account or service quota issue.
    echo   Try creating the function manually in AWS Console.
    exit /b 1
)

echo   OK - Lambda function created!

echo.
echo ======================================
echo SUCCESS! 
echo ======================================
echo.
echo Lambda function created: %LAMBDA_FUNCTION_NAME%
echo Region: %AWS_REGION%
echo.
echo Next steps:
echo 1. Run: deploy_update_env.bat
echo 2. Test: aws lambda invoke --function-name %LAMBDA_FUNCTION_NAME% response.json
echo.

ENDLOCAL
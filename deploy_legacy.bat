@echo off
REM ============================================
REM Legacy Docker Build (No BuildKit)
REM Uses old Docker image format compatible with Lambda
REM ============================================

SETLOCAL EnableDelayedExpansion

SET AWS_REGION=us-east-1
SET AWS_ACCOUNT_ID=587234333121
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline
SET LAMBDA_ROLE_NAME=CryptoSentimentLambdaRole

echo ======================================
echo Legacy Docker Build for Lambda
echo Using Docker Image Manifest V2 Schema 2
echo ======================================

REM CRITICAL: Disable BuildKit completely
SET DOCKER_BUILDKIT=0
SET BUILDKIT_PROGRESS=

echo.
echo [1/8] Environment setup...
echo   DOCKER_BUILDKIT=0 (disabled)
echo   Target: Docker Image Manifest V2, Schema 2

REM Clean everything
echo.
echo [2/8] Cleaning previous builds...
docker rmi %ECR_REPOSITORY_NAME%:latest -f 2>nul
docker rmi %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest -f 2>nul

REM Recreate ECR repository
echo.
echo [3/8] Recreating ECR repository...
aws ecr delete-repository --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --force 2>nul
aws ecr create-repository --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --image-scanning-configuration scanOnPush=false
echo   OK - Fresh repository ready

REM Login to ECR
echo.
echo [4/8] Logging into ECR...
FOR /F "tokens=*" %%A IN ('aws ecr get-login-password --region %AWS_REGION%') DO SET ECR_PASSWORD=%%A
echo %ECR_PASSWORD% | docker login --username AWS --password-stdin %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com
echo   OK

REM Build with legacy builder
echo.
echo [5/8] Building with LEGACY Docker builder...
echo   Using: Dockerfile.simple
echo   BuildKit: DISABLED
echo   This ensures Docker Image Manifest V2, Schema 2

SET IMAGE_URI=%AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest

docker build ^
    -f Dockerfile.simple ^
    --no-cache ^
    -t %IMAGE_URI% ^
    .

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Build failed
    exit /b 1
)
echo   OK - Image built with legacy builder

REM Verify image format
echo.
echo [6/8] Verifying image format...
docker inspect %IMAGE_URI% --format="Architecture: {{.Architecture}}, OS: {{.Os}}" 
docker inspect %IMAGE_URI% --format="ManifestType: {{.Config.Image}}"

REM Push to ECR
echo.
echo [7/8] Pushing to ECR...
docker push %IMAGE_URI%

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Push failed
    exit /b 1
)
echo   OK - Pushed

echo   Waiting 10 seconds for ECR...
timeout /t 10 /nobreak >nul

REM Verify what's in ECR
echo.
echo   Checking ECR manifest type...
aws ecr batch-get-image ^
    --repository-name %ECR_REPOSITORY_NAME% ^
    --image-ids imageTag=latest ^
    --region %AWS_REGION% ^
    --query "images[0].imageManifest" ^
    --output text > ecr_manifest.txt

findstr "schemaVersion" ecr_manifest.txt
findstr "mediaType" ecr_manifest.txt

REM Create Lambda
echo.
echo [8/8] Creating Lambda function...

REM Ensure role exists
aws iam get-role --role-name %LAMBDA_ROLE_NAME% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   Creating IAM role...
    echo {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]} > trust-policy.json
    aws iam create-role --role-name %LAMBDA_ROLE_NAME% --assume-role-policy-document file://trust-policy.json
    aws iam attach-role-policy --role-name %LAMBDA_ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    del trust-policy.json
    timeout /t 20 /nobreak >nul
)

FOR /F "tokens=*" %%A IN ('aws iam get-role --role-name %LAMBDA_ROLE_NAME% --query "Role.Arn" --output text') DO SET LAMBDA_ROLE_ARN=%%A

aws lambda create-function ^
    --function-name %LAMBDA_FUNCTION_NAME% ^
    --package-type Image ^
    --code ImageUri=%IMAGE_URI% ^
    --role %LAMBDA_ROLE_ARN% ^
    --architectures x86_64 ^
    --timeout 900 ^
    --memory-size 512 ^
    --region %AWS_REGION%

IF %ERRORLEVEL% EQU 0 (
    echo.
    echo ======================================
    echo SUCCESS!
    echo ======================================
    echo.
    echo Function: %LAMBDA_FUNCTION_NAME%
    echo Region: %AWS_REGION%
    echo.
    echo Next: deploy_update_env.bat
) ELSE (
    echo.
    echo ======================================
    echo Still Failed - Try Manual Creation
    echo ======================================
    echo.
    echo The image is valid in ECR but Lambda rejects it.
    echo This might be an AWS account or regional issue.
    echo.
    echo Try creating manually:
    echo 1. Go to: https://console.aws.amazon.com/lambda
    echo 2. Click "Create function"
    echo 3. Choose "Container image"
    echo 4. Function name: %LAMBDA_FUNCTION_NAME%
    echo 5. Browse images: Select %ECR_REPOSITORY_NAME%:latest
    echo 6. Architecture: x86_64
    echo 7. Create
    echo.
    echo If manual creation also fails, the issue might be:
    echo - Lambda service quota in your region
    echo - AWS account permissions
    echo - Regional Lambda service issue
)

ENDLOCAL
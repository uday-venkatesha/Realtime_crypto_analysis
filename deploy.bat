@echo off
REM ============================================
REM AWS Lambda Deployment Script (FIXED v2)
REM Crypto Sentiment ETL Pipeline
REM Addresses: Image manifest/config not supported
REM ============================================

SETLOCAL EnableDelayedExpansion

REM Configuration
SET AWS_REGION=us-east-1
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline
SET LAMBDA_ROLE_NAME=CryptoSentimentLambdaRole

echo ======================================
echo Crypto Sentiment Pipeline Deployment
echo FIXED v2 - Multi-platform build
echo ======================================

REM Step 1: Check AWS CLI
echo.
echo [Step 1/9] Checking AWS CLI configuration...
aws sts get-caller-identity >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Error: AWS CLI not configured. Run 'aws configure' first.
    exit /b 1
)

FOR /F "tokens=*" %%A IN ('aws sts get-caller-identity --query Account --output text') DO SET AWS_ACCOUNT_ID=%%A
echo   OK - AWS Account ID: %AWS_ACCOUNT_ID%

REM Step 2: Check Docker
echo.
echo [Step 2/9] Checking Docker...
docker --version >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Error: Docker is not running or not installed
    exit /b 1
)
echo   OK - Docker is ready

REM Step 3: Setup buildx (for multi-platform builds)
echo.
echo [Step 3/9] Setting up Docker buildx...
docker buildx create --name lambda-builder --use 2>nul || docker buildx use lambda-builder
docker buildx inspect --bootstrap >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   Warning: buildx setup failed, will try standard build
    SET USE_BUILDX=0
) ELSE (
    echo   OK - buildx ready for multi-platform builds
    SET USE_BUILDX=1
)

REM Step 4: Clean up old images
echo.
echo [Step 4/9] Cleaning up old local images...
docker rmi %ECR_REPOSITORY_NAME%:latest 2>nul
docker rmi %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest 2>nul
echo   OK - Old images removed

REM Step 5: ECR repository
echo.
echo [Step 5/9] Checking ECR repository...
aws ecr describe-repositories --repository-names %ECR_REPOSITORY_NAME% --region %AWS_REGION% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   Creating new ECR repository...
    aws ecr create-repository --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --image-scanning-configuration scanOnPush=true
    echo   OK - ECR repository created
) ELSE (
    echo   OK - ECR repository already exists
)

REM Step 6: Login to ECR
echo.
echo [Step 6/9] Logging into ECR...
FOR /F "tokens=*" %%A IN ('aws ecr get-login-password --region %AWS_REGION%') DO SET ECR_PASSWORD=%%A
echo %ECR_PASSWORD% | docker login --username AWS --password-stdin %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com
IF %ERRORLEVEL% NEQ 0 (
    echo Error: Failed to login to ECR
    exit /b 1
)
echo   OK - Logged into ECR

REM Step 7: Build Docker image
echo.
echo [Step 7/9] Building Docker image...
echo   Platform: linux/amd64 (AWS Lambda compatible)
echo   This may take 5-10 minutes...

SET IMAGE_URI=%AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest

IF "%USE_BUILDX%"=="1" (
    echo   Using buildx for optimized build...
    docker buildx build --platform linux/amd64 -t %IMAGE_URI% --push . 
    IF %ERRORLEVEL% NEQ 0 (
        echo   Buildx failed, trying standard build...
        goto STANDARD_BUILD
    )
    echo   OK - Image built and pushed via buildx
    goto BUILD_COMPLETE
) ELSE (
    :STANDARD_BUILD
    echo   Using standard Docker build...
    docker build --platform linux/amd64 -t %ECR_REPOSITORY_NAME%:latest .
    IF %ERRORLEVEL% NEQ 0 (
        echo Error: Docker build failed
        exit /b 1
    )
    echo   OK - Docker image built
    
    REM Step 8: Tag image
    echo.
    echo [Step 8/9] Tagging Docker image...
    docker tag %ECR_REPOSITORY_NAME%:latest %IMAGE_URI%
    echo   OK - Image tagged
    
    REM Step 9: Push to ECR
    echo.
    echo [Step 9/9] Pushing image to ECR...
    docker push %IMAGE_URI%
    IF %ERRORLEVEL% NEQ 0 (
        echo Error: Failed to push image to ECR
        exit /b 1
    )
    echo   OK - Image pushed to ECR
)

:BUILD_COMPLETE

REM Step 10: Wait for image to be available
echo.
echo [Step 10/11] Waiting for ECR image to be available...
timeout /t 5 /nobreak >nul
echo   OK - Image should be ready

REM Step 11: Setup IAM Role
echo.
echo [Step 11/11] Setting up Lambda IAM role...
aws iam get-role --role-name %LAMBDA_ROLE_NAME% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   Creating IAM role...
    echo {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]} > trust-policy.json
    
    aws iam create-role --role-name %LAMBDA_ROLE_NAME% --assume-role-policy-document file://trust-policy.json
    aws iam attach-role-policy --role-name %LAMBDA_ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    echo   OK - IAM role created
    echo   Waiting 15 seconds for role to propagate...
    timeout /t 15 /nobreak >nul
    
    del trust-policy.json
) ELSE (
    echo   OK - IAM role already exists
)

FOR /F "tokens=*" %%A IN ('aws iam get-role --role-name %LAMBDA_ROLE_NAME% --query "Role.Arn" --output text') DO SET LAMBDA_ROLE_ARN=%%A

REM Step 12: Create/Update Lambda function
echo.
echo [Step 12/12] Creating/Updating Lambda function...
aws lambda get-function --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   Creating new Lambda function...
    echo   Image URI: %IMAGE_URI%
    
    aws lambda create-function ^
        --function-name %LAMBDA_FUNCTION_NAME% ^
        --package-type Image ^
        --code ImageUri=%IMAGE_URI% ^
        --role %LAMBDA_ROLE_ARN% ^
        --timeout 900 ^
        --memory-size 512 ^
        --region %AWS_REGION% ^
        --architectures x86_64
    
    IF %ERRORLEVEL% NEQ 0 (
        echo.
        echo Error: Failed to create Lambda function
        echo.
        echo Troubleshooting:
        echo 1. Check if image manifest is compatible
        echo 2. Verify ECR image was pushed successfully
        echo 3. Try: aws ecr describe-images --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION%
        exit /b 1
    )
    echo   OK - Lambda function created
) ELSE (
    echo   Updating existing Lambda function...
    aws lambda update-function-code --function-name %LAMBDA_FUNCTION_NAME% --image-uri %IMAGE_URI% --region %AWS_REGION% --architectures x86_64
    
    echo   Waiting for function update to complete...
    aws lambda wait function-updated --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION%
    
    echo   OK - Lambda function updated
)

echo.
echo ======================================
echo   Deployment Completed Successfully!
echo ======================================
echo.
echo Lambda Function: %LAMBDA_FUNCTION_NAME%
echo Region: %AWS_REGION%
echo Image: %IMAGE_URI%
echo.
echo Next steps:
echo 1. Run: deploy_update_env.bat (to set environment variables)
echo 2. Test: aws lambda invoke --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% response.json
echo 3. Set up EventBridge schedule
echo.

ENDLOCAL
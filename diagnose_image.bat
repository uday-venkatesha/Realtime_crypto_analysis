@echo off
REM ============================================
REM Diagnostic Script - Check ECR Image
REM ============================================

SET AWS_REGION=us-east-1
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET AWS_ACCOUNT_ID=587234333121

echo ======================================
echo ECR Image Diagnostic Tool
echo ======================================

echo.
echo [1/5] Checking ECR repository exists...
aws ecr describe-repositories --repository-names %ECR_REPOSITORY_NAME% --region %AWS_REGION% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Repository does not exist
    exit /b 1
)
echo   OK - Repository exists

echo.
echo [2/5] Listing images in repository...
aws ecr describe-images --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --output table
IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Failed to list images
    exit /b 1
)

echo.
echo [3/5] Getting image manifest details...
aws ecr batch-get-image --repository-name %ECR_REPOSITORY_NAME% --image-ids imageTag=latest --region %AWS_REGION% --query "images[0].imageManifest" --output text > manifest.json 2>nul
IF %ERRORLEVEL% EQU 0 (
    echo   Manifest saved to manifest.json
    type manifest.json
) ELSE (
    echo   WARNING - Could not retrieve manifest
)

echo.
echo [4/5] Checking local Docker images...
echo   Looking for: %ECR_REPOSITORY_NAME%:latest
docker images | findstr %ECR_REPOSITORY_NAME%

echo.
echo [5/5] Inspecting local image architecture...
docker inspect %ECR_REPOSITORY_NAME%:latest 2>nul | findstr "Architecture"
IF %ERRORLEVEL% NEQ 0 (
    echo   Note: Local image not found or already removed
) ELSE (
    echo.
    docker inspect %ECR_REPOSITORY_NAME%:latest --format="{{.Architecture}} {{.Os}}"
)

echo.
echo ======================================
echo Diagnosis Complete
echo ======================================
echo.
echo If you see "amd64 linux" above, the image is correct.
echo If you see "arm64" or anything else, that's the problem.
echo.
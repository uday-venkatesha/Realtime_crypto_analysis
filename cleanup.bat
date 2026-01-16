@echo off
REM ============================================
REM Cleanup Script - Remove failed deployment
REM ============================================

SET AWS_REGION=us-east-1
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline
SET LAMBDA_ROLE_NAME=CryptoSentimentLambdaRole

echo ======================================
echo Cleaning Up Failed Deployment
echo ======================================

echo.
echo [1/4] Deleting Lambda function (if exists)...
aws lambda delete-function --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% 2>nul
IF %ERRORLEVEL% EQU 0 (
    echo   OK - Lambda function deleted
) ELSE (
    echo   Note - Lambda function does not exist or already deleted
)

echo.
echo [2/4] Detaching IAM policies...
aws iam detach-role-policy --role-name %LAMBDA_ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>nul
echo   OK - Policies detached

echo.
echo [3/4] Deleting IAM role...
aws iam delete-role --role-name %LAMBDA_ROLE_NAME% 2>nul
IF %ERRORLEVEL% EQU 0 (
    echo   OK - IAM role deleted
) ELSE (
    echo   Note - IAM role does not exist or already deleted
)

echo.
echo [4/4] Deleting ECR images...
aws ecr batch-delete-image --repository-name %ECR_REPOSITORY_NAME% --image-ids imageTag=latest --region %AWS_REGION% 2>nul
echo   OK - ECR images deleted (repository kept for reuse)

echo.
echo ======================================
echo Cleanup Complete!
echo ======================================
echo.
echo You can now run deploy.bat again with the fixed configuration.
echo.
@echo off
REM ============================================
REM AWS Lambda Deployment Script (Consolidated)
REM Crypto Sentiment ETL Pipeline
REM ============================================

SETLOCAL EnableDelayedExpansion

REM Configuration
SET AWS_REGION=us-east-1
SET ECR_REPOSITORY_NAME=crypto-sentiment-etl
SET LAMBDA_FUNCTION_NAME=crypto-sentiment-pipeline
SET LAMBDA_ROLE_NAME=CryptoSentimentLambdaRole

REM Check for command line arguments
SET ACTION=%1
IF "%ACTION%"=="" SET ACTION=deploy
IF "%ACTION%"=="help" GOTO SHOW_HELP
IF "%ACTION%"=="clean" GOTO CLEAN
IF "%ACTION%"=="update-env" GOTO UPDATE_ENV
IF "%ACTION%"=="update-code" GOTO UPDATE_CODE
IF "%ACTION%"=="schedule" GOTO SETUP_SCHEDULE
IF "%ACTION%"=="deploy" GOTO DEPLOY
GOTO SHOW_HELP

:SHOW_HELP
echo.
echo Crypto Sentiment Pipeline - Deployment Tool
echo.
echo Usage: deploy.bat [command]
echo.
echo Commands:
echo   deploy        - Full deployment (default)
echo   update-code   - Update Lambda code only
echo   update-env    - Update environment variables only
echo   schedule      - Setup EventBridge schedule
echo   clean         - Remove all AWS resources
echo   help          - Show this help
echo.
GOTO END

:DEPLOY
echo ======================================
echo Crypto Sentiment Pipeline Deployment
echo ======================================

echo.
echo [1/9] Checking AWS CLI...
aws sts get-caller-identity >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Error: AWS CLI not configured. Run 'aws configure' first.
    exit /b 1
)

FOR /F "tokens=*" %%A IN ('aws sts get-caller-identity --query Account --output text') DO SET AWS_ACCOUNT_ID=%%A
echo   OK - AWS Account: %AWS_ACCOUNT_ID%

echo.
echo [2/9] Checking Docker...
docker --version >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Error: Docker not running
    exit /b 1
)
echo   OK - Docker ready

echo.
echo [3/9] Creating ECR repository...
aws ecr describe-repositories --repository-names %ECR_REPOSITORY_NAME% --region %AWS_REGION% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    aws ecr create-repository --repository-name %ECR_REPOSITORY_NAME% --region %AWS_REGION% --image-scanning-configuration scanOnPush=true >nul
    echo   Created: %ECR_REPOSITORY_NAME%
) ELSE (
    echo   OK - Repository exists
)

echo.
echo [4/9] Logging into ECR...
FOR /F "tokens=*" %%A IN ('aws ecr get-login-password --region %AWS_REGION%') DO SET ECR_PASSWORD=%%A
echo %ECR_PASSWORD% | docker login --username AWS --password-stdin %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com >nul 2>&1
echo   OK - Logged in

echo.
echo [5/9] Building Docker image...
SET IMAGE_URI=%AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest
docker build --platform linux/amd64 -t %IMAGE_URI% . >nul
IF %ERRORLEVEL% NEQ 0 (
    echo Error: Build failed
    exit /b 1
)
echo   OK - Image built

echo.
echo [6/9] Pushing to ECR...
docker push %IMAGE_URI% >nul
echo   OK - Image pushed

echo.
echo [7/9] Setting up IAM role...
aws iam get-role --role-name %LAMBDA_ROLE_NAME% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]} > trust-policy.json
    aws iam create-role --role-name %LAMBDA_ROLE_NAME% --assume-role-policy-document file://trust-policy.json >nul
    aws iam attach-role-policy --role-name %LAMBDA_ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >nul
    del trust-policy.json
    echo   Created: %LAMBDA_ROLE_NAME%
    timeout /t 10 /nobreak >nul
) ELSE (
    echo   OK - Role exists
)

FOR /F "tokens=*" %%A IN ('aws iam get-role --role-name %LAMBDA_ROLE_NAME% --query "Role.Arn" --output text') DO SET LAMBDA_ROLE_ARN=%%A

echo.
echo [8/9] Creating Lambda function...
aws lambda get-function --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    aws lambda create-function --function-name %LAMBDA_FUNCTION_NAME% --package-type Image --code ImageUri=%IMAGE_URI% --role %LAMBDA_ROLE_ARN% --timeout 900 --memory-size 512 --region %AWS_REGION% --architectures x86_64 >nul
    echo   Created: %LAMBDA_FUNCTION_NAME%
) ELSE (
    aws lambda update-function-code --function-name %LAMBDA_FUNCTION_NAME% --image-uri %IMAGE_URI% --region %AWS_REGION% >nul
    aws lambda wait function-updated --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION%
    echo   Updated: %LAMBDA_FUNCTION_NAME%
)

echo.
echo [9/9] Updating environment variables...
IF NOT EXIST .env (
    echo Warning: .env file not found
    echo Create .env from .env.example and run: deploy.bat update-env
) ELSE (
    CALL :UPDATE_ENV_INTERNAL
)

echo.
echo ======================================
echo Deployment Complete!
echo ======================================
echo.
echo Function: %LAMBDA_FUNCTION_NAME%
echo Region: %AWS_REGION%
echo.
echo Next steps:
echo   1. Setup schedule: deploy.bat schedule
echo   2. Test: aws lambda invoke --function-name %LAMBDA_FUNCTION_NAME% response.json
echo.
GOTO END

:UPDATE_CODE
echo ======================================
echo Updating Lambda Code
echo ======================================

FOR /F "tokens=*" %%A IN ('aws sts get-caller-identity --query Account --output text') DO SET AWS_ACCOUNT_ID=%%A
SET IMAGE_URI=%AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%ECR_REPOSITORY_NAME%:latest

echo.
echo [1/3] Building new image...
docker build --platform linux/amd64 -t %IMAGE_URI% . >nul
echo   OK

echo.
echo [2/3] Pushing to ECR...
FOR /F "tokens=*" %%A IN ('aws ecr get-login-password --region %AWS_REGION%') DO SET ECR_PASSWORD=%%A
echo %ECR_PASSWORD% | docker login --username AWS --password-stdin %AWS_ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com >nul 2>&1
docker push %IMAGE_URI% >nul
echo   OK

echo.
echo [3/3] Updating Lambda...
aws lambda update-function-code --function-name %LAMBDA_FUNCTION_NAME% --image-uri %IMAGE_URI% --region %AWS_REGION% >nul
aws lambda wait function-updated --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION%
echo   OK - Updated
GOTO END

:UPDATE_ENV
IF NOT EXIST .env (
    echo Error: .env file not found
    echo Create .env from .env.example first
    exit /b 1
)
CALL :UPDATE_ENV_INTERNAL
GOTO END

:UPDATE_ENV_INTERNAL
echo Loading variables from .env...
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
        IF "%%A"=="NEWS_SEARCH_QUERY" SET "NEWS_QUERY=%%B"
    )
)

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
) > lambda-env.json

aws lambda update-function-configuration --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% --environment file://lambda-env.json >nul
aws lambda wait function-updated --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION%
del lambda-env.json
echo   OK - Environment updated
GOTO :EOF

:SETUP_SCHEDULE
echo ======================================
echo Setting up EventBridge Schedule
echo ======================================

FOR /F "tokens=*" %%A IN ('aws sts get-caller-identity --query Account --output text') DO SET AWS_ACCOUNT_ID=%%A
SET LAMBDA_ARN=arn:aws:lambda:%AWS_REGION%:%AWS_ACCOUNT_ID%:function:%LAMBDA_FUNCTION_NAME%
SET RULE_NAME=crypto-sentiment-schedule

echo.
echo [1/3] Creating EventBridge rule...
aws events put-rule --name %RULE_NAME% --schedule-expression "rate(30 minutes)" --region %AWS_REGION% >nul
echo   OK - Rule: %RULE_NAME%

echo.
echo [2/3] Adding Lambda target...
echo [{"Id":"1","Arn":"%LAMBDA_ARN%"}] > targets.json
aws events put-targets --rule %RULE_NAME% --targets file://targets.json --region %AWS_REGION% >nul
del targets.json
echo   OK - Target added

echo.
echo [3/3] Granting permissions...
aws lambda add-permission --function-name %LAMBDA_FUNCTION_NAME% --statement-id EventBridgeInvoke --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn arn:aws:events:%AWS_REGION%:%AWS_ACCOUNT_ID%:rule/%RULE_NAME% --region %AWS_REGION% 2>nul
echo   OK - Permissions granted

echo.
echo ======================================
echo Schedule Setup Complete!
echo ======================================
echo Lambda will run every 30 minutes
GOTO END

:CLEAN
echo ======================================
echo Cleaning Up AWS Resources
echo ======================================

echo.
echo [1/4] Deleting Lambda function...
aws lambda delete-function --function-name %LAMBDA_FUNCTION_NAME% --region %AWS_REGION% 2>nul
echo   OK

echo.
echo [2/4] Removing IAM policies...
aws iam detach-role-policy --role-name %LAMBDA_ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>nul
aws iam delete-role --role-name %LAMBDA_ROLE_NAME% 2>nul
echo   OK

echo.
echo [3/4] Deleting ECR images...
aws ecr batch-delete-image --repository-name %ECR_REPOSITORY_NAME% --image-ids imageTag=latest --region %AWS_REGION% 2>nul
echo   OK

echo.
echo [4/4] Deleting EventBridge rule...
aws events remove-targets --rule crypto-sentiment-schedule --ids 1 --region %AWS_REGION% 2>nul
aws events delete-rule --name crypto-sentiment-schedule --region %AWS_REGION% 2>nul
echo   OK

echo.
echo Cleanup complete!
GOTO END

:END
ENDLOCAL
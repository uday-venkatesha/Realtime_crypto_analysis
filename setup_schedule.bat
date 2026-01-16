@echo off
REM ============================================
REM Setup EventBridge Schedule
REM Runs Lambda every 30 minutes
REM ============================================

SET AWS_REGION=us-east-1
SET LAMBDA_ARN=arn:aws:lambda:us-east-1:587234333121:function:crypto-sentiment-pipeline
SET RULE_NAME=crypto-sentiment-schedule

echo ======================================
echo Setting up EventBridge Schedule
echo ======================================

echo.
echo [1/3] Creating EventBridge rule (30-minute interval)...
aws events put-rule ^
    --name %RULE_NAME% ^
    --schedule-expression "rate(30 minutes)" ^
    --region %AWS_REGION%

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Failed to create rule
    exit /b 1
)
echo   OK - Rule created

echo.
echo [2/3] Adding Lambda as target...

REM Create targets JSON file
echo [{"Id":"1","Arn":"%LAMBDA_ARN%"}] > targets.json

aws events put-targets ^
    --rule %RULE_NAME% ^
    --targets file://targets.json ^
    --region %AWS_REGION%

IF %ERRORLEVEL% NEQ 0 (
    echo   ERROR - Failed to add target
    del targets.json
    exit /b 1
)
echo   OK - Target added

REM Clean up
del targets.json

echo.
echo [3/3] Granting EventBridge permission...
aws lambda add-permission ^
    --function-name crypto-sentiment-pipeline ^
    --statement-id EventBridgeInvoke ^
    --action lambda:InvokeFunction ^
    --principal events.amazonaws.com ^
    --source-arn arn:aws:events:us-east-1:587234333121:rule/%RULE_NAME% ^
    --region %AWS_REGION% 2>nul

IF %ERRORLEVEL% EQU 0 (
    echo   OK - Permission granted
) ELSE (
    echo   Note - Permission already exists
)

echo.
echo ======================================
echo Schedule Setup Complete!
echo ======================================
echo.
echo Your Lambda function will now run automatically every 30 minutes.
echo.
echo Verify in AWS Console:
echo https://console.aws.amazon.com/events/home?region=us-east-1#/rules
echo.
echo To disable the schedule:
echo   aws events disable-rule --name %RULE_NAME% --region %AWS_REGION%
echo.
echo To enable it again:
echo   aws events enable-rule --name %RULE_NAME% --region %AWS_REGION%
echo.
echo To delete the schedule:
echo   aws events remove-targets --rule %RULE_NAME% --ids 1 --region %AWS_REGION%
echo   aws events delete-rule --name %RULE_NAME% --region %AWS_REGION%
echo.
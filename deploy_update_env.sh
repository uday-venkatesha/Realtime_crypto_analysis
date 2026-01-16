#!/bin/bash

# ============================================
# Update Lambda Environment Variables
# Use this to update secrets without redeploying
# ============================================

set -e

# Load environment variables from .env file
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

# Configuration
AWS_REGION="us-east-1"
LAMBDA_FUNCTION_NAME="crypto-sentiment-pipeline"

echo "Updating Lambda environment variables..."

aws lambda update-function-configuration \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $AWS_REGION \
    --environment Variables="{
        DB_HOST=$DB_HOST,
        DB_PORT=$DB_PORT,
        DB_NAME=$DB_NAME,
        DB_USER=$DB_USER,
        DB_PASSWORD=$DB_PASSWORD,
        NEWSAPI_KEY=$NEWSAPI_KEY,
        CRYPTO_SYMBOLS=bitcoin,ethereum,
        NEWS_SEARCH_QUERY=\"$NEWS_SEARCH_QUERY\"
    }"

echo "✓ Environment variables updated successfully!"
echo "⏳ Waiting for function update to complete..."

aws lambda wait function-updated \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $AWS_REGION

echo "✓ Lambda function ready!"
#!/bin/bash

# ============================================
# AWS Lambda Deployment Script
# Crypto Sentiment ETL Pipeline
# ============================================

set -e  # Exit on any error

# Configuration - UPDATE THESE VALUES
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="587234333121"  # Get from AWS Console
ECR_REPOSITORY_NAME="crypto-sentiment-etl"
LAMBDA_FUNCTION_NAME="crypto-sentiment-pipeline"
LAMBDA_ROLE_NAME="CryptoSentimentLambdaRole"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Crypto Sentiment Pipeline Deployment${NC}"
echo -e "${BLUE}======================================${NC}"

# Step 1: Check AWS CLI is configured
echo -e "\n${GREEN}[Step 1/8] Checking AWS CLI configuration...${NC}"
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not configured. Run 'aws configure' first.${NC}"
    exit 1
fi
ACTUAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✓ AWS Account ID: $ACTUAL_ACCOUNT_ID"

# Update account ID if it's placeholder
if [ "$AWS_ACCOUNT_ID" = "YOUR_AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$ACTUAL_ACCOUNT_ID
    echo "✓ Using detected account ID: $AWS_ACCOUNT_ID"
fi

# Step 2: Create ECR repository (if not exists)
echo -e "\n${GREEN}[Step 2/8] Creating ECR repository...${NC}"
if ! aws ecr describe-repositories --repository-names $ECR_REPOSITORY_NAME --region $AWS_REGION &> /dev/null; then
    aws ecr create-repository \
        --repository-name $ECR_REPOSITORY_NAME \
        --region $AWS_REGION \
        --image-scanning-configuration scanOnPush=true
    echo "✓ ECR repository created: $ECR_REPOSITORY_NAME"
else
    echo "✓ ECR repository already exists: $ECR_REPOSITORY_NAME"
fi

# Step 3: Login to ECR
echo -e "\n${GREEN}[Step 3/8] Logging into ECR...${NC}"
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin \
    $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
echo "✓ Logged into ECR"

# Step 4: Build Docker image
echo -e "\n${GREEN}[Step 4/8] Building Docker image...${NC}"
docker build --platform linux/amd64 -t $ECR_REPOSITORY_NAME:latest .
echo "✓ Docker image built successfully"

# Step 5: Tag Docker image
echo -e "\n${GREEN}[Step 5/8] Tagging Docker image...${NC}"
IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest"
docker tag $ECR_REPOSITORY_NAME:latest $IMAGE_URI
echo "✓ Image tagged: $IMAGE_URI"

# Step 6: Push to ECR
echo -e "\n${GREEN}[Step 6/8] Pushing image to ECR...${NC}"
docker push $IMAGE_URI
echo "✓ Image pushed to ECR"

# Step 7: Create/Update Lambda IAM Role
echo -e "\n${GREEN}[Step 7/8] Setting up Lambda IAM role...${NC}"
if ! aws iam get-role --role-name $LAMBDA_ROLE_NAME &> /dev/null; then
    # Create trust policy
    cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # Create role
    aws iam create-role \
        --role-name $LAMBDA_ROLE_NAME \
        --assume-role-policy-document file:///tmp/trust-policy.json
    
    # Attach basic Lambda execution policy
    aws iam attach-role-policy \
        --role-name $LAMBDA_ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    echo "✓ IAM role created: $LAMBDA_ROLE_NAME"
    echo "⏳ Waiting 10 seconds for role to propagate..."
    sleep 10
else
    echo "✓ IAM role already exists: $LAMBDA_ROLE_NAME"
fi

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)

# Step 8: Create/Update Lambda function
echo -e "\n${GREEN}[Step 8/8] Creating/Updating Lambda function...${NC}"
if ! aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION &> /dev/null; then
    # Create new Lambda function
    aws lambda create-function \
        --function-name $LAMBDA_FUNCTION_NAME \
        --package-type Image \
        --code ImageUri=$IMAGE_URI \
        --role $LAMBDA_ROLE_ARN \
        --timeout 900 \
        --memory-size 512 \
        --region $AWS_REGION \
        --environment Variables="{
            DB_HOST=$DB_HOST,
            DB_PORT=$DB_PORT,
            DB_NAME=$DB_NAME,
            DB_USER=$DB_USER,
            DB_PASSWORD=$DB_PASSWORD,
            NEWSAPI_KEY=$NEWSAPI_KEY,
            CRYPTO_SYMBOLS=bitcoin,ethereum
        }"
    echo "✓ Lambda function created: $LAMBDA_FUNCTION_NAME"
else
    # Update existing Lambda function
    aws lambda update-function-code \
        --function-name $LAMBDA_FUNCTION_NAME \
        --image-uri $IMAGE_URI \
        --region $AWS_REGION
    
    echo "⏳ Waiting for function update to complete..."
    aws lambda wait function-updated --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION
    
    echo "✓ Lambda function updated: $LAMBDA_FUNCTION_NAME"
fi

echo -e "\n${BLUE}======================================${NC}"
echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
echo -e "${BLUE}======================================${NC}"
echo -e "\nNext steps:"
echo -e "1. Set environment variables in Lambda console (or use deploy_update_env.sh)"
echo -e "2. Create EventBridge rule for 30-minute scheduling"
echo -e "3. Test the function manually in Lambda console"
echo -e "\nLambda Function ARN:"
aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION --query 'Configuration.FunctionArn' --output text
#!/bin/bash

# ============================================
# AWS Lambda Deployment Script (Consolidated)
# Crypto Sentiment ETL Pipeline
# ============================================

set -e

# Configuration
AWS_REGION="us-east-1"
ECR_REPOSITORY_NAME="crypto-sentiment-etl"
LAMBDA_FUNCTION_NAME="crypto-sentiment-pipeline"
LAMBDA_ROLE_NAME="CryptoSentimentLambdaRole"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Functions
show_help() {
    echo ""
    echo "Crypto Sentiment Pipeline - Deployment Tool"
    echo ""
    echo "Usage: ./deploy.sh [command]"
    echo ""
    echo "Commands:"
    echo "  deploy        - Full deployment (default)"
    echo "  update-code   - Update Lambda code only"
    echo "  update-env    - Update environment variables only"
    echo "  schedule      - Setup EventBridge schedule"
    echo "  clean         - Remove all AWS resources"
    echo "  help          - Show this help"
    echo ""
}

update_env_internal() {
    if [ ! -f .env ]; then
        echo -e "${RED}Error: .env file not found${NC}"
        echo "Create .env from .env.example first"
        exit 1
    fi

    echo "Loading variables from .env..."
    export $(cat .env | grep -v '^#' | xargs)

    cat > lambda-env.json << EOF
{
  "Variables": {
    "DB_HOST": "$DB_HOST",
    "DB_PORT": "$DB_PORT",
    "DB_NAME": "$DB_NAME",
    "DB_USER": "$DB_USER",
    "DB_PASSWORD": "$DB_PASSWORD",
    "NEWSAPI_KEY": "$NEWSAPI_KEY",
    "CRYPTO_SYMBOLS": "$CRYPTO_SYMBOLS",
    "NEWS_SEARCH_QUERY": "$NEWS_SEARCH_QUERY"
  }
}
EOF

    aws lambda update-function-configuration \
        --function-name $LAMBDA_FUNCTION_NAME \
        --region $AWS_REGION \
        --environment file://lambda-env.json > /dev/null

    aws lambda wait function-updated \
        --function-name $LAMBDA_FUNCTION_NAME \
        --region $AWS_REGION

    rm lambda-env.json
    echo "  ✓ Environment updated"
}

deploy() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Crypto Sentiment Pipeline Deployment${NC}"
    echo -e "${BLUE}======================================${NC}"

    echo -e "\n${GREEN}[1/9] Checking AWS CLI...${NC}"
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}Error: AWS CLI not configured${NC}"
        exit 1
    fi
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo "  ✓ AWS Account: $AWS_ACCOUNT_ID"

    echo -e "\n${GREEN}[2/9] Checking Docker...${NC}"
    if ! docker --version &> /dev/null; then
        echo -e "${RED}Error: Docker not running${NC}"
        exit 1
    fi
    echo "  ✓ Docker ready"

    echo -e "\n${GREEN}[3/9] Creating ECR repository...${NC}"
    if ! aws ecr describe-repositories --repository-names $ECR_REPOSITORY_NAME --region $AWS_REGION &> /dev/null; then
        aws ecr create-repository \
            --repository-name $ECR_REPOSITORY_NAME \
            --region $AWS_REGION \
            --image-scanning-configuration scanOnPush=true > /dev/null
        echo "  ✓ Created: $ECR_REPOSITORY_NAME"
    else
        echo "  ✓ Repository exists"
    fi

    echo -e "\n${GREEN}[4/9] Logging into ECR...${NC}"
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin \
        $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com > /dev/null 2>&1
    echo "  ✓ Logged in"

    echo -e "\n${GREEN}[5/9] Building Docker image...${NC}"
    IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest"
    docker build --platform linux/amd64 -t $IMAGE_URI . > /dev/null
    echo "  ✓ Image built"

    echo -e "\n${GREEN}[6/9] Pushing to ECR...${NC}"
    docker push $IMAGE_URI > /dev/null
    echo "  ✓ Image pushed"

    echo -e "\n${GREEN}[7/9] Setting up IAM role...${NC}"
    if ! aws iam get-role --role-name $LAMBDA_ROLE_NAME &> /dev/null; then
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
        aws iam create-role \
            --role-name $LAMBDA_ROLE_NAME \
            --assume-role-policy-document file:///tmp/trust-policy.json > /dev/null
        
        aws iam attach-role-policy \
            --role-name $LAMBDA_ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole > /dev/null
        
        echo "  ✓ Created: $LAMBDA_ROLE_NAME"
        sleep 10
    else
        echo "  ✓ Role exists"
    fi

    LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)

    echo -e "\n${GREEN}[8/9] Creating Lambda function...${NC}"
    if ! aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION &> /dev/null; then
        aws lambda create-function \
            --function-name $LAMBDA_FUNCTION_NAME \
            --package-type Image \
            --code ImageUri=$IMAGE_URI \
            --role $LAMBDA_ROLE_ARN \
            --timeout 900 \
            --memory-size 512 \
            --region $AWS_REGION \
            --architectures x86_64 > /dev/null
        echo "  ✓ Created: $LAMBDA_FUNCTION_NAME"
    else
        aws lambda update-function-code \
            --function-name $LAMBDA_FUNCTION_NAME \
            --image-uri $IMAGE_URI \
            --region $AWS_REGION > /dev/null
        
        aws lambda wait function-updated \
            --function-name $LAMBDA_FUNCTION_NAME \
            --region $AWS_REGION
        echo "  ✓ Updated: $LAMBDA_FUNCTION_NAME"
    fi

    echo -e "\n${GREEN}[9/9] Updating environment variables...${NC}"
    if [ ! -f .env ]; then
        echo "  ⚠ .env file not found"
        echo "  Create .env from .env.example and run: ./deploy.sh update-env"
    else
        update_env_internal
    fi

    echo -e "\n${BLUE}======================================${NC}"
    echo -e "${GREEN}✓ Deployment Complete!${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
    echo "Function: $LAMBDA_FUNCTION_NAME"
    echo "Region: $AWS_REGION"
    echo ""
    echo "Next steps:"
    echo "  1. Setup schedule: ./deploy.sh schedule"
    echo "  2. Test: aws lambda invoke --function-name $LAMBDA_FUNCTION_NAME response.json"
    echo ""
}

update_code() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Updating Lambda Code${NC}"
    echo -e "${BLUE}======================================${NC}"

    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest"

    echo -e "\n${GREEN}[1/3] Building new image...${NC}"
    docker build --platform linux/amd64 -t $IMAGE_URI . > /dev/null
    echo "  ✓ Built"

    echo -e "\n${GREEN}[2/3] Pushing to ECR...${NC}"
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin \
        $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com > /dev/null 2>&1
    docker push $IMAGE_URI > /dev/null
    echo "  ✓ Pushed"

    echo -e "\n${GREEN}[3/3] Updating Lambda...${NC}"
    aws lambda update-function-code \
        --function-name $LAMBDA_FUNCTION_NAME \
        --image-uri $IMAGE_URI \
        --region $AWS_REGION > /dev/null
    
    aws lambda wait function-updated \
        --function-name $LAMBDA_FUNCTION_NAME \
        --region $AWS_REGION
    echo "  ✓ Updated"
}

update_env() {
    update_env_internal
}

setup_schedule() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Setting up EventBridge Schedule${NC}"
    echo -e "${BLUE}======================================${NC}"

    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    LAMBDA_ARN="arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$LAMBDA_FUNCTION_NAME"
    RULE_NAME="crypto-sentiment-schedule"

    echo -e "\n${GREEN}[1/3] Creating EventBridge rule...${NC}"
    aws events put-rule \
        --name $RULE_NAME \
        --schedule-expression "rate(30 minutes)" \
        --region $AWS_REGION > /dev/null
    echo "  ✓ Rule: $RULE_NAME"

    echo -e "\n${GREEN}[2/3] Adding Lambda target...${NC}"
    aws events put-targets \
        --rule $RULE_NAME \
        --targets "Id"="1","Arn"="$LAMBDA_ARN" \
        --region $AWS_REGION > /dev/null
    echo "  ✓ Target added"

    echo -e "\n${GREEN}[3/3] Granting permissions...${NC}"
    aws lambda add-permission \
        --function-name $LAMBDA_FUNCTION_NAME \
        --statement-id EventBridgeInvoke \
        --action lambda:InvokeFunction \
        --principal events.amazonaws.com \
        --source-arn arn:aws:events:$AWS_REGION:$AWS_ACCOUNT_ID:rule/$RULE_NAME \
        --region $AWS_REGION &> /dev/null || true
    echo "  ✓ Permissions granted"

    echo -e "\n${BLUE}======================================${NC}"
    echo -e "${GREEN}✓ Schedule Setup Complete!${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo "Lambda will run every 30 minutes"
}

clean() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Cleaning Up AWS Resources${NC}"
    echo -e "${BLUE}======================================${NC}"

    echo -e "\n${GREEN}[1/4] Deleting Lambda function...${NC}"
    aws lambda delete-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION &> /dev/null || true
    echo "  ✓ Deleted"

    echo -e "\n${GREEN}[2/4] Removing IAM policies...${NC}"
    aws iam detach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole &> /dev/null || true
    aws iam delete-role --role-name $LAMBDA_ROLE_NAME &> /dev/null || true
    echo "  ✓ Deleted"

    echo -e "\n${GREEN}[3/4] Deleting ECR images...${NC}"
    aws ecr batch-delete-image --repository-name $ECR_REPOSITORY_NAME --image-ids imageTag=latest --region $AWS_REGION &> /dev/null || true
    echo "  ✓ Deleted"

    echo -e "\n${GREEN}[4/4] Deleting EventBridge rule...${NC}"
    aws events remove-targets --rule crypto-sentiment-schedule --ids 1 --region $AWS_REGION &> /dev/null || true
    aws events delete-rule --name crypto-sentiment-schedule --region $AWS_REGION &> /dev/null || true
    echo "  ✓ Deleted"

    echo -e "\n${GREEN}✓ Cleanup complete!${NC}"
}

# Main
ACTION=${1:-deploy}

case $ACTION in
    deploy)
        deploy
        ;;
    update-code)
        update_code
        ;;
    update-env)
        update_env
        ;;
    schedule)
        setup_schedule
        ;;
    clean)
        clean
        ;;
    help)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $ACTION${NC}"
        show_help
        exit 1
        ;;
esac
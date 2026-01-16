# 🚀 Crypto Sentiment Analysis Pipeline

Real-time data engineering project that tracks correlation between Bitcoin/Ethereum prices and news sentiment.

## 📊 Architecture

```
CoinGecko API ──┐
                ├──> ETL Pipeline (AWS Lambda) ──> PostgreSQL (Supabase) ──> Streamlit Dashboard
NewsAPI ────────┘                ↑
                                 │
                          EventBridge (30 min)
```

## 🛠️ Tech Stack

- **Data Sources**: CoinGecko API, NewsAPI
- **Language**: Python 3.11
- **Database**: PostgreSQL (Supabase)
- **Compute**: AWS Lambda (Docker Container)
- **Scheduler**: Amazon EventBridge
- **Dashboard**: Streamlit

## 📁 Project Structure

```
crypto-sentiment-pipeline/
├── etl_pipeline.py          # Main ETL logic
├── lambda_function.py       # AWS Lambda entry point
├── requirements.txt         # Python dependencies
├── Dockerfile              # Container configuration
├── .dockerignore           # Docker ignore rules
├── deploy.sh               # Deployment automation
├── deploy_update_env.sh    # Update environment variables
├── .env                    # Local environment variables (gitignored)
└── README.md               # This file
```

## 🚀 Local Development Setup

### 1. Clone and Setup

```bash
# Create project directory
mkdir crypto-sentiment-pipeline
cd crypto-sentiment-pipeline

# Create virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

### 2. Configure Environment Variables

Create `.env` file:

```bash
# Database (Supabase)
DB_HOST=aws-0-us-east-1.pooler.supabase.com
DB_PORT=6543
DB_NAME=postgres
DB_USER=postgres.your_project_ref
DB_PASSWORD=your_password

# API Keys
NEWSAPI_KEY=your_newsapi_key

# Configuration
CRYPTO_SYMBOLS=bitcoin,ethereum
NEWS_SEARCH_QUERY=cryptocurrency OR bitcoin OR ethereum
```

### 3. Test Locally

```bash
python etl_pipeline.py
```

## 🐳 AWS Lambda Deployment

### Prerequisites

1. **AWS Account** with CLI configured
2. **Docker** installed and running
3. **Supabase** database set up
4. **NewsAPI** key obtained

### Step 1: Configure AWS CLI

```bash
aws configure
# Enter your AWS Access Key ID
# Enter your AWS Secret Access Key
# Enter default region (e.g., us-east-1)
# Enter output format (json)
```

### Step 2: Make Deployment Script Executable

```bash
chmod +x deploy.sh
chmod +x deploy_update_env.sh
```

### Step 3: Update Configuration in deploy.sh

Open `deploy.sh` and update:

```bash
AWS_REGION="us-east-1"  # Your preferred region
AWS_ACCOUNT_ID="YOUR_AWS_ACCOUNT_ID"  # From AWS Console
```

### Step 4: Deploy to AWS

```bash
./deploy.sh
```

This script will:
1. ✓ Verify AWS credentials
2. ✓ Create ECR repository
3. ✓ Build Docker image
4. ✓ Push to ECR
5. ✓ Create IAM role
6. ✓ Create/Update Lambda function

### Step 5: Update Environment Variables (After Deployment)

```bash
./deploy_update_env.sh
```

## ⏰ EventBridge Scheduling Setup

### Create EventBridge Rule (30-minute intervals)

#### Option 1: AWS Console

1. Go to **Amazon EventBridge** → **Rules**
2. Click **Create rule**
3. Configure:
   - Name: `crypto-sentiment-schedule`
   - Event bus: `default`
   - Rule type: `Schedule`
4. Schedule pattern:
   - Rate expression: `rate(30 minutes)`
5. Select target:
   - Target type: `AWS service`
   - Target: `Lambda function`
   - Function: `crypto-sentiment-pipeline`
6. Click **Create**

#### Option 2: AWS CLI

```bash
# Create EventBridge rule
aws events put-rule \
    --name crypto-sentiment-schedule \
    --schedule-expression "rate(30 minutes)" \
    --region us-east-1

# Get Lambda function ARN
LAMBDA_ARN=$(aws lambda get-function \
    --function-name crypto-sentiment-pipeline \
    --query 'Configuration.FunctionArn' \
    --output text \
    --region us-east-1)

# Add Lambda as target
aws events put-targets \
    --rule crypto-sentiment-schedule \
    --targets "Id"="1","Arn"="$LAMBDA_ARN" \
    --region us-east-1

# Grant EventBridge permission to invoke Lambda
aws lambda add-permission \
    --function-name crypto-sentiment-pipeline \
    --statement-id EventBridgeInvoke \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn arn:aws:events:us-east-1:YOUR_ACCOUNT_ID:rule/crypto-sentiment-schedule \
    --region us-east-1
```

## 🧪 Testing

### Test Lambda Function Manually

```bash
# Invoke function
aws lambda invoke \
    --function-name crypto-sentiment-pipeline \
    --region us-east-1 \
    response.json

# View response
cat response.json
```

### Check CloudWatch Logs

```bash
# View latest logs
aws logs tail /aws/lambda/crypto-sentiment-pipeline --follow --region us-east-1
```

### Verify Database

```sql
-- In Supabase SQL Editor
SELECT COUNT(*) FROM crypto_prices;
SELECT COUNT(*) FROM crypto_sentiment;
SELECT * FROM aggregated_metrics ORDER BY time_bucket DESC LIMIT 10;
```

## 📊 Monitoring

### CloudWatch Metrics

Monitor in AWS Console:
- **Invocations**: Number of times Lambda runs
- **Duration**: Execution time
- **Errors**: Failed executions
- **Throttles**: Rate limiting

### Set Up Alarms

```bash
# Create CloudWatch alarm for errors
aws cloudwatch put-metric-alarm \
    --alarm-name crypto-pipeline-errors \
    --alarm-description "Alert on Lambda errors" \
    --metric-name Errors \
    --namespace AWS/Lambda \
    --statistic Sum \
    --period 300 \
    --threshold 1 \
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=FunctionName,Value=crypto-sentiment-pipeline \
    --evaluation-periods 1 \
    --region us-east-1
```

## 💰 Cost Estimation

### Free Tier (First 12 months)
- **Lambda**: 1M requests/month free
- **EventBridge**: 2M events/month free
- **CloudWatch Logs**: 5GB ingestion free

### Monthly Cost (After Free Tier)
- **Lambda**: ~$0.20 (48 runs/day × 30 days × ~10 sec)
- **Supabase**: $0 (Free tier: 500MB database)
- **NewsAPI**: $0 (Free tier: 100 requests/day)
- **Total**: ~$0.20/month ✅

## 🔧 Troubleshooting

### Lambda Timeout
```bash
# Increase timeout to 15 minutes
aws lambda update-function-configuration \
    --function-name crypto-sentiment-pipeline \
    --timeout 900 \
    --region us-east-1
```

### Memory Issues
```bash
# Increase memory to 1024 MB
aws lambda update-function-configuration \
    --function-name crypto-sentiment-pipeline \
    --memory-size 1024 \
    --region us-east-1
```

### Connection Issues
- Verify Supabase credentials in Lambda environment variables
- Check security groups allow outbound connections
- Test database connection locally first

## 🎯 Next Steps

1. ✅ Deploy Lambda function
2. ✅ Set up EventBridge scheduling
3. ⏳ Build Streamlit dashboard (Phase 4)
4. ⏳ Deploy dashboard to Streamlit Cloud

## 📚 Resources

- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
- [Supabase Docs](https://supabase.com/docs)
- [NewsAPI Documentation](https://newsapi.org/docs)
- [CoinGecko API](https://www.coingecko.com/en/api)

## 📝 License

MIT License - Feel free to use this for learning and portfolio projects!
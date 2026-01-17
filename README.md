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
- **Dashboard**: Streamlit (Phase 4)

## 📁 Project Structure

```
crypto-sentiment-pipeline/
├── README.md                    # This file
├── .env.example                 # Environment variables template
├── .dockerignore               # Docker ignore rules
├── Dockerfile                  # Container configuration
├── requirements.txt            # Python dependencies
├── etl_pipeline.py            # Main ETL logic
├── lambda_function.py         # AWS Lambda entry point
├── test_db.py                 # Database connection test
├── deploy.bat                 # Windows deployment script
└── deploy.sh                  # Linux/Mac deployment script
```

## 🚀 Quick Start

### Prerequisites

1. **AWS Account** with CLI configured
2. **Docker** installed and running
3. **Supabase** database set up
4. **NewsAPI** key obtained

### 1. Clone and Setup

```bash
# Clone repository
git clone <your-repo-url>
cd crypto-sentiment-pipeline

# Create virtual environment (optional, for local testing)
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies (optional, for local testing)
pip install -r requirements.txt
```

### 2. Configure Environment

```bash
# Copy template and edit
cp .env.example .env

# Edit .env with your credentials
# Required values:
# - DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD (from Supabase)
# - NEWSAPI_KEY (from newsapi.org)
```

### 3. Setup Database Schema

Run this SQL in your Supabase SQL Editor:

```sql
-- Create crypto_prices table
CREATE TABLE IF NOT EXISTS crypto_prices (
    id SERIAL PRIMARY KEY,
    symbol VARCHAR(10) NOT NULL,
    price DECIMAL(20, 8) NOT NULL,
    volume_24h DECIMAL(30, 2),
    market_cap DECIMAL(30, 2),
    price_change_24h DECIMAL(10, 4),
    last_updated TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create crypto_sentiment table
CREATE TABLE IF NOT EXISTS crypto_sentiment (
    id SERIAL PRIMARY KEY,
    headline TEXT NOT NULL,
    description TEXT,
    source VARCHAR(100),
    author VARCHAR(200),
    published_at TIMESTAMPTZ NOT NULL,
    url TEXT,
    sentiment_score DECIMAL(5, 4),
    sentiment_positive DECIMAL(5, 4),
    sentiment_negative DECIMAL(5, 4),
    sentiment_neutral DECIMAL(5, 4),
    mentions_bitcoin BOOLEAN DEFAULT FALSE,
    mentions_ethereum BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(headline, published_at)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_crypto_prices_symbol ON crypto_prices(symbol);
CREATE INDEX IF NOT EXISTS idx_crypto_prices_last_updated ON crypto_prices(last_updated);
CREATE INDEX IF NOT EXISTS idx_crypto_sentiment_published_at ON crypto_sentiment(published_at);
CREATE INDEX IF NOT EXISTS idx_crypto_sentiment_sentiment_score ON crypto_sentiment(sentiment_score);

-- Create aggregated metrics view
CREATE MATERIALIZED VIEW IF NOT EXISTS aggregated_metrics AS
SELECT 
    DATE_TRUNC('hour', cp.last_updated) as time_bucket,
    cp.symbol,
    AVG(cp.price) as avg_price,
    AVG(cs.sentiment_score) as avg_sentiment,
    COUNT(DISTINCT cs.id) as news_count
FROM crypto_prices cp
LEFT JOIN crypto_sentiment cs 
    ON DATE_TRUNC('hour', cs.published_at) = DATE_TRUNC('hour', cp.last_updated)
GROUP BY DATE_TRUNC('hour', cp.last_updated), cp.symbol
ORDER BY time_bucket DESC;

-- Create index on materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_aggregated_metrics_unique 
ON aggregated_metrics (time_bucket, symbol);
```

### 4. Test Database Connection (Optional)

```bash
# Test before deploying
python test_db.py
```

### 5. Configure AWS CLI

```bash
aws configure
# Enter your AWS Access Key ID
# Enter your AWS Secret Access Key
# Enter default region (e.g., us-east-1)
# Enter output format (json)
```

### 6. Deploy to AWS

#### Windows:
```batch
# Full deployment
deploy.bat

# Or use specific commands
deploy.bat deploy        # Full deployment
deploy.bat update-code   # Update code only
deploy.bat update-env    # Update environment variables
deploy.bat schedule      # Setup EventBridge schedule
deploy.bat clean         # Remove all resources
deploy.bat help          # Show help
```

#### Linux/Mac:
```bash
# Make script executable
chmod +x deploy.sh

# Full deployment
./deploy.sh

# Or use specific commands
./deploy.sh deploy        # Full deployment
./deploy.sh update-code   # Update code only
./deploy.sh update-env    # Update environment variables
./deploy.sh schedule      # Setup EventBridge schedule
./deploy.sh clean         # Remove all resources
./deploy.sh help          # Show help
```

### 7. Setup Automatic Scheduling

```bash
# Windows
deploy.bat schedule

# Linux/Mac
./deploy.sh schedule
```

This creates an EventBridge rule that runs the pipeline every 30 minutes.

## 🧪 Testing

### Test Lambda Function Manually

```bash
# Invoke function
aws lambda invoke \
    --function-name crypto-sentiment-pipeline \
    --region us-east-1 \
    response.json

# View response
cat response.json  # Linux/Mac
type response.json # Windows
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

Monitor in AWS Console → CloudWatch:
- **Invocations**: Number of times Lambda runs
- **Duration**: Execution time
- **Errors**: Failed executions
- **Throttles**: Rate limiting

### Set Up Alarms (Optional)

```bash
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
- **Lambda**: ~$0.20 (48 runs/day × 30 days)
- **Supabase**: $0 (Free tier: 500MB database)
- **NewsAPI**: $0 (Free tier: 100 requests/day)
- **Total**: ~$0.20/month ✅

## 🔧 Troubleshooting

### Lambda Timeout
```bash
aws lambda update-function-configuration \
    --function-name crypto-sentiment-pipeline \
    --timeout 900 \
    --region us-east-1
```

### Memory Issues
```bash
aws lambda update-function-configuration \
    --function-name crypto-sentiment-pipeline \
    --memory-size 1024 \
    --region us-east-1
```

### Connection Issues
- Verify Supabase credentials in `.env`
- Check security groups allow outbound connections
- Test database connection with `test_db.py`

### Deployment Issues
- Ensure Docker is running
- Check AWS credentials: `aws sts get-caller-identity`
- Verify IAM permissions for Lambda, ECR, EventBridge

## 🔄 Updating the Pipeline

### Update Code
```bash
# After modifying etl_pipeline.py or lambda_function.py
deploy.bat update-code  # Windows
./deploy.sh update-code # Linux/Mac
```

### Update Environment Variables
```bash
# After modifying .env
deploy.bat update-env  # Windows
./deploy.sh update-env # Linux/Mac
```

### Update Dependencies
```bash
# After modifying requirements.txt
deploy.bat deploy      # Full redeployment needed
./deploy.sh deploy
```

## 🗑️ Cleanup

Remove all AWS resources:

```bash
# Windows
deploy.bat clean

# Linux/Mac
./deploy.sh clean
```

This will delete:
- Lambda function
- ECR repository images
- IAM role
- EventBridge rule

## 🎯 Next Steps

1. ✅ Deploy Lambda function
2. ✅ Set up EventBridge scheduling
3. ⏳ Build Streamlit dashboard (Phase 4)
4. ⏳ Deploy dashboard to Streamlit Cloud

## 📚 Resources

- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
- [Supabase Documentation](https://supabase.com/docs)
- [NewsAPI Documentation](https://newsapi.org/docs)
- [CoinGecko API](https://www.coingecko.com/en/api)
- [Docker Documentation](https://docs.docker.com/)

## 📝 License

MIT License - Feel free to use this for learning and portfolio projects!

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
"""
Crypto Price & Sentiment ETL Pipeline
Fetches Bitcoin/Ethereum prices and news sentiment every 30 minutes
"""

import os
import sys
import logging
from datetime import datetime, timezone, timedelta
from typing import List, Dict, Optional
import requests
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Configure logging (Lambda-compatible)
# Use /tmp directory for logs in Lambda (only writable location)
log_dir = '/tmp' if os.environ.get('AWS_EXECUTION_ENV') else os.path.join(os.getcwd(), 'logs')
if not os.environ.get('AWS_EXECUTION_ENV'):
    os.makedirs(log_dir, exist_ok=True)

# Force UTF-8 encoding for Windows console
if sys.platform == 'win32' and not os.environ.get('AWS_EXECUTION_ENV'):
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(os.path.join(log_dir, 'etl_pipeline.log'), encoding='utf-8') if not os.environ.get('AWS_EXECUTION_ENV') else logging.NullHandler()
    ]
)
logger = logging.getLogger(__name__)

# Configuration from environment
NEWSAPI_KEY = os.getenv("NEWSAPI_KEY")
CRYPTO_SYMBOLS = os.getenv("CRYPTO_SYMBOLS", "bitcoin,ethereum").split(',')
NEWS_QUERY = os.getenv("NEWS_SEARCH_QUERY", "cryptocurrency OR bitcoin OR ethereum")

# API Endpoints
COINGECKO_API = "https://api.coingecko.com/api/v3"
NEWSAPI_ENDPOINT = "https://newsapi.org/v2/everything"

# Database configuration
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")


class CryptoETLPipeline:
    """Main ETL Pipeline orchestrator"""
    
    def __init__(self):
        """Initialize database connection and sentiment analyzer"""
        # Build connection string from individual components
        if not all([DB_HOST, DB_USER, DB_PASSWORD, DB_NAME]):
            raise ValueError(
                "Missing database credentials. Please check your environment variables!\n"
                "Required: DB_HOST, DB_USER, DB_PASSWORD, DB_NAME"
            )
        
        # Build connection string (avoiding URL encoding issues)
        from urllib.parse import quote_plus
        db_url = (
            f"postgresql://{DB_USER}:{quote_plus(DB_PASSWORD)}"
            f"@{DB_HOST}:{DB_PORT}/{DB_NAME}"
        )
        
        logger.info(f"Connecting to database: {DB_HOST}:{DB_PORT}/{DB_NAME}")
        logger.info(f"User: {DB_USER}")
        
        try:
            self.engine = create_engine(
                db_url,
                pool_pre_ping=True,
                pool_size=5,
                max_overflow=10,
                pool_recycle=3600
            )
            
            # Test the connection
            with self.engine.connect() as conn:
                result = conn.execute(text("SELECT 1"))
                logger.info("[OK] Database connection successful!")
                
        except Exception as e:
            logger.error(f"[ERROR] Failed to connect to database: {e}")
            raise
        
        self.sentiment_analyzer = SentimentIntensityAnalyzer()
        logger.info("[OK] ETL Pipeline initialized successfully")
    
    def fetch_crypto_prices(self) -> Optional[pd.DataFrame]:
        """
        Fetch current prices for BTC and ETH from CoinGecko API
        
        Returns:
            DataFrame with columns: symbol, price, volume_24h, market_cap, 
            price_change_24h, last_updated
        """
        try:
            logger.info(f"Fetching crypto prices for: {', '.join(CRYPTO_SYMBOLS)}")
            
            # CoinGecko API endpoint (free tier, no API key needed)
            url = f"{COINGECKO_API}/simple/price"
            params = {
                'ids': ','.join(CRYPTO_SYMBOLS),
                'vs_currencies': 'usd',
                'include_market_cap': 'true',
                'include_24hr_vol': 'true',
                'include_24hr_change': 'true',
                'include_last_updated_at': 'true'
            }
            
            response = requests.get(url, params=params, timeout=15)
            response.raise_for_status()
            data = response.json()
            
            # Transform to DataFrame
            records = []
            for symbol in CRYPTO_SYMBOLS:
                symbol = symbol.strip()
                if symbol in data:
                    coin_data = data[symbol]
                    records.append({
                        'symbol': symbol.upper() if len(symbol) <= 3 else symbol.title(),
                        'price': coin_data.get('usd'),
                        'volume_24h': coin_data.get('usd_24h_vol'),
                        'market_cap': coin_data.get('usd_market_cap'),
                        'price_change_24h': coin_data.get('usd_24h_change'),
                        'last_updated': datetime.fromtimestamp(
                            coin_data.get('last_updated_at'),
                            tz=timezone.utc
                        ) if coin_data.get('last_updated_at') else datetime.now(timezone.utc)
                    })
                else:
                    logger.warning(f"No data returned for symbol: {symbol}")
            
            if not records:
                logger.error("[ERROR] No crypto price data retrieved!")
                return None
                
            df = pd.DataFrame(records)
            logger.info(f"[OK] Successfully fetched {len(df)} crypto prices")
            
            # Log the prices
            for _, row in df.iterrows():
                logger.info(f"  {row['symbol']}: ${row['price']:,.2f} ({row['price_change_24h']:+.2f}%)")
            
            return df
            
        except requests.exceptions.RequestException as e:
            logger.error(f"[ERROR] Error fetching crypto prices: {e}")
            return None
        except Exception as e:
            logger.error(f"[ERROR] Unexpected error in fetch_crypto_prices: {e}")
            return None
    
    def fetch_news_headlines(self) -> Optional[pd.DataFrame]:
        """
        Fetch recent crypto news from NewsAPI
        
        Returns:
            DataFrame with columns: headline, description, source, author, 
            published_at, url
        """
        try:
            if not NEWSAPI_KEY:
                logger.warning("[WARNING] NEWSAPI_KEY not set, skipping news fetch")
                return None
            
            logger.info("Fetching crypto news headlines...")
            
            # Get news from last 24 hours
            from_date = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
            
            # NewsAPI parameters
            params = {
                'q': NEWS_QUERY,
                'apiKey': NEWSAPI_KEY,
                'language': 'en',
                'sortBy': 'publishedAt',
                'from': from_date,
                'pageSize': 50
            }
            
            response = requests.get(NEWSAPI_ENDPOINT, params=params, timeout=15)
            response.raise_for_status()
            data = response.json()
            
            if data.get('status') != 'ok':
                logger.error(f"[ERROR] NewsAPI error: {data.get('message')}")
                return None
            
            articles = data.get('articles', [])
            
            if not articles:
                logger.warning("[WARNING] No news articles found")
                return None
            
            # Transform to DataFrame
            records = []
            for article in articles:
                # Skip articles with removed content
                if article.get('title') == '[Removed]' or not article.get('title'):
                    continue
                    
                records.append({
                    'headline': article.get('title', '').strip(),
                    'description': article.get('description', '').strip() if article.get('description') else '',
                    'source': article.get('source', {}).get('name', 'Unknown'),
                    'author': article.get('author', ''),
                    'published_at': pd.to_datetime(article.get('publishedAt'), utc=True),
                    'url': article.get('url', '')
                })
            
            if not records:
                logger.warning("[WARNING] No valid news articles after filtering")
                return None
                
            df = pd.DataFrame(records)
            logger.info(f"[OK] Successfully fetched {len(df)} news articles")
            return df
            
        except requests.exceptions.RequestException as e:
            logger.error(f"[ERROR] Error fetching news headlines: {e}")
            return None
        except Exception as e:
            logger.error(f"[ERROR] Unexpected error in fetch_news_headlines: {e}")
            return None
    
    def analyze_sentiment(self, df: pd.DataFrame) -> pd.DataFrame:
        """
        Apply VADER sentiment analysis to headlines
        
        Args:
            df: DataFrame with 'headline' column
            
        Returns:
            DataFrame with added sentiment columns
        """
        try:
            logger.info("Analyzing sentiment for headlines...")
            
            # Apply VADER to each headline
            sentiment_scores = df['headline'].apply(
                lambda x: self.sentiment_analyzer.polarity_scores(str(x))
            )
            
            # Extract individual scores
            df['sentiment_score'] = sentiment_scores.apply(lambda x: x['compound'])
            df['sentiment_positive'] = sentiment_scores.apply(lambda x: x['pos'])
            df['sentiment_negative'] = sentiment_scores.apply(lambda x: x['neg'])
            df['sentiment_neutral'] = sentiment_scores.apply(lambda x: x['neu'])
            
            # Detect crypto mentions in headlines
            df['mentions_bitcoin'] = df['headline'].str.contains(
                r'bitcoin|btc', case=False, na=False
            )
            df['mentions_ethereum'] = df['headline'].str.contains(
                r'ethereum|eth', case=False, na=False
            )
            
            avg_score = df['sentiment_score'].mean()
            logger.info(f"[OK] Sentiment analysis complete. Average score: {avg_score:.3f}")
            
            # Log sentiment distribution
            positive = (df['sentiment_score'] > 0.05).sum()
            negative = (df['sentiment_score'] < -0.05).sum()
            neutral = len(df) - positive - negative
            logger.info(f"  Positive: {positive}, Negative: {negative}, Neutral: {neutral}")
            
            return df
            
        except Exception as e:
            logger.error(f"[ERROR] Error in sentiment analysis: {e}")
            return df
    
    def load_to_database(self, prices_df: Optional[pd.DataFrame], 
                        sentiment_df: Optional[pd.DataFrame]) -> bool:
        """
        Load data into PostgreSQL database
        
        Args:
            prices_df: Crypto prices DataFrame
            sentiment_df: News sentiment DataFrame
            
        Returns:
            True if successful, False otherwise
        """
        try:
            rows_inserted = 0
            
            with self.engine.begin() as conn:
                # Load crypto prices
                if prices_df is not None and not prices_df.empty:
                    prices_df.to_sql(
                        'crypto_prices',
                        conn,
                        if_exists='append',
                        index=False,
                        method='multi'
                    )
                    rows_inserted += len(prices_df)
                    logger.info(f"[OK] Loaded {len(prices_df)} price records to database")
                
                # Load sentiment data
                if sentiment_df is not None and not sentiment_df.empty:
                    # Insert with conflict handling
                    inserted = 0
                    for _, row in sentiment_df.iterrows():
                        result = conn.execute(text("""
                            INSERT INTO crypto_sentiment 
                            (headline, description, source, author, published_at, url,
                             sentiment_score, sentiment_positive, sentiment_negative, 
                             sentiment_neutral, mentions_bitcoin, mentions_ethereum)
                            VALUES 
                            (:headline, :description, :source, :author, :published_at, :url,
                             :sentiment_score, :sentiment_positive, :sentiment_negative,
                             :sentiment_neutral, :mentions_bitcoin, :mentions_ethereum)
                            ON CONFLICT (headline, published_at) DO NOTHING
                        """), row.to_dict())
                        if result.rowcount > 0:
                            inserted += 1
                    
                    rows_inserted += inserted
                    logger.info(f"[OK] Loaded {inserted} new sentiment records to database")
                    if inserted < len(sentiment_df):
                        logger.info(f"  ({len(sentiment_df) - inserted} duplicates skipped)")
                
                # Refresh materialized view if it exists
                try:
                    logger.info("Refreshing aggregated_metrics view...")
                    conn.execute(text("REFRESH MATERIALIZED VIEW CONCURRENTLY aggregated_metrics"))
                    logger.info("[OK] Aggregated metrics updated")
                except Exception as e:
                    logger.warning(f"[WARNING] Could not refresh materialized view (may not exist yet): {e}")
            
            logger.info(f"[OK] Total rows inserted: {rows_inserted}")
            return True
            
        except SQLAlchemyError as e:
            logger.error(f"[ERROR] Database error: {e}")
            return False
        except Exception as e:
            logger.error(f"[ERROR] Unexpected error in load_to_database: {e}")
            return False
    
    def run(self) -> bool:
        """
        Execute the complete ETL pipeline
        
        Returns:
            True if successful, False otherwise
        """
        logger.info("=" * 70)
        logger.info("STARTING ETL Pipeline Execution")
        logger.info(f"Timestamp: {datetime.now(timezone.utc).isoformat()}")
        logger.info("=" * 70)
        
        try:
            # Step 1: Extract - Fetch crypto prices
            logger.info("\n[1/4] Extracting crypto prices...")
            prices_df = self.fetch_crypto_prices()
            
            # Step 2: Extract - Fetch news headlines
            logger.info("\n[2/4] Extracting news headlines...")
            news_df = self.fetch_news_headlines()
            
            # Step 3: Transform - Analyze sentiment
            logger.info("\n[3/4] Transforming data (sentiment analysis)...")
            sentiment_df = None
            if news_df is not None and not news_df.empty:
                sentiment_df = self.analyze_sentiment(news_df)
            else:
                logger.warning("[WARNING] No news data to analyze")
            
            # Step 4: Load - Insert into database
            logger.info("\n[4/4] Loading data to database...")
            success = self.load_to_database(prices_df, sentiment_df)
            
            logger.info("\n" + "=" * 70)
            if success:
                logger.info("[SUCCESS] ETL Pipeline completed successfully!")
            else:
                logger.warning("[WARNING] ETL Pipeline completed with errors")
            logger.info("=" * 70)
            
            return success
            
        except Exception as e:
            logger.error(f"\n[ERROR] Critical error in ETL pipeline: {e}", exc_info=True)
            logger.info("=" * 70)
            return False


def lambda_handler(event=None, context=None):
    """
    AWS Lambda entry point
    This function will be called by Lambda when deployed
    """
    try:
        pipeline = CryptoETLPipeline()
        success = pipeline.run()
        
        return {
            'statusCode': 200 if success else 500,
            'body': {
                'message': 'ETL pipeline executed successfully' if success else 'ETL pipeline failed',
                'timestamp': datetime.now(timezone.utc).isoformat()
            }
        }
    except Exception as e:
        logger.error(f"Lambda handler error: {e}", exc_info=True)
        return {
            'statusCode': 500,
            'body': {'error': str(e)}
        }


if __name__ == "__main__":
    """Run pipeline locally for testing"""
    try:
        pipeline = CryptoETLPipeline()
        success = pipeline.run()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        logger.info("\n[WARNING] Pipeline interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"\n[ERROR] Fatal error: {e}", exc_info=True)
        sys.exit(1)
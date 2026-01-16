"""
Crypto Price & Sentiment ETL Pipeline
Fetches Bitcoin/Ethereum prices and news sentiment every 30 minutes
"""

import os
import sys
import logging
from datetime import datetime, timezone
from typing import List, Dict, Optional
import requests
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/tmp/etl_pipeline.log')  # Lambda writable directory
    ]
)
logger = logging.getLogger(__name__)

# Configuration from environment
DATABASE_URL = os.getenv("DATABASE_URL")
NEWSAPI_KEY = os.getenv("NEWSAPI_KEY")
CRYPTO_SYMBOLS = os.getenv("CRYPTO_SYMBOLS", "bitcoin,ethereum").split(',')
NEWS_QUERY = os.getenv("NEWS_QUERY", "cryptocurrency OR bitcoin OR ethereum")

# API Endpoints
COINGECKO_API = "https://api.coingecko.com/api/v3"
NEWSAPI_ENDPOINT = "https://newsapi.org/v2/everything"

DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")


class CryptoETLPipeline:
    """Main ETL Pipeline orchestrator"""
    
    def __init__(self):
        """Initialize database connection and sentiment analyzer"""
        # Build connection string from individual components or use full URL
        if DATABASE_URL:
            # Clean the DATABASE_URL by removing unsupported parameters
            clean_db_url = DATABASE_URL.split('?')[0]
            logger.info("Using DATABASE_URL from environment")
        elif all([DB_HOST, DB_USER, DB_PASSWORD]):
            # Build from individual components (avoids URL encoding issues)
            from urllib.parse import quote_plus
            clean_db_url = (
                f"postgresql://{DB_USER}:{quote_plus(DB_PASSWORD)}"
                f"@{DB_HOST}:{DB_PORT}/{DB_NAME}"
            )
            logger.info(f"Building connection string from individual components")
            logger.info(f"Connecting to: {DB_HOST}:{DB_PORT}/{DB_NAME} as user: {DB_USER}")
        else:
            raise ValueError(
                "Either DATABASE_URL or (DB_HOST, DB_USER, DB_PASSWORD) must be set. "
                "Check your .env file!"
            )
        
        try:
            self.engine = create_engine(clean_db_url, pool_pre_ping=True)
            # Test the connection
            with self.engine.connect() as conn:
                result = conn.execute(text("SELECT 1"))
                logger.info("Database connection test successful!")
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            logger.error("Please verify your credentials in .env file:")
            logger.error(f"  DB_HOST: {DB_HOST}")
            logger.error(f"  DB_PORT: {DB_PORT}")
            logger.error(f"  DB_NAME: {DB_NAME}")
            logger.error(f"  DB_USER: {DB_USER}")
            logger.error(f"  DB_PASSWORD: {'*' * len(DB_PASSWORD) if DB_PASSWORD else 'NOT SET'}")
            raise
        
        self.sentiment_analyzer = SentimentIntensityAnalyzer()
        logger.info("ETL Pipeline initialized successfully")
    
    def fetch_crypto_prices(self) -> Optional[pd.DataFrame]:
        """
        Fetch current prices for BTC and ETH from CoinGecko API
        
        Returns:
            DataFrame with columns: symbol, price, volume_24h, market_cap, 
            price_change_24h, price_change_percentage_24h, last_updated
        """
        try:
            logger.info(f"Fetching crypto prices for: {CRYPTO_SYMBOLS}")
            
            # CoinGecko API endpoint
            url = f"{COINGECKO_API}/simple/price"
            params = {
                'ids': ','.join(CRYPTO_SYMBOLS),
                'vs_currencies': 'usd',
                'include_market_cap': 'true',
                'include_24hr_vol': 'true',
                'include_24hr_change': 'true',
                'include_last_updated_at': 'true'
            }
            
            response = requests.get(url, params=params, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            # Transform to DataFrame
            records = []
            for symbol in CRYPTO_SYMBOLS:
                if symbol in data:
                    coin_data = data[symbol]
                    records.append({
                        'symbol': symbol.upper() if len(symbol) <= 3 else symbol,
                        'price': coin_data.get('usd'),
                        'volume_24h': coin_data.get('usd_24h_vol'),
                        'market_cap': coin_data.get('usd_market_cap'),
                        'price_change_24h': coin_data.get('usd_24h_change'),
                        'price_change_percentage_24h': coin_data.get('usd_24h_change'),
                        'last_updated': datetime.fromtimestamp(
                            coin_data.get('last_updated_at'),
                            tz=timezone.utc
                        ) if coin_data.get('last_updated_at') else datetime.now(timezone.utc)
                    })
            
            df = pd.DataFrame(records)
            logger.info(f"Successfully fetched {len(df)} crypto prices")
            return df
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching crypto prices: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error in fetch_crypto_prices: {e}")
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
                logger.warning("NEWSAPI_KEY not set, skipping news fetch")
                return None
            
            logger.info("Fetching crypto news headlines")
            
            # NewsAPI parameters
            params = {
                'q': NEWS_QUERY,
                'apiKey': NEWSAPI_KEY,
                'language': 'en',
                'sortBy': 'publishedAt',
                'pageSize': 50  # Get up to 50 recent articles
            }
            
            response = requests.get(NEWSAPI_ENDPOINT, params=params, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            if data.get('status') != 'ok':
                logger.error(f"NewsAPI error: {data.get('message')}")
                return None
            
            articles = data.get('articles', [])
            
            # Transform to DataFrame
            records = []
            for article in articles:
                # Skip articles with removed content
                if article.get('title') == '[Removed]':
                    continue
                    
                records.append({
                    'headline': article.get('title', ''),
                    'description': article.get('description', ''),
                    'source': article.get('source', {}).get('name', 'Unknown'),
                    'author': article.get('author'),
                    'published_at': pd.to_datetime(article.get('publishedAt')),
                    'url': article.get('url', '')
                })
            
            df = pd.DataFrame(records)
            logger.info(f"Successfully fetched {len(df)} news articles")
            return df
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching news headlines: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error in fetch_news_headlines: {e}")
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
            logger.info("Analyzing sentiment for headlines")
            
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
            
            logger.info(f"Sentiment analysis complete. Avg score: {df['sentiment_score'].mean():.3f}")
            return df
            
        except Exception as e:
            logger.error(f"Error in sentiment analysis: {e}")
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
                    logger.info(f"Loaded {len(prices_df)} price records to database")
                
                # Load sentiment data
                if sentiment_df is not None and not sentiment_df.empty:
                    # Use ON CONFLICT to handle duplicates
                    for _, row in sentiment_df.iterrows():
                        conn.execute(text("""
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
                    
                    logger.info(f"Loaded {len(sentiment_df)} sentiment records to database")
                
                # Refresh materialized view
                logger.info("Refreshing aggregated_metrics view")
                conn.execute(text("REFRESH MATERIALIZED VIEW CONCURRENTLY aggregated_metrics"))
                
            return True
            
        except SQLAlchemyError as e:
            logger.error(f"Database error: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error in load_to_database: {e}")
            return False
    
    def run(self) -> bool:
        """
        Execute the complete ETL pipeline
        
        Returns:
            True if successful, False otherwise
        """
        logger.info("=" * 60)
        logger.info("Starting ETL Pipeline Execution")
        logger.info("=" * 60)
        
        try:
            # Step 1: Extract - Fetch crypto prices
            prices_df = self.fetch_crypto_prices()
            
            # Step 2: Extract - Fetch news headlines
            news_df = self.fetch_news_headlines()
            
            # Step 3: Transform - Analyze sentiment
            sentiment_df = None
            if news_df is not None and not news_df.empty:
                sentiment_df = self.analyze_sentiment(news_df)
            
            # Step 4: Load - Insert into database
            success = self.load_to_database(prices_df, sentiment_df)
            
            if success:
                logger.info("ETL Pipeline completed successfully")
            else:
                logger.warning("ETL Pipeline completed with errors")
            
            logger.info("=" * 60)
            return success
            
        except Exception as e:
            logger.error(f"Critical error in ETL pipeline: {e}")
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
        logger.error(f"Lambda handler error: {e}")
        return {
            'statusCode': 500,
            'body': {'error': str(e)}
        }


if __name__ == "__main__":
    """Run pipeline locally for testing"""
    pipeline = CryptoETLPipeline()
    pipeline.run()
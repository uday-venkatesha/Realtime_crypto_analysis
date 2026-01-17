"""
Simple script to test Supabase database connection
Run this BEFORE running the full ETL pipeline
"""

import os
import sys
from dotenv import load_dotenv
import psycopg2

# Force UTF-8 for Windows
if sys.platform == 'win32':
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

# Load environment variables
load_dotenv()

print("=" * 70)
print("TESTING SUPABASE DATABASE CONNECTION")
print("=" * 70)

# Get credentials from .env
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")

print("\n[1/3] Reading credentials from .env file...")
print(f"  DB_HOST: {DB_HOST}")
print(f"  DB_PORT: {DB_PORT}")
print(f"  DB_NAME: {DB_NAME}")
print(f"  DB_USER: {DB_USER}")
print(f"  DB_PASSWORD: {'*' * len(DB_PASSWORD) if DB_PASSWORD else 'NOT SET'}")

# Check if any are missing
missing = []
if not DB_HOST:
    missing.append("DB_HOST")
if not DB_PORT:
    missing.append("DB_PORT")
if not DB_NAME:
    missing.append("DB_NAME")
if not DB_USER:
    missing.append("DB_USER")
if not DB_PASSWORD:
    missing.append("DB_PASSWORD")

if missing:
    print(f"\n[ERROR] Missing required variables in .env file: {', '.join(missing)}")
    print("\nPlease check your .env file and add these variables.")
    print("Refer to the 'How to Get Supabase Credentials' guide.")
    sys.exit(1)

print("\n[2/3] Attempting to connect to database...")

try:
    # Build connection string
    conn_string = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    
    # Try to connect
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=10
    )
    
    print("  [OK] Connected successfully!")
    
    # Test a simple query
    print("\n[3/3] Testing database query...")
    cursor = conn.cursor()
    cursor.execute("SELECT version();")
    version = cursor.fetchone()
    print(f"  [OK] PostgreSQL version: {version[0][:50]}...")
    
    # Check if our tables exist
    cursor.execute("""
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name IN ('crypto_prices', 'crypto_sentiment')
        ORDER BY table_name;
    """)
    tables = cursor.fetchall()
    
    if tables:
        print(f"\n  [OK] Found {len(tables)} required table(s):")
        for table in tables:
            print(f"    - {table[0]}")
    else:
        print("\n  [WARNING] Required tables (crypto_prices, crypto_sentiment) not found!")
        print("  You may need to create them first.")
        print("\n  Run this SQL in Supabase SQL Editor:")
        print("""
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

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_crypto_prices_symbol ON crypto_prices(symbol);
CREATE INDEX IF NOT EXISTS idx_crypto_prices_last_updated ON crypto_prices(last_updated);
CREATE INDEX IF NOT EXISTS idx_crypto_sentiment_published_at ON crypto_sentiment(published_at);
CREATE INDEX IF NOT EXISTS idx_crypto_sentiment_sentiment_score ON crypto_sentiment(sentiment_score);
        """)
    
    cursor.close()
    conn.close()
    
    print("\n" + "=" * 70)
    print("[SUCCESS] Database connection test passed!")
    print("=" * 70)
    print("\nYou can now run the ETL pipeline:")
    print("  python etl_pipeline.py")
    print("")
    
except psycopg2.OperationalError as e:
    print(f"\n[ERROR] Failed to connect to database!")
    print(f"  Error: {e}")
    print("\n" + "=" * 70)
    print("TROUBLESHOOTING STEPS:")
    print("=" * 70)
    print("\n1. Verify your Supabase credentials:")
    print("   - Go to https://supabase.com/dashboard")
    print("   - Select your project")
    print("   - Click 'Project Settings' (gear icon)")
    print("   - Go to 'Database' tab")
    print("   - Find 'Connection pooling' section")
    print("   - Copy the connection string")
    print("")
    print("2. Your connection string should look like:")
    print("   postgresql://postgres.[PROJECT]:[PASSWORD]@[HOST]:6543/postgres")
    print("")
    print("3. Extract these values for .env:")
    print("   DB_USER = postgres.[PROJECT]  (before the : and password)")
    print("   DB_PASSWORD = your password")
    print("   DB_HOST = the hostname (after @ and before :6543)")
    print("   DB_PORT = 6543")
    print("   DB_NAME = postgres")
    print("")
    print("4. Common mistakes:")
    print("   - Wrong DB_USER (should include 'postgres.' prefix)")
    print("   - Typo in password (spaces, special characters)")
    print("   - Wrong host (should end with .pooler.supabase.com)")
    print("   - Wrong port (use 6543 for connection pooling)")
    print("")
    sys.exit(1)

except Exception as e:
    print(f"\n[ERROR] Unexpected error: {e}")
    print("\nPlease check your credentials and try again.")
    sys.exit(1)
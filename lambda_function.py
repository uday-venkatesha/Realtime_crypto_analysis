"""
AWS Lambda Function Handler for Crypto Sentiment ETL Pipeline
This is the entry point that Lambda will invoke
"""

import json
import logging
from datetime import datetime, timezone
from etl_pipeline import CryptoETLPipeline

# Configure logging for Lambda
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    AWS Lambda entry point
    
    Args:
        event: EventBridge trigger event (contains metadata)
        context: Lambda context object (contains runtime info)
    
    Returns:
        dict: Status code and response body
    """
    logger.info("=" * 70)
    logger.info(f"Lambda function invoked at: {datetime.now(timezone.utc).isoformat()}")
    logger.info(f"Function name: {context.function_name}")
    logger.info(f"Request ID: {context.aws_request_id}")
    logger.info(f"Memory limit: {context.memory_limit_in_mb} MB")
    logger.info("=" * 70)
    
    try:
        # Initialize and run ETL pipeline
        pipeline = CryptoETLPipeline()
        success = pipeline.run()
        
        # Prepare response
        response = {
            'statusCode': 200 if success else 500,
            'body': json.dumps({
                'message': 'ETL pipeline executed successfully' if success else 'ETL pipeline failed',
                'timestamp': datetime.now(timezone.utc).isoformat(),
                'function_name': context.function_name,
                'request_id': context.aws_request_id
            })
        }
        
        logger.info(f"Lambda execution completed: {response['statusCode']}")
        return response
        
    except Exception as e:
        logger.error(f"Lambda handler critical error: {e}", exc_info=True)
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'timestamp': datetime.now(timezone.utc).isoformat(),
                'function_name': context.function_name,
                'request_id': context.aws_request_id
            })
        }
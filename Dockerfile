# Use the official AWS Lambda Python 3.11 base image
# This ensures compatibility with Lambda's runtime environment
FROM public.ecr.aws/lambda/python:3.11

# Set environment variables for pip optimization
ENV PIP_DEFAULT_TIMEOUT=100 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

# Set working directory to Lambda task root
WORKDIR ${LAMBDA_TASK_ROOT}

# Copy requirements file first (for better layer caching)
COPY requirements.txt .

# Install Python dependencies
# Using --no-cache-dir to reduce image size
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY etl_pipeline.py .
COPY lambda_function.py .

# Verify critical files exist
RUN ls -la ${LAMBDA_TASK_ROOT} && \
    python -c "import lambda_function; print('Lambda function module OK')"

# Set the Lambda handler
# Format: {filename}.{function_name}
CMD ["lambda_function.lambda_handler"]
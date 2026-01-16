# Use AWS Lambda Python 3.11 base image
FROM public.ecr.aws/lambda/python:3.11

# Optimize pip for faster installs
ENV PIP_DEFAULT_TIMEOUT=100
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# Set working directory
WORKDIR ${LAMBDA_TASK_ROOT}

# Copy requirements first (for better caching)
COPY requirements.txt .

# Install Python dependencies with optimizations
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY etl_pipeline.py .
COPY lambda_function.py .

# Set the CMD to your Lambda handler
CMD ["lambda_function.lambda_handler"]
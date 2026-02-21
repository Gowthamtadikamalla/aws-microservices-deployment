FROM python:3.8-slim

LABEL PROMETHEUS_EXPORTER_PORT="5001"

WORKDIR /app

# Copy requirements and install dependencies.
COPY requirements.txt requirements.txt
RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy the application code.
COPY . .

# Expose port 5001.
EXPOSE 5001

# Run the application.
CMD ["python", "service2.py"]

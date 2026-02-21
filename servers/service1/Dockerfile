FROM python:3.8-slim

LABEL PROMETHEUS_EXPORTER_PORT="5000"

WORKDIR /app

# Copy requirements and install dependencies.
COPY requirements.txt requirements.txt
RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy the application code.
COPY . .

# Expose port 5000.
EXPOSE 5000

# Run the application.
CMD ["python", "service1.py"]

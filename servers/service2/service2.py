import json
import logging
import os
import sys
import time
import uuid

from flask import Flask, g, jsonify, request
from prometheus_flask_exporter import PrometheusMetrics


SERVICE_NAME = os.environ.get("SERVICE_NAME", "service2")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()


class JsonFormatter(logging.Formatter):
    """Minimal structured JSON log formatter with tenant/request context."""

    def format(self, record):
        payload = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created)),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "environment": ENVIRONMENT,
            "message": record.getMessage(),
        }
        for attr in ("tenant_id", "request_id", "path", "method", "status"):
            if hasattr(record, attr):
                payload[attr] = getattr(record, attr)
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def _configure_logging():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(LOG_LEVEL)


_configure_logging()
log = logging.getLogger(SERVICE_NAME)

app = Flask(__name__)
metrics = PrometheusMetrics(app)

metrics.info("app_info", "Application info", version="1.0.0", service="service-2")


@app.before_request
def _attach_request_context():
    g.request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    g.tenant_id = request.headers.get("X-Tenant-ID", "unknown")


@app.after_request
def _access_log(response):
    if request.path not in ("/health", "/metrics"):
        log.info(
            "http_request",
            extra={
                "tenant_id": getattr(g, "tenant_id", "unknown"),
                "request_id": getattr(g, "request_id", ""),
                "path": request.path,
                "method": request.method,
                "status": response.status_code,
            },
        )
    response.headers["X-Request-ID"] = getattr(g, "request_id", "")
    return response


@app.route("/")
@metrics.counter("index_requests_total", "Number of requests to the index page")
def index():
    return jsonify({
        "message": "Hello from Service 2",
        "user_info": request.headers.get("X-Amzn-Oidc-Data", "No user info provided"),
        "tenant_id": g.tenant_id,
        "request_id": g.request_id,
    })


@app.route("/service2")
@metrics.counter("service2_requests_total", "Number of requests to the service2 endpoint")
def s_index():
    return jsonify({
        "message": "Hello from Service 2",
        "user_info": request.headers.get("X-Amzn-Oidc-Data", "No user info provided"),
        "tenant_id": g.tenant_id,
        "request_id": g.request_id,
    })


@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)

import json
import logging
import os
import sys
import time
import uuid

from flask import Flask, g, jsonify, request
from prometheus_flask_exporter import PrometheusMetrics


SERVICE_NAME = os.environ.get("SERVICE_NAME", "service1")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()


class JsonFormatter(logging.Formatter):
    """Minimal structured JSON log formatter.

    Includes tenant_id and request_id when present on the log record so every
    line can be traced back to a specific tenant and HTTP request.
    """

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

metrics.info("app_info", "Application info", version="1.0.0", service="service-1")


@app.before_request
def _attach_request_context():
    g.request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    # Tenant id is supplied by an upstream component (API gateway, auth proxy,
    # or ALB) as a trusted header. We default to "unknown" rather than rejecting
    # so single-tenant callers can still use the service during migration.
    g.tenant_id = request.headers.get("X-Tenant-ID", "unknown")


@app.after_request
def _access_log(response):
    # Skip noisy endpoints that would otherwise dominate the log stream.
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
        "message": "Hello from Service 1",
        "user_info": request.headers.get("X-Amzn-Oidc-Data", "No user info provided"),
        "tenant_id": g.tenant_id,
        "request_id": g.request_id,
    })


@app.route("/service1")
@metrics.counter("service1_requests_total", "Number of requests to the service1 endpoint")
def s_index():
    return jsonify({
        "message": "Hello from Service 1",
        "user_info": request.headers.get("X-Amzn-Oidc-Data", "No user info provided"),
        "tenant_id": g.tenant_id,
        "request_id": g.request_id,
    })


@app.route("/health")
def health():
    # Health check is intentionally tenant-agnostic and does not emit an access
    # log line (ALB polls every 30 seconds and it would dominate the logs).
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

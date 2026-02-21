from flask import Flask, request, jsonify
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)
metrics = PrometheusMetrics(app)

metrics.info('app_info', 'Application info', version='1.0.0', service='service-2')

@app.route("/")
@metrics.counter('index_requests_total', 'Number of requests to the index page')
def index():
    # Retrieve user info passed by the ALB after Cognito authentication.
    user_info = request.headers.get('X-Amzn-Oidc-Data', 'No user info provided')
    return jsonify({
        "message": "Hello from Service 2",
        "user_info": user_info
    })

@app.route("/service2")
@metrics.counter('service2_requests_total', 'Number of requests to the service2 endpoint')
def s_index():
    # Retrieve user info passed by the ALB after Cognito authentication.
    user_info = request.headers.get('X-Amzn-Oidc-Data', 'No user info provided')
    return jsonify({
        "message": "Hello from Service 2",
        "user_info": user_info
    })

@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)

import os
import yaml
from flask import Flask, request, jsonify, abort
from render_config import render_zone

app = Flask(__name__)

record_file = os.environ.get("RECORD_FILE", "/data/records.yaml")
zone_file = os.environ.get("ZONE_FILE", "/etc/bind/db.override")
zone_name = os.environ.get("ZONE_NAME", "example.com")
api_key = os.environ.get("API_KEY", "changeme")

def require_api_key(f):
    def wrapper(*args, **kwargs):
        key = request.headers.get("X-API-Key")
        if not key or key != api_key:
            abort(401, description="Unauthorized: Invalid or missing API key")
        return f(*args, **kwargs)
    wrapper.__name__ = f.__name__  # Required to avoid Flask routing issues
    return wrapper

@app.route("/records", methods=["GET"])
@require_api_key
def get_records():
    with open(record_file) as f:
        data = yaml.safe_load(f)
    return jsonify(data)

@app.route("/records", methods=["POST", "PUT"])
@require_api_key
def update_records():
    new_data = request.get_json()
    if not new_data or "records" not in new_data:
        return {"error": "Invalid format, must contain 'records'"}, 400
    with open(record_file, "w") as f:
        yaml.safe_dump(new_data, f)
    render_zone(record_file, zone_file, zone_name)
    os.system("rndc reload || true")
    return {"message": "Records updated and zone reloaded"}, 200

@app.route("/reload", methods=["POST"])
@require_api_key
def manual_reload():
    render_zone(record_file, zone_file, zone_name)
    os.system("rndc reload || true")
    return {"message": "Zone reloaded"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

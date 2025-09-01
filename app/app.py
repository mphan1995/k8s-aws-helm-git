from flask import Flask
import os
app = Flask(__name__)

@app.route("/")
def hello():
    env = os.getenv("APP_ENV", "dev")
    return f"Hello from Flask on EKS via Helm! Env={env}\n"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))

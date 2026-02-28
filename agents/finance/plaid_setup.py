#!/usr/bin/env python3
"""
One-time Plaid Link setup.

Starts a local Flask server that serves the Plaid Link flow.
For each institution you want to connect (banks, Vanguard, etc.):
  1. Open http://localhost:5000 in your browser
  2. Click "Link Account" and complete the Plaid Link UI
  3. The access token is printed to the console
  4. Add it to .env as PLAID_ACCESS_TOKEN_1, PLAID_ACCESS_TOKEN_2, etc.

Reads PLAID_CLIENT_ID, PLAID_SECRET, PLAID_ENV from .env.

Usage:
    python3 plaid_setup.py
"""

import os
import sys

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

try:
    from flask import Flask, request, jsonify, render_template_string
except ImportError:
    sys.exit("ERROR: flask not installed. Run: pip install flask")

try:
    import plaid
    from plaid.api import plaid_api
    from plaid.model.link_token_create_request import LinkTokenCreateRequest
    from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
    from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
    from plaid.model.products import Products
    from plaid.model.country_code import CountryCode
except ImportError:
    sys.exit("ERROR: plaid-python not installed. Run: pip install plaid-python")


client_id = os.environ.get("PLAID_CLIENT_ID", "").strip()
secret = os.environ.get("PLAID_SECRET", "").strip()
plaid_env_name = os.environ.get("PLAID_ENV", "production").lower()

if not client_id:
    sys.exit("ERROR: PLAID_CLIENT_ID not set in .env")
if not secret:
    sys.exit("ERROR: PLAID_SECRET not set in .env")

env_map = {
    "sandbox": plaid.Environment.Sandbox,
    "development": plaid.Environment.Development,
    "production": plaid.Environment.Production,
}
plaid_host = env_map.get(plaid_env_name, plaid.Environment.Production)

configuration = plaid.Configuration(
    host=plaid_host,
    api_key={"clientId": client_id, "secret": secret},
)
api_client = plaid.ApiClient(configuration)
plaid_client = plaid_api.PlaidApi(api_client)

app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html>
<head>
  <title>Plaid Link Setup</title>
  <style>
    body { font-family: sans-serif; max-width: 600px; margin: 60px auto; padding: 0 20px; }
    button { padding: 12px 24px; font-size: 16px; cursor: pointer; background: #2563eb; color: white; border: none; border-radius: 6px; }
    button:hover { background: #1d4ed8; }
    #status { margin-top: 20px; padding: 12px; background: #f0fdf4; border: 1px solid #86efac; border-radius: 6px; display: none; }
  </style>
</head>
<body>
  <h1>Plaid Account Link</h1>
  <p>Click the button below to link a bank or investment account (e.g. Vanguard, Chase, etc.).</p>
  <p>After completing the Plaid Link flow, the access token will be printed in this terminal.</p>
  <button id="link-btn">Link Account</button>
  <div id="status"></div>

  <script src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"></script>
  <script>
    document.getElementById('link-btn').addEventListener('click', async () => {
      const resp = await fetch('/create_link_token', { method: 'POST' });
      const data = await resp.json();
      if (data.error) { alert('Error: ' + data.error); return; }

      const handler = Plaid.create({
        token: data.link_token,
        onSuccess: async (public_token, metadata) => {
          const exResp = await fetch('/exchange_token', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ public_token, institution: metadata.institution })
          });
          const exData = await exResp.json();
          if (exData.error) { alert('Exchange error: ' + exData.error); return; }
          const status = document.getElementById('status');
          status.style.display = 'block';
          status.innerHTML = '<strong>Success!</strong> Check the terminal for the access token to add to your .env file.';
        },
        onExit: (err) => {
          if (err) console.error('Plaid Link error:', err);
        }
      });
      handler.open();
    });
  </script>
</body>
</html>
"""


@app.route("/")
def index():
    return render_template_string(HTML)


@app.route("/create_link_token", methods=["POST"])
def create_link_token():
    try:
        req = LinkTokenCreateRequest(
            products=[Products("transactions"), Products("investments")],
            client_name="Homelab Finance Monitor",
            country_codes=[CountryCode("US")],
            language="en",
            user=LinkTokenCreateRequestUser(client_user_id="homelab-user"),
        )
        resp = plaid_client.link_token_create(req)
        return jsonify({"link_token": resp.link_token})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/exchange_token", methods=["POST"])
def exchange_token():
    data = request.get_json()
    public_token = data.get("public_token", "")
    institution = data.get("institution", {})
    institution_name = institution.get("name", "unknown") if institution else "unknown"

    try:
        req = ItemPublicTokenExchangeRequest(public_token=public_token)
        resp = plaid_client.item_public_token_exchange(req)
        access_token = resp.access_token

        print("\n" + "=" * 60)
        print(f"Institution: {institution_name}")
        print(f"Access token: {access_token}")
        print()
        print("Add to your .env file:")
        print(f"  PLAID_ACCESS_TOKEN_<n>={access_token}")
        print(f"  PLAID_INSTITUTION_<n>={institution_name.lower().replace(' ', '_')}")
        print("=" * 60 + "\n")

        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    print("Plaid Link setup server starting at http://localhost:5000")
    print("Open that URL in your browser to link accounts.")
    print("Press Ctrl+C when done.\n")
    app.run(port=5000, debug=False)

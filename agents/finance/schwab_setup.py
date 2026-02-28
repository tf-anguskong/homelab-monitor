#!/usr/bin/env python3
"""
One-time Schwab OAuth2 setup.

Run this interactively once to generate the token file used by collect.py.
Reads SCHWAB_CLIENT_ID, SCHWAB_CLIENT_SECRET, and SCHWAB_TOKEN_FILE from .env.

Usage:
    python3 schwab_setup.py
"""

import os
import sys

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))


def main():
    client_id = os.environ.get("SCHWAB_CLIENT_ID", "").strip()
    client_secret = os.environ.get("SCHWAB_CLIENT_SECRET", "").strip()
    token_file = os.environ.get("SCHWAB_TOKEN_FILE", "").strip()

    if not client_id:
        sys.exit("ERROR: SCHWAB_CLIENT_ID not set in .env")
    if not client_secret:
        sys.exit("ERROR: SCHWAB_CLIENT_SECRET not set in .env")
    if not token_file:
        sys.exit("ERROR: SCHWAB_TOKEN_FILE not set in .env")

    # Ensure the token directory exists
    token_dir = os.path.dirname(token_file)
    if token_dir:
        os.makedirs(token_dir, exist_ok=True)

    try:
        import schwab
    except ImportError:
        sys.exit("ERROR: schwab-py not installed. Run: pip install schwab-py")

    print("Starting Schwab OAuth2 flow...")
    print("A browser window will open. Log in to Schwab and authorise the app.")
    print("After authorising, you will be redirected to a localhost URL.")
    print("Copy the full redirect URL and paste it here when prompted.\n")

    try:
        # schwab-py handles the browser flow and callback
        client = schwab.auth.client_from_login_flow(
            client_id=client_id,
            client_secret=client_secret,
            redirect_uri="https://127.0.0.1",
            token_path=token_file,
        )
    except Exception as e:
        sys.exit(f"ERROR: OAuth flow failed: {e}")

    print(f"\nSuccess! Token saved to: {token_file}")
    print("You can now run collect.py — Schwab collection will use this token automatically.")
    print("The token will be refreshed automatically on each collect.py run.")


if __name__ == "__main__":
    main()

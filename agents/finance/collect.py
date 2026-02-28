#!/usr/bin/env python3
"""
Finance account balance collector.
Reads balances from Schwab, Robinhood, and Plaid-connected institutions,
then writes them to InfluxDB under the `account_balance` measurement.

Run hourly via cron. Each provider is skipped if its credentials are absent.
"""

import os
import sys
import logging
from datetime import datetime, timezone
from typing import Optional

from dotenv import load_dotenv
from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS

# Load .env from the same directory as this script
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# InfluxDB writer
# ---------------------------------------------------------------------------

def get_write_api():
    url = os.environ["INFLUXDB_URL"]
    token = os.environ["INFLUXDB_TOKEN"]
    org = os.environ["INFLUXDB_ORG"]
    client = InfluxDBClient(url=url, token=token, org=org)
    return client, client.write_api(write_options=SYNCHRONOUS)


def write_balance(
    write_api,
    org: str,
    bucket: str,
    institution: str,
    account_name: str,
    account_type: str,
    balance: float,
    ts: Optional[datetime] = None,
):
    if ts is None:
        ts = datetime.now(tz=timezone.utc)
    point = (
        Point("account_balance")
        .tag("institution", institution)
        .tag("account_name", account_name)
        .tag("account_type", account_type)
        .field("balance", float(balance))
        .time(ts, WritePrecision.SECONDS)
    )
    write_api.write(bucket=bucket, org=org, record=point)
    log.info(
        "wrote: institution=%s account=%s type=%s balance=%.2f",
        institution, account_name, account_type, balance,
    )


# ---------------------------------------------------------------------------
# Schwab
# ---------------------------------------------------------------------------

def collect_schwab(write_api, org, bucket):
    if os.environ.get("SCHWAB_ENABLED", "").lower() not in ("1", "true", "yes"):
        log.info("Schwab: disabled, skipping")
        return
    client_id = os.environ.get("SCHWAB_CLIENT_ID", "")
    client_secret = os.environ.get("SCHWAB_CLIENT_SECRET", "")
    token_file = os.environ.get("SCHWAB_TOKEN_FILE", "")
    if not (client_id and client_secret and token_file):
        log.info("Schwab: credentials not configured, skipping")
        return
    if not os.path.exists(token_file):
        log.warning("Schwab: token file %s not found — run schwab_setup.py first", token_file)
        return

    try:
        import schwab
        client = schwab.auth.client_from_token_file(token_file, client_id, client_secret)
    except Exception as e:
        log.error("Schwab: auth failed: %s", e)
        return

    try:
        resp = client.get_accounts(fields=[client.Account.Fields.POSITIONS])
        resp.raise_for_status()
        accounts = resp.json()
    except Exception as e:
        log.error("Schwab: get_accounts failed: %s", e)
        return

    ts = datetime.now(tz=timezone.utc)
    for entry in accounts:
        acct = entry.get("securitiesAccount", {})
        acct_type_raw = acct.get("type", "").lower()
        # Map Schwab account type strings to our schema types
        type_map = {
            "margin": "brokerage",
            "cash": "brokerage",
            "ira": "ira",
            "roth ira": "ira",
            "traditional ira": "ira",
        }
        acct_type = type_map.get(acct_type_raw, "brokerage")

        current_balances = acct.get("currentBalances", {})
        liquidation_value = current_balances.get("liquidationValue")
        if liquidation_value is None:
            liquidation_value = current_balances.get("cashBalance", 0.0)

        acct_number = acct.get("accountNumber", "unknown")
        # Use last 4 digits for privacy
        display_name = f"Schwab ...{acct_number[-4:]}" if len(acct_number) >= 4 else f"Schwab {acct_number}"

        write_balance(write_api, org, bucket, "schwab", display_name, acct_type, liquidation_value, ts)

    log.info("Schwab: done")


# ---------------------------------------------------------------------------
# Robinhood
# ---------------------------------------------------------------------------

def collect_robinhood(write_api, org, bucket):
    if os.environ.get("ROBINHOOD_ENABLED", "").lower() not in ("1", "true", "yes"):
        log.info("Robinhood: disabled, skipping")
        return
    username = os.environ.get("ROBINHOOD_USERNAME", "")
    password = os.environ.get("ROBINHOOD_PASSWORD", "")
    if not (username and password):
        log.info("Robinhood: credentials not configured, skipping")
        return

    try:
        import robin_stocks.robinhood as r
    except ImportError:
        log.error("Robinhood: robin_stocks not installed")
        return

    totp_secret = os.environ.get("ROBINHOOD_TOTP_SECRET", "")
    mfa_code = None
    if totp_secret:
        try:
            import pyotp
            mfa_code = pyotp.TOTP(totp_secret).now()
        except Exception as e:
            log.warning("Robinhood: TOTP generation failed: %s", e)

    try:
        if mfa_code:
            r.login(username, password, mfa_code=mfa_code)
        else:
            r.login(username, password)
    except Exception as e:
        log.error("Robinhood: login failed: %s", e)
        return

    ts = datetime.now(tz=timezone.utc)
    try:
        profile = r.account.build_user_profile()
        equity = float(profile.get("equity", 0.0))
        write_balance(write_api, org, bucket, "robinhood", "Robinhood Brokerage", "brokerage", equity, ts)

        # Crypto portfolio (separate from equity in some API versions)
        try:
            crypto = r.crypto.get_crypto_positions()
            crypto_total = sum(
                float(p.get("quantity", 0)) * float(p.get("cost_bases", [{}])[0].get("direct_cost_basis", 0))
                for p in (crypto or [])
                if p.get("quantity")
            )
            if crypto_total > 0:
                write_balance(write_api, org, bucket, "robinhood", "Robinhood Crypto", "brokerage", crypto_total, ts)
        except Exception:
            pass  # Crypto not available or zero balance

    except Exception as e:
        log.error("Robinhood: balance fetch failed: %s", e)
    finally:
        try:
            r.logout()
        except Exception:
            pass

    log.info("Robinhood: done")


# ---------------------------------------------------------------------------
# Plaid
# ---------------------------------------------------------------------------

def collect_plaid(write_api, org, bucket):
    client_id = os.environ.get("PLAID_CLIENT_ID", "")
    plaid_secret = os.environ.get("PLAID_SECRET", "")
    plaid_env = os.environ.get("PLAID_ENV", "production")
    if not (client_id and plaid_secret):
        log.info("Plaid: credentials not configured, skipping")
        return

    # Collect all PLAID_ACCESS_TOKEN_n values from env
    access_tokens = []
    i = 1
    while True:
        token = os.environ.get(f"PLAID_ACCESS_TOKEN_{i}", "")
        if not token:
            break
        access_tokens.append(token)
        i += 1

    if not access_tokens:
        log.info("Plaid: no access tokens configured, skipping")
        return

    try:
        from plaid.api import plaid_api
        from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
        import plaid
    except ImportError:
        log.error("Plaid: plaid-python not installed")
        return

    env_map = {
        "sandbox": plaid.Environment.Sandbox,
        "development": plaid.Environment.Development,
        "production": plaid.Environment.Production,
    }
    plaid_env_obj = env_map.get(plaid_env.lower(), plaid.Environment.Production)

    configuration = plaid.Configuration(
        host=plaid_env_obj,
        api_key={
            "clientId": client_id,
            "secret": plaid_secret,
        },
    )
    api_client = plaid.ApiClient(configuration)
    client = plaid_api.PlaidApi(api_client)

    type_map = {
        "depository": {"checking": "checking", "savings": "savings", "cd": "savings", "money market": "savings"},
        "credit": {"credit card": "credit", "paypal": "credit"},
        "investment": {"401k": "ira", "ira": "ira", "roth": "ira", "brokerage": "brokerage"},
        "loan": {"student": "credit", "mortgage": "credit", "auto": "credit"},
        "other": {},
    }

    ts = datetime.now(tz=timezone.utc)
    for idx, access_token in enumerate(access_tokens, start=1):
        try:
            request = AccountsBalanceGetRequest(access_token=access_token)
            response = client.accounts_balance_get(request)
        except Exception as e:
            log.error("Plaid: token %d balance fetch failed: %s", idx, e)
            continue

        institution_name = "bank"
        try:
            item = response.item
            # Try to get institution name via item metadata (not always available without extra call)
            # Fall back to a generic name; plaid_setup.py stores the name in .env optionally
            inst_name_env = os.environ.get(f"PLAID_INSTITUTION_{idx}", "")
            if inst_name_env:
                institution_name = inst_name_env.lower().replace(" ", "_")
        except Exception:
            pass

        for acct in response.accounts:
            acct_name = acct.name or f"Account {acct.account_id[-4:]}"
            acct_plaid_type = str(acct.type).lower() if acct.type else "other"
            acct_plaid_subtype = str(acct.subtype).lower() if acct.subtype else ""

            # Map Plaid type/subtype → our account_type
            sub_map = type_map.get(acct_plaid_type, {})
            acct_type = sub_map.get(acct_plaid_subtype, acct_plaid_type)
            if acct_type not in ("brokerage", "ira", "checking", "savings", "credit", "investment"):
                acct_type = "other"

            # Use current balance for most; available for credit
            balances = acct.balances
            if acct_plaid_type == "credit":
                balance = float(balances.current or 0.0)
            else:
                balance = float(balances.current or balances.available or 0.0)

            write_balance(write_api, org, bucket, institution_name, acct_name, acct_type, balance, ts)

    log.info("Plaid: done (%d token(s))", len(access_tokens))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    org = os.environ["INFLUXDB_ORG"]
    bucket = os.environ["INFLUXDB_BUCKET"]

    client, write_api = get_write_api()
    try:
        collect_schwab(write_api, org, bucket)
        collect_robinhood(write_api, org, bucket)
        collect_plaid(write_api, org, bucket)
    finally:
        write_api.close()
        client.close()

    log.info("Collection complete")


if __name__ == "__main__":
    main()

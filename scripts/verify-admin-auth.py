#!/usr/bin/env python3
"""
scripts/verify-admin-auth.py - Verify Photobooth-App admin authentication.

Reference: docs/photobooth-auth-contract.md
Authenticates via POST /api/admin/auth/token (OAuth2PasswordBearer).
Verifies identity via GET /api/admin/auth/me.
Read-only authentication test: does not write or modify configuration.
"""

import argparse
import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Tuple

DEFAULT_BASE_URL = "http://192.168.2.3:8000"


def get_credentials() -> Tuple[str, str]:
    """
    Retrieve admin credentials from environment variables or interactive prompt.
    Does not echo password during interactive entry.
    """
    username = os.environ.get("PHOTOBOOTH_ADMIN_USERNAME", "").strip()
    password = os.environ.get("PHOTOBOOTH_ADMIN_PASSWORD", "").strip()

    if not username:
        try:
            username = input("Enter admin username: ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.stderr.write("Error: Username prompt interrupted or input unavailable.\n")
            sys.exit(1)

    if not password:
        try:
            password = getpass.getpass("Enter admin password: ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.stderr.write("Error: Password prompt interrupted or input unavailable.\n")
            sys.exit(1)

    if not username:
        sys.stderr.write("Error: Username cannot be empty.\n")
        sys.exit(1)

    if not password:
        sys.stderr.write("Error: Password cannot be empty.\n")
        sys.exit(1)

    return username, password


def authenticate(base_url: str, username: str, password: str) -> str:
    """
    Authenticate against POST /api/admin/auth/token using application/x-www-form-urlencoded.
    Returns access_token. Never prints or persists password or token.
    """
    token_url = f"{base_url.rstrip('/')}/api/admin/auth/token"
    form_data = urllib.parse.urlencode({"username": username, "password": password}).encode("utf-8")

    req = urllib.request.Request(
        token_url,
        data=form_data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                sys.stderr.write(f"Error: Unexpected HTTP status {resp.status} from {token_url}\n")
                sys.exit(1)
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if err.code == 401:
            sys.stderr.write("Error: Authentication failed (HTTP 401). Incorrect username or password.\n")
        else:
            sys.stderr.write(f"Error: HTTP {err.code} {err.reason} from {token_url}\n")
        sys.exit(1)
    except urllib.error.URLError as err:
        sys.stderr.write(f"Error: Failed to reach Photobooth-App at {token_url}: {err.reason}\n")
        sys.exit(1)
    except TimeoutError:
        sys.stderr.write(f"Error: Connection timed out reaching {token_url}\n")
        sys.exit(1)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Error: Invalid JSON response from {token_url}: {err}\n")
        sys.exit(1)

    access_token = payload.get("access_token")
    if not access_token:
        sys.stderr.write("Error: Missing 'access_token' in token response.\n")
        sys.exit(1)

    return access_token


def verify_me(base_url: str, access_token: str) -> Dict[str, Any]:
    """
    Verify identity via GET /api/admin/auth/me using Bearer token.
    Returns User dictionary containing username and full_name.
    """
    me_url = f"{base_url.rstrip('/')}/api/admin/auth/me"
    req = urllib.request.Request(
        me_url,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/json",
        },
        method="GET",
    )

    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                sys.stderr.write(f"Error: Unexpected HTTP status {resp.status} from {me_url}\n")
                sys.exit(1)
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        sys.stderr.write(f"Error: HTTP {err.code} {err.reason} from {me_url}\n")
        sys.exit(1)
    except urllib.error.URLError as err:
        sys.stderr.write(f"Error: Failed to reach Photobooth-App at {me_url}: {err.reason}\n")
        sys.exit(1)
    except TimeoutError:
        sys.stderr.write(f"Error: Connection timed out reaching {me_url}\n")
        sys.exit(1)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Error: Invalid JSON response from {me_url}: {err}\n")
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify Photobooth-App admin authentication and identity (read-only)."
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_BASE_URL,
        help=f"Base URL of Photobooth-App (default: {DEFAULT_BASE_URL})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print authenticated user identity as JSON",
    )

    args = parser.parse_args()

    username, password = get_credentials()
    access_token = authenticate(args.url, username, password)
    user_info = verify_me(args.url, access_token)

    username_val = user_info.get("username")
    full_name_val = user_info.get("full_name")

    if args.json:
        print(json.dumps({"username": username_val, "full_name": full_name_val}, indent=2))
    else:
        print(f"username: {username_val}")
        print(f"full_name: {full_name_val}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read provider identity metadata and enforce an optional local account profile.

No credential files are opened. Codex identity is read through account/read on
a short-lived local app-server; Claude identity comes from auth status. Neither
operation submits a task, starts a model turn, refreshes tokens, or logs in.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import threading


class AccountError(ValueError):
    """An account cannot be safely selected or verified."""


def load_profile(state_dir=None, environ=None) -> dict:
    env = os.environ if environ is None else environ
    directory = state_dir if state_dir is not None else env.get("KILN_STATE_DIR")
    if not directory:
        return {}
    path = Path(directory) / "providers.json"
    try:
        if not path.exists():
            return {}
        if path.stat().st_size > 65536:
            raise AccountError("Provider profile is too large")
        profile = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AccountError("Cannot read the local providers.json profile") from error
    if not isinstance(profile, dict):
        raise AccountError("providers.json must contain a JSON object")
    for key in ("expected_email", "claude_config_dir", "codex_home"):
        if key in profile and (not isinstance(profile[key], str) or not profile[key].strip()
                               or any(char in profile[key] for char in ("\n", "\r", "\x00"))):
            raise AccountError(f"providers.json {key} must be a nonempty single-line string")
    if profile.get("expected_email") and "@" not in profile["expected_email"]:
        raise AccountError("providers.json expected_email must be an email address")
    for key in ("claude_config_dir", "codex_home"):
        if profile.get(key) and not Path(profile[key]).is_absolute():
            raise AccountError(f"providers.json {key} must be an absolute path")
    return profile


def provider_environment(base_env=None, state_dir=None) -> dict[str, str]:
    """Restore the original provider environment, then apply explicit profiles."""
    env = dict(os.environ if base_env is None else base_env)
    for suffix in ("CONFIG_HOME", "DATA_HOME", "STATE_HOME", "CACHE_HOME"):
        key = "XDG_" + suffix
        original = "KILN_ORIGINAL_" + key
        if original in env:
            value = env.pop(original)
            if value:
                env[key] = value
            else:
                env.pop(key, None)
    profile = load_profile(state_dir, env)
    for key, variable in (("claude_config_dir", "CLAUDE_CONFIG_DIR"), ("codex_home", "CODEX_HOME")):
        if profile.get(key):
            env[variable] = profile[key]
    return env


def config_directory(provider: str, env: dict) -> str:
    if provider == "codex":
        return env.get("CODEX_HOME") or str(Path(env.get("HOME", str(Path.home()))) / ".codex")
    return env.get("CLAUDE_CONFIG_DIR") or str(Path(env.get("HOME", str(Path.home()))) / ".claude")


def _finish(process: subprocess.Popen) -> None:
    """Close a metadata subprocess and its process group within a bounded time."""
    if process.stdin and not process.stdin.closed:
        process.stdin.close()
    try:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=0.3)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=0.3)
    finally:
        # The server must not leave inherited worker processes behind.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for pipe in (process.stdout, process.stderr):
            if pipe and not pipe.closed:
                pipe.close()


def _claude_account(env: dict, timeout: float) -> dict:
    command = [env.get("KILN_CLAUDE_BIN", "claude"), "auth", "status", "--json"]
    process = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, start_new_session=True)
        stdout, _stderr = process.communicate(timeout=timeout)
        if len(stdout) > 1024 * 1024:
            raise AccountError("Claude account metadata exceeded the size limit")
        data = json.loads(stdout)
        if not isinstance(data, dict):
            raise AccountError("Claude returned an invalid account metadata object")
        method = data.get("authMethod")
        # API keys and external routes do not establish an email identity.
        email = data.get("email") if (method in ("claude.ai", "oauth_token")
                                       and data.get("apiProvider") == "firstParty") else None
        return {"authenticated": bool(data.get("loggedIn")),
                "email": email if isinstance(email, str) and email else None,
                "config_dir": data.get("configDirectory") or config_directory("claude", env)}
    except subprocess.TimeoutExpired as error:
        raise AccountError("Claude account verification timed out") from error
    except (OSError, json.JSONDecodeError) as error:
        raise AccountError("Claude account metadata is unavailable; check the selected CLI profile") from error
    finally:
        if process is not None:
            _finish(process)


def _codex_account(env: dict, timeout: float) -> dict:
    command = [env.get("KILN_CODEX_BIN", "codex"), "app-server", "--stdio"]
    process = None
    deadline = time.monotonic() + timeout
    buffer = b""
    replies = {}
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, start_new_session=True, bufsize=0)
        with selectors.DefaultSelector() as selector:
            for pipe in (process.stdout, process.stderr):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ)

            def send(record):
                process.stdin.write((json.dumps(record) + "\n").encode())

            def receive(identity):
                nonlocal buffer
                while identity not in replies:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise AccountError("Codex account verification timed out")
                    if not selector.get_map():
                        raise AccountError("Codex account metadata server exited before replying")
                    for key, _events in selector.select(min(remaining, 0.1)):
                        pipe = key.fileobj
                        try:
                            chunk = os.read(pipe.fileno(), 65536)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(pipe)
                            continue
                        if pipe is process.stderr:
                            continue  # Never print provider diagnostics or credential-bearing output.
                        buffer += chunk
                        if len(buffer) > 1024 * 1024:
                            raise AccountError("Codex account metadata exceeded the size limit")
                        while b"\n" in buffer:
                            line, buffer = buffer.split(b"\n", 1)
                            try:
                                record = json.loads(line)
                            except (json.JSONDecodeError, UnicodeDecodeError):
                                continue
                            if isinstance(record, dict) and record.get("id") in (1, 2):
                                replies[record["id"]] = record
                record = replies.pop(identity)
                if "error" in record or not isinstance(record.get("result"), dict):
                    raise AccountError("Codex refused the account metadata request")
                return record["result"]

            send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "kiln", "title": "Kiln account check", "version": "0.1.0"}}})
            receive(1)
            send({"method": "initialized", "params": {}})
            send({"id": 2, "method": "account/read", "params": {"refreshToken": False}})
            data = receive(2)
        account = data.get("account")
        if not isinstance(account, dict):
            account = {}
        email = account.get("email") if account.get("type") == "chatgpt" and data.get("requiresOpenaiAuth", True) else None
        return {"authenticated": bool(account), "email": email if isinstance(email, str) and email else None,
                "config_dir": config_directory("codex", env)}
    except (OSError, BrokenPipeError) as error:
        raise AccountError("Codex account metadata is unavailable; check the selected CLI profile") from error
    finally:
        if process is not None:
            _finish(process)


def read_account(provider: str, env=None, timeout: float = 5) -> dict:
    if provider not in ("codex", "claude"):
        raise AccountError("Unsupported account provider")
    environment = provider_environment() if env is None else env
    old_handlers = {}

    def stop(signum, frame):
        previous = old_handlers.get(signum)
        if callable(previous):
            previous(signum, frame)
        raise AccountError("Account verification stopped")

    try:
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                old_handlers[sig] = signal.signal(sig, stop)
        if provider == "codex":
            return _codex_account(environment, timeout)
        return _claude_account(environment, timeout)
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def _unverifiable_route(provider: str, env: dict) -> str | None:
    keys = (("OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE")
            if provider == "codex" else
            ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
             "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
             "CLAUDE_CODE_USE_FOUNDRY"))
    for key in keys:
        value = env.get(key)
        if value and (not key.startswith("CLAUDE_CODE_USE_") or value.lower() not in ("0", "false")):
            return key
    return None


def check_account(provider: str, profile=None, env=None, timeout: float = 5) -> dict:
    environment = provider_environment() if env is None else env
    selected = load_profile(environ=environment) if profile is None else profile
    expected = selected.get("expected_email")
    if expected:
        route = _unverifiable_route(provider, environment)
        if route:
            raise AccountError(f"Cannot verify the required email while {route} selects another authentication route")
    account = read_account(provider, environment, timeout)
    email = account.get("email")
    account["matches"] = (bool(account["authenticated"] and email and email.casefold() == expected.casefold())
                          if expected else None)
    return account


def enforce_account(provider: str, profile=None, env=None, timeout: float = 5) -> None:
    environment = provider_environment() if env is None else env
    selected = load_profile(environ=environment) if profile is None else profile
    expected = selected.get("expected_email")
    if not expected:
        return
    account = check_account(provider, selected, environment, timeout)
    if account["matches"]:
        return
    actual = account.get("email")
    if actual:
        raise AccountError(f"{provider.title()} is signed in as {actual}; Kiln requires {expected}. No agent started. Select the correct local profile or sign in through kiln --login {provider}.")
    raise AccountError(f"Cannot verify {provider.title()} as {expected}. No agent started. Sign in to the selected profile through kiln --login {provider}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    parser.add_argument("--state-dir")
    args = parser.parse_args()
    result = {"authenticated": False, "email": None, "matches": False, "config_dir": None}
    try:
        profile = load_profile(args.state_dir)
        env = provider_environment(state_dir=args.state_dir)
        result = check_account(args.provider, profile, env)
    except AccountError as error:
        print(f"Kiln: {error}", file=sys.stderr)
        print(json.dumps(result))
        return 1
    print(json.dumps({key: result[key] for key in ("authenticated", "email", "matches", "config_dir")}))
    return 1 if result["matches"] is False else 0


if __name__ == "__main__":
    raise SystemExit(main())

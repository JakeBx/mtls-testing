"""mTLS smoke tests for garak RestGenerator with client certificates.

Prerequisites:
    - ./certs/generate-certs.sh has been run
    - docker compose up -d (nginx mTLS proxy)
    - ollama running on localhost:11434
"""

import json
import multiprocessing
import os
import pathlib
import pickle
import pytest

PROMPT = "Say hello"
CONFIG_DIR = pathlib.Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_garak_config(config_file: str = "garak_config.json") -> dict:
    """Load and return the garak config dict."""
    with open(CONFIG_DIR / config_file) as f:
        return json.load(f)


def _make_prompt(text: str):
    """Build a garak Conversation object from a plain string.

    garak's _call_model expects a Conversation whose last Turn has a
    Message with a .text attribute — NOT a raw string.
    """
    from garak.attempt import Conversation, Message, Turn
    return Conversation(turns=[Turn(role="user", content=Message(text=text))])


def _make_generator(config_file: str = "garak_config.json"):
    """Instantiate a RestGenerator from the given config file.

    _load_config expects config_root to be a dict with a top-level
    'generators' key (i.e. the 'plugins' sub-dict from the full config).
    """
    from garak.generators.rest import RestGenerator

    cfg = _load_garak_config(config_file)
    # Pass the full plugins.generators subtree so _load_config can
    # navigate: generators -> rest -> RestGenerator
    plugins_cfg = {"generators": cfg["plugins"]["generators"]}
    return RestGenerator(config_root=plugins_cfg)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_basic_request():
    """Load config, instantiate RestGenerator, call _call_model once, assert non-empty response."""
    gen = _make_generator("garak_config.json")
    result = gen._call_model(_make_prompt(PROMPT))
    assert result is not None, "Response was None"
    assert len(result) > 0, "Response was empty"
    assert result[0] is not None, "First result element was None"
    assert len(result[0].text) > 0, "Response text was empty"
    print(f"Response: {result[0].text}")


def test_encrypted_key():
    """Set MTLS_KEY_PASS in env, load config with client_key_passphrase_env_var, same assertion."""
    os.environ["MTLS_KEY_PASS"] = "changeit"
    try:
        gen = _make_generator("garak_config_encrypted.json")
        result = gen._call_model(_make_prompt(PROMPT))
        assert result is not None, "Response was None"
        assert len(result) > 0, "Response was empty"
        assert result[0] is not None, "First result element was None"
        assert len(result[0].text) > 0, "Response text was empty"
        print(f"Response (encrypted key): {result[0].text}")
    finally:
        os.environ.pop("MTLS_KEY_PASS", None)


def _worker(gen_state, prompt_turns_data, result_queue):
    """Worker function that reconstructs a RestGenerator in a subprocess and makes a request."""
    from garak.generators.rest import RestGenerator
    from garak.attempt import Conversation, Message, Turn
    gen = RestGenerator.__new__(RestGenerator)
    gen.__setstate__(gen_state)
    # Rebuild Conversation from serializable data
    conv = Conversation(turns=[
        Turn(role=t["role"], content=Message(text=t["text"]))
        for t in prompt_turns_data
    ])
    result = gen._call_model(conv)
    result_queue.put([m.text if m is not None else None for m in result])


def test_multiprocessing_pickle():
    """Test that RestGenerator can be pickled/unpickled across process boundaries.

    This explicitly tests:
    - __getstate__ strips the mTLS session (non-picklable SSL context)
    - __setstate__ rebuilds it in the subprocess
    - A live request succeeds from the subprocess
    """
    gen = _make_generator("garak_config.json")
    state = gen.__getstate__()

    # The mTLS session must be stripped for pickling
    assert state.get("_mtls_session") is None, \
        "__getstate__ must strip _mtls_session for pickle compatibility"

    # Verify it's actually picklable
    pickled = pickle.dumps(state)
    assert len(pickled) > 0

    # Serialize the prompt as plain dicts (fully picklable, no garak types)
    prompt_turns_data = [{"role": "user", "text": PROMPT}]

    q = multiprocessing.Queue()
    p = multiprocessing.Process(target=_worker, args=(state, prompt_turns_data, q))
    p.start()
    p.join(timeout=15)

    assert p.exitcode == 0, f"Subprocess exited with code {p.exitcode}"
    result = q.get_nowait()
    assert result is not None and len(result) > 0, \
        f"Subprocess returned empty/None result: {result}"
    assert result[0] is not None and len(result[0]) > 0, \
        f"Subprocess returned empty first result: {result}"
    print(f"Response (multiprocessing): {result[0]}")

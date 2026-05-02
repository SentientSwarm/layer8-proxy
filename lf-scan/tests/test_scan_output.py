"""Tests for POST /scan/output."""


def test_scan_output_allows_benign_response(client):
    response = client.post(
        "/scan/output",
        json={
            "messages": [
                {"role": "user", "content": "Show me a hello-world Python program"},
                {"role": "assistant", "content": "print('hello, world')"},
            ],
            "scanners": ["codeshield"],
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "ALLOW"


def test_scan_output_blocks_dangerous_code(client):
    """CodeShield should flag clearly insecure generated code.

    Sample: SHA1 used for password hashing (weak hash + credential context).
    """
    danger = (
        "import hashlib\n"
        "def hash_password(p):\n"
        "    return hashlib.sha1(p.encode()).hexdigest()\n"
    )
    response = client.post(
        "/scan/output",
        json={
            "messages": [
                {"role": "user", "content": "Write a password hashing helper"},
                {"role": "assistant", "content": danger},
            ],
            "scanners": ["codeshield"],
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "BLOCK"
    assert "codeshield" in body["scanners_triggered"]


def test_scan_output_rejects_unknown_scanner(client):
    response = client.post(
        "/scan/output",
        json={
            "messages": [{"role": "assistant", "content": "ok"}],
            "scanners": ["nonexistent"],
        },
    )
    assert response.status_code == 400

"""Signs a release's latest.json and publishes the release.

    .venv/bin/python scripts/publish_release.py 1.0.1    # sign and publish the draft v1.0.1
    .venv/bin/python scripts/publish_release.py new-key  # once: make the signing key

The Release workflow makes a draft with the .dmg, the .zip and latest.json,
and a build attestation for the .dmg and the .zip. This checks that both
were built by that workflow on main from the commit the draft points at,
shows that commit, checks that latest.json describes the zip, signs latest.json with the
key in ~/.config/luftbro-release (LUFTBRO_SIGNING_KEY for another file),
uploads the signature as latest.json.sig and publishes the draft. The app
installs an update only when latest.json.sig verifies against the public key
in Updater.swift, so the key never goes to GitHub. Keep a copy of it somewhere
safe: without it, installed copies can't be updated.
"""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

REPO = "luftbro/luftbro"
ROOT = Path(__file__).resolve().parent.parent
UPDATER = ROOT / "app/Sources/Luftbro/Support/Updater.swift"
KEY_FILE = Path(os.environ.get("LUFTBRO_SIGNING_KEY")
                or Path.home() / ".config/luftbro-release/update-signing-key.pem")


def die(msg):
    sys.exit(f"publish_release: {msg}")


def public_key_b64(key):
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def load_key():
    if not KEY_FILE.exists():
        die(f"no signing key at {KEY_FILE}")
    key = serialization.load_pem_private_key(KEY_FILE.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        die(f"{KEY_FILE} is not an Ed25519 key")
    return key


def new_key():
    if KEY_FILE.exists():
        die(f"{KEY_FILE} exists already; a new key would lock out every installed copy")
    KEY_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    key = Ed25519PrivateKey.generate()
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(pem)
    print(f"Signing key: {KEY_FILE}")
    print(f"Public key for Updater.swift: {public_key_b64(key)}")


def gh(*args, capture=True):
    r = subprocess.run(["gh", *args, "-R", REPO], capture_output=capture, text=True)
    if r.returncode != 0:
        die(f"gh {' '.join(args)} failed: {(r.stderr or '').strip()}")
    return r.stdout


def attested_commit(path):
    """The commit the Release workflow built `path` from, on main."""
    r = subprocess.run(["gh", "attestation", "verify", str(path), "-R", REPO,
                        "--signer-workflow", f"{REPO}/.github/workflows/release.yml",
                        "--format", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"{path.name} has no valid attestation from the Release workflow: {r.stderr.strip()}")
    certs = [a["verificationResult"]["signature"]["certificate"] for a in json.loads(r.stdout)]
    commits = {c["sourceRepositoryDigest"] for c in certs if c.get("sourceRepositoryRef") == "refs/heads/main"}
    if len(commits) != 1:
        die(f"{path.name} is not attested as one build from main")
    return commits.pop()


def publish(version, ask=True):
    key = load_key()
    m = re.search(r'updateKey = "([A-Za-z0-9+/=]+)"', UPDATER.read_text())
    if not m or m.group(1) != public_key_b64(key):
        die(f"the public key in {UPDATER.relative_to(ROOT)} doesn't belong to {KEY_FILE}")

    tag = f"v{version}"
    release = json.loads(gh("release", "view", tag, "--json", "isDraft,assets,targetCommitish"))
    names = {a["name"] for a in release["assets"]}
    zip_name, dmg_name = f"Luftbro-{version}.zip", f"Luftbro-{version}.dmg"
    for needed in (dmg_name, zip_name, "latest.json"):
        if needed not in names:
            die(f"{tag} has no {needed}")

    with tempfile.TemporaryDirectory() as tmp:
        gh("release", "download", tag, "-p", "latest.json", "-p", zip_name, "-p", dmg_name, "-D", tmp)
        commit = release["targetCommitish"]
        for name in (zip_name, dmg_name):
            if attested_commit(Path(tmp) / name) != commit:
                die(f"{name} was not built from {commit[:7]}, the commit {tag} points at")
        subprocess.run(["git", "-C", str(ROOT), "fetch", "-q", "origin", "main"], check=True)
        if subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", commit, "origin/main"]).returncode:
            die(f"{commit[:7]} is not on main")
        subject = subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%h %s (%cs)", commit],
                                 capture_output=True, text=True).stdout.strip()
        print(f"{tag} was built by the Release workflow from {subject}")
        if ask and input(f"Sign and publish {tag}? [y/N] ").strip().lower() != "y":
            die("nothing signed or published")

        feed_bytes = (Path(tmp) / "latest.json").read_bytes()
        feed = json.loads(feed_bytes)
        url = f"https://github.com/{REPO}/releases/download/{tag}/{zip_name}"
        zip_sha = hashlib.sha256((Path(tmp) / zip_name).read_bytes()).hexdigest()
        if feed.get("version") != version:
            die(f"latest.json is for version {feed.get('version')}, not {version}")
        if feed.get("url") != url:
            die(f"latest.json points at {feed.get('url')}, not {url}")
        if feed.get("sha256") != zip_sha:
            die(f"latest.json's checksum doesn't match {zip_name}")

        sig = Path(tmp) / "latest.json.sig"
        sig.write_text(base64.b64encode(key.sign(feed_bytes)).decode() + "\n")
        gh("release", "upload", tag, str(sig), "--clobber")

    if release["isDraft"]:
        gh("release", "edit", tag, "--draft=false", "--latest")
        print(f"Signed and published {tag} (build {feed['build']}).")
    else:
        print(f"Signed {tag} (build {feed['build']}); it was already published.")


if __name__ == "__main__":
    args = sys.argv[1:]
    yes = "--yes" in args
    args = [a for a in args if a != "--yes"]
    if len(args) != 1:
        die("usage: publish_release.py <version> [--yes] | new-key")
    if args[0] == "new-key":
        new_key()
    elif re.fullmatch(r"\d+(\.\d+)+", args[0]):
        publish(args[0], ask=not yes)
    else:
        die(f"not a version: {args[0]}")

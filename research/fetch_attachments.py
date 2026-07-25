"""Pull attachments off a Gmail message by UID, reusing the local gmail_tools creds.

Used to retrieve the on-device iOS crash report (.ips) that Zach shared from
Settings > Privacy & Security > Analytics & Improvements, without needing a Mac
or Xcode. The .ips is JSON-ish text; iOS writes the terminating reason into it
in plain language, including the exact Info.plist key when a usage description
is missing.
"""
import email
import os
import sys

sys.path.insert(0, os.path.expanduser(r"~/.claude/scripts"))
from gmail_tools import _imap  # noqa: E402


def fetch(uid, outdir, mailbox='"[Gmail]/All Mail"'):
    os.makedirs(outdir, exist_ok=True)
    M = _imap()
    saved = []
    try:
        M.select(mailbox, readonly=True)
        typ, data = M.uid("fetch", uid, "(RFC822)")
        if typ != "OK" or not data or not data[0]:
            print("fetch failed for uid", uid)
            return saved
        msg = email.message_from_bytes(data[0][1])
        for part in msg.walk():
            if part.get_content_maintype() == "multipart":
                continue
            name = part.get_filename()
            disp = str(part.get("Content-Disposition", ""))
            if not name and "attachment" not in disp:
                continue
            payload = part.get_payload(decode=True)
            if not payload:
                continue
            name = name or "attachment.bin"
            safe = "".join(c for c in name if c.isalnum() or c in "._- ")
            path = os.path.join(outdir, safe)
            with open(path, "wb") as f:
                f.write(payload)
            saved.append((path, len(payload), part.get_content_type()))
    finally:
        M.logout()
    return saved


if __name__ == "__main__":
    uid = sys.argv[1]
    outdir = sys.argv[2]
    for path, size, ctype in fetch(uid, outdir):
        print(f"{size:>9,} bytes  {ctype:<28} {path}")

#!/usr/bin/env bash
# Checks the "Word copy" tool on the running stack (after import_seed.py):
#   - unit tests of the .docx logic (inside the openwebui container: python-docx)
#   - end to end: a fictitious .docx is attached to a saved chat, mistral-small is asked to
#     "edit a copy"; the answer must link a new .docx with the change, the original intact.
# The chat, the uploaded file and the copy are deleted afterwards.
# Usage: ./scripts/test-word-tool.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

E2E_PY='import json, os, re, sys, tempfile, time, uuid, urllib.request
sys.path.insert(0, "/seed")
from docx import Document
from owui_client import Api, BASE

api = Api(); api.signin()

def fixture():
    doc = Document()
    doc.add_heading("Note de service — Hôtels", 1)
    doc.add_paragraph("Le plafond hôtel à Paris est de 120 € par nuit.")
    doc.add_paragraph("Les justificatifs sont à envoyer sous 30 jours.")
    path = os.path.join(tempfile.mkdtemp(), "note-hotels.docx")
    doc.save(path)
    return path

def ask(file_id, prompt):
    """Runs one turn in a saved chat (tools only run server-side there); returns (chat id, answer)."""
    chat = api.call("POST", "/api/v1/chats/new", {"chat": {"title": "test-word-tool", "models": ["mistral-small"]}})
    mid = str(uuid.uuid4())
    # tool_ids: the browser sends the tools enabled on the model (meta.toolIds); so do we.
    body = {"chat_id": chat["id"], "id": mid, "model": "mistral-small", "stream": True, "tool_ids": ["word_copy"],
            "files": [{"type": "file", "id": file_id, "name": "note-hotels.docx"}],
            "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(BASE + "/api/chat/completions", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + api.token})
    urllib.request.urlopen(req, timeout=300).read()
    for _ in range(60):
        msg = api.call("GET", "/api/v1/chats/" + chat["id"])["chat"].get("history", {}).get("messages", {}).get(mid)
        if msg and msg.get("done"):
            return chat["id"], msg.get("content", "")
        time.sleep(3)
    return chat["id"], ""

def download(file_id):
    req = urllib.request.Request(BASE + f"/api/v1/files/{file_id}/content", headers={"Authorization": "Bearer " + api.token})
    path = os.path.join(tempfile.mkdtemp(), "copie.docx")
    with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as f:
        f.write(r.read())
    return "\n".join(p.text for p in Document(path).paragraphs)

source, chat_id, answer, copy, original, link = api.upload(fixture())["id"], None, "", "", "", None
try:
    chat_id, answer = ask(source, "Passe le plafond hôtel à 150 € par nuit. Vas-y, modifie sur une copie.")
    link = re.search(r"/api/v1/files/([0-9a-f-]+)/content", answer)
    copy, original = (download(link.group(1)) if link else ""), download(source)
finally:
    # Cleanup even when a call above fails: no test chat or file left behind.
    paths = [f"/api/v1/files/{i}" for i in [source] + ([link.group(1)] if link else [])]
    for path in paths + ([f"/api/v1/chats/{chat_id}"] if chat_id else []):
        api.try_call("DELETE", path)
    print(json.dumps({"answer": answer[:300], "link": bool(link), "copy_ok": "150 €" in copy and "30 jours" in copy,
                      "original_ok": "120 €" in original and "150" not in original}))'

echo "Tests unitaires (python-docx, dans le conteneur openwebui)"
if docker compose exec -T openwebui python3 -m unittest discover -s /seed/tools 2>&1 | tail -n1 | grep -q '^OK'; then
  pass "logique .docx (remplacer, insérer, supprimer, tableaux, propriétaire)"
else
  fail "tests unitaires : docker compose exec openwebui python3 -m unittest discover -s /seed/tools -v"
fi

echo "Bout en bout : mistral-small + .docx joint (fichier fictif)"
result="$(docker compose exec -T openwebui python3 - <<<"$E2E_PY" 2>&1 | tail -n1 || true)"
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$result" "$1" 2>/dev/null || echo "?"; }
[ "$(field link)" = True ] && pass "la réponse donne un lien de téléchargement" \
  || fail "pas de lien dans la réponse : $(field answer)${result:0:300}"
[ "$(field copy_ok)" = True ] && pass "la copie contient la modification (150 €) et le reste (30 jours)" \
  || fail "copie incorrecte ou absente"
[ "$(field original_ok)" = True ] && pass "l'original est inchangé" || fail "l'original a été modifié"
finish

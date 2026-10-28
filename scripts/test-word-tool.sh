#!/usr/bin/env bash
# Checks the "Word copy" tool on the running stack (after import_seed.py):
#   - unit tests of the .docx logic (inside the openwebui container: python-docx)
#   - end to end: a fictitious .docx is attached to a saved chat and mistral-small is asked
#     (1) to "edit a copy": the answer links a new .docx with the change, the original intact;
#     (2) to add a step diagram and a table: the copy holds a picture and a Word table.
# The chats, the uploaded file and the copies are deleted afterwards.
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
    return Document(path)

def text(doc):
    return "\n".join(p.text for p in doc.paragraphs) if doc else ""

def scenario(source, prompt, created):
    """Asks, records what to delete, returns (answer, edited copy or None)."""
    chat_id, answer = ask(source, prompt)
    created.append(f"/api/v1/chats/{chat_id}")
    link = re.search(r"/api/v1/files/([0-9a-f-]+)/content", answer)
    if not link:
        return answer, None
    created.append(f"/api/v1/files/{link.group(1)}")
    return answer, download(link.group(1))

source = api.upload(fixture())["id"]
created, result = [f"/api/v1/files/{source}"], {}
try:
    answer, copy = scenario(source, "Passe le plafond hôtel à 150 € par nuit. Vas-y, modifie sur une copie.", created)
    result.update(answer=answer[:300], link=copy is not None,
                  copy_ok="150 €" in text(copy) and "30 jours" in text(copy))
    answer, copy = scenario(source, "Ajoute au document un visuel des étapes (demande, validation, réservation, "
                            "remboursement) et un tableau des responsables par étape.", created)
    result.update(visual_answer=answer[:300], picture=bool(copy and len(copy.inline_shapes)),
                  table=bool(copy and len(copy.tables)))
    original = text(download(source))
    result["original_ok"] = "120 €" in original and "150" not in original
finally:
    # Cleanup even when a call above fails: no test chat or file left behind.
    for path in created:
        api.try_call("DELETE", path)
    print(json.dumps(result))'

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
[ "$(field picture)" = True ] && pass "« visuel des étapes » : schéma inséré dans la copie" \
  || fail "pas de schéma dans la copie : $(field visual_answer)"
[ "$(field table)" = True ] && pass "« tableau des responsables » : tableau Word inséré" || fail "pas de tableau dans la copie"
[ "$(field original_ok)" = True ] && pass "l'original est inchangé" || fail "l'original a été modifié"
finish

"""Load the seed/ workspace into Open WebUI through its REST API.

Run inside the openwebui container (seed/ is mounted read-only at /seed):
    docker compose exec openwebui python3 /seed/import_seed.py
    docker compose exec openwebui python3 /seed/import_seed.py --supprimer-comptes-demo
Idempotent: existing items (same id / command / name) are updated or skipped.
Stdlib only, so it runs in the stock image.
"""
import glob
import json
import os
import sys
import time

from library import sync_prompts, sync_skills, sync_tools
from owui_client import Api, items

SEED = os.path.dirname(os.path.abspath(__file__))


def read_grants(group_ids, names):
    return [{"principal_type": "group", "principal_id": group_ids[n], "permission": "read"} for n in names]


def audience(access):
    # "standard" content is meant for everyone: standard and advanced groups.
    return ["standard", "avancé"] if access == "standard" else ["avancé"]


def everyone(group_ids):
    return read_grants(group_ids, audience("standard"))


def sync_groups(api, spec):
    existing = {g["name"]: g for g in items(api.call("GET", "/api/v1/groups/"))}
    ids = {}
    for g in spec["groups"]:
        form = {"name": g["name"], "description": g["description"], "permissions": g["permissions"]}
        if g["name"] in existing:
            gid = existing[g["name"]]["id"]
            api.call("POST", f"/api/v1/groups/id/{gid}/update", form)
        else:
            gid = api.call("POST", "/api/v1/groups/create", form)["id"]
        ids[g["name"]] = gid
        print(f"groupe      {g['name']}")
    return ids


MIN_DEMO_PASSWORD = 16


def demo_password():
    """Shared demo password, only when demo accounts are explicitly enabled.

    They are reachable from the Internet in VPS/tunnel mode, hence the opt-in flag and
    the minimum length (online guessing)."""
    if os.environ.get("CREATE_DEMO_USERS", "false").lower() != "true":
        print("comptes     CREATE_DEMO_USERS≠true : comptes de démo non créés")
        return None
    password = os.environ.get("DEMO_USERS_PASSWORD", "")
    if len(password) < MIN_DEMO_PASSWORD:
        print(f"comptes     DEMO_USERS_PASSWORD trop court (< {MIN_DEMO_PASSWORD}) : comptes non créés")
        return None
    return password


def sync_users(api, spec, group_ids):
    password = demo_password()
    if not password:
        return
    users = {u["email"]: u for u in api.call("GET", "/api/v1/users/all").get("users", [])}
    for u in spec["users"]:
        uid = users[u["email"]]["id"] if u["email"] in users else api.call("POST", "/api/v1/auths/add", {
            "name": u["name"], "email": u["email"], "password": password, "role": "user"})["id"]
        for g in u["groups"]:
            api.call("POST", f"/api/v1/groups/id/{group_ids[g]}/users/add", {"user_ids": [uid]})
        print(f"compte      {u['email']} ({', '.join(u['groups'])})")


def remove_demo_users(api, spec):
    users = {u["email"]: u for u in api.call("GET", "/api/v1/users/all").get("users", [])}
    for u in spec["users"]:
        if u["email"] in users:
            api.call("DELETE", f"/api/v1/users/{users[u['email']]['id']}")
            print(f"supprimé    {u['email']}")


def upsert_model(api, form):
    if api.try_call("GET", f"/api/v1/models/model?id={form['id']}"):
        api.call("POST", "/api/v1/models/model/update", form)
    else:
        api.call("POST", "/api/v1/models/create", form)


def grant_base_models(api, spec, group_ids, tool_ids):
    """Restrict each LiteLLM model to the groups allowed to use it; enable the seed tools on it."""
    available = [m["id"] for m in api.call("GET", "/api/models")["data"] if not m.get("info", {}).get("base_model_id")]
    for model_id in available:
        groups = [g for g, models in spec["model_access"].items()
                  if model_id in models or any(p.endswith("*") and model_id.startswith(p[:-1]) for p in models)]
        form = {"id": model_id, "name": model_id, "base_model_id": None, "meta": {"toolIds": tool_ids}, "params": {},
                "access_grants": read_grants(group_ids, groups), "is_active": True}
        upsert_model(api, form)
        print(f"modèle      {model_id} -> {', '.join(groups) or 'admins uniquement'}")


def wait_processed(api, file_id, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = api.call("GET", f"/api/v1/files/{file_id}/process/status").get("status")
        if status in ("completed", "failed"):
            return status
        time.sleep(2)
    return "timeout"


def knowledge_file_names(api, kb_id):
    files = items(api.call("GET", f"/api/v1/knowledge/{kb_id}/files"))
    return {f.get("filename") or (f.get("meta") or {}).get("name") for f in files}


def sync_knowledge(api, name, group_ids):
    """Create the collection if needed, then add any seed document it does not contain yet."""
    existing = [k for k in items(api.call("GET", "/api/v1/knowledge/")) if k["name"] == name]
    kb = existing[0] if existing else api.call("POST", "/api/v1/knowledge/create", {
        "name": name, "description": "Procédures fictives de Société Exemple SAS (démo)",
        "access_grants": everyone(group_ids)})
    present = knowledge_file_names(api, kb["id"])
    for path in sorted(glob.glob(os.path.join(SEED, "knowledge", "*.md"))):
        if os.path.basename(path) in present:
            continue
        file_id = api.upload(path)["id"]
        status = wait_processed(api, file_id)
        api.call("POST", f"/api/v1/knowledge/{kb['id']}/file/add", {"file_id": file_id})
        print(f"document    {os.path.basename(path)} ({status})")
    print(f"knowledge   {name} ({len(present)} document(s) déjà présent(s))")
    return kb


def sync_assistants(api, group_ids):
    for path in sorted(glob.glob(os.path.join(SEED, "models", "*.json"))):
        spec = json.load(open(path, encoding="utf-8"))
        meta = dict(spec["meta"])
        if spec.get("knowledge"):
            kb = sync_knowledge(api, spec["knowledge"], group_ids)
            meta["knowledge"] = [{"type": "collection", "id": kb["id"], "name": kb["name"],
                                  "description": kb.get("description", "")}]
        form = {"id": spec["id"], "name": spec["name"], "base_model_id": spec["base_model_id"],
                "meta": meta, "params": spec["params"], "is_active": True,
                "access_grants": read_grants(group_ids, audience(spec["access"]))}
        upsert_model(api, form)
        print(f"assistant   {spec['name']}")


def main():
    api = Api()
    api.signin()
    spec = json.load(open(os.path.join(SEED, "groups.json"), encoding="utf-8"))
    if "--supprimer-comptes-demo" in sys.argv:
        remove_demo_users(api, spec)
        return
    group_ids = sync_groups(api, spec)
    tool_ids = sync_tools(api, everyone(group_ids))
    sync_users(api, spec, group_ids)
    grant_base_models(api, spec, group_ids, tool_ids)
    sync_assistants(api, group_ids)
    sync_prompts(api, everyone(group_ids))
    sync_skills(api, everyone(group_ids))
    print("Import terminé.")


if __name__ == "__main__":
    main()

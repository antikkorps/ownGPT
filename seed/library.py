"""Workspace items offered to every group: prompts, skills and tools (used by import_seed.py)."""
import glob
import json
import os

from owui_client import items

SEED = os.path.dirname(os.path.abspath(__file__))


def parse_header(text, fence):
    """Splits "<fence> key: value lines <fence> body" (skill front matter, tool docstring)."""
    _, front, body = text.split(fence, 2)
    fields = dict(line.split(":", 1) for line in front.strip().splitlines())
    return {k.strip(): v.strip() for k, v in fields.items()}, body.strip()


def sync_prompts(api, grants):
    commands = {p["command"] for p in items(api.call("GET", "/api/v1/prompts/"))}
    for path in sorted(glob.glob(os.path.join(SEED, "prompts", "*.json"))):
        spec = json.load(open(path, encoding="utf-8"))
        spec["access_grants"] = grants
        if spec["command"] in commands:
            print(f"prompt      /{spec['command']} (déjà présent)")
            continue
        api.call("POST", "/api/v1/prompts/create", spec)
        print(f"prompt      /{spec['command']}")


def sync_skills(api, grants):
    existing = {s["id"] for s in items(api.try_call("GET", "/api/v1/skills/"))}
    for path in sorted(glob.glob(os.path.join(SEED, "skills", "*.md"))):
        fields, body = parse_header(open(path, encoding="utf-8").read(), "---")
        form = {"id": fields["name"], "name": fields["name"], "description": fields["description"],
                "content": body, "is_active": True, "meta": {"tags": []}, "access_grants": grants}
        if fields["name"] in existing:
            api.call("POST", f"/api/v1/skills/id/{fields['name']}/update", form)
        else:
            api.call("POST", "/api/v1/skills/create", form)
        print(f"skill       {fields['name']}")


def tool_paths():
    paths = glob.glob(os.path.join(SEED, "tools", "*.py"))
    return sorted(p for p in paths if not os.path.basename(p).startswith("test_"))


def sync_tools(api, grants):
    """Tools are server-side Python: created here by the admin, only *used* by the groups."""
    existing = {t["id"] for t in items(api.try_call("GET", "/api/v1/tools/"))}
    ids = []
    for path in tool_paths():
        content = open(path, encoding="utf-8").read()
        fields, _ = parse_header(content, '"""')
        tool_id = os.path.splitext(os.path.basename(path))[0]
        form = {"id": tool_id, "name": fields["title"], "content": content, "access_grants": grants,
                "meta": {"description": fields["description"], "manifest": fields}}
        if tool_id in existing:
            api.call("POST", f"/api/v1/tools/id/{tool_id}/update", form)
        else:
            api.call("POST", "/api/v1/tools/create", form)
        print(f"tool        {tool_id}")
        ids.append(tool_id)
    return ids

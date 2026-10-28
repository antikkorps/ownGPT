"""
title: Copie modifiée d'un document Word
description: Lit en entier un .docx joint au chat et en produit une copie modifiée à télécharger (l'original n'est jamais touché).
version: 1.1.0
"""
# Open WebUI loads a Tool from one module: text edits, tables and the step diagram live
# together here instead of being split into files.
import asyncio
import io
import math
import os
import re
import uuid

from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm
from docx.text.paragraph import Paragraph
from PIL import Image, ImageDraw, ImageFont

# Upper bound on the text handed to the model, so a huge file cannot flood the context.
MAX_TEXT = 60000
# Caps on what one call may ask for: the tool runs in Open WebUI's event loop.
MAX_CHANGES, MAX_STEPS, MAX_ROWS, MAX_COLS, MAX_CELL, MAX_LABEL = 30, 12, 50, 8, 300, 120
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
# 3 boxes per row scaled to 16 cm keep the 30 px labels at about 10 pt in the document.
BOX_W, BOX_H, GAP, MARGIN, PER_ROW, FONT_SIZE = 360, 160, 90, 30, 3, 30
# Children of w:tblPr that must come after w:tblBorders (the schema is a strict sequence).
AFTER_BORDERS = ("shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption", "tblDescription")
FILL, LINE, INK = (220, 230, 242), (31, 78, 121), (20, 20, 20)


def norm(text):
    return " ".join(text.split())


def all_paragraphs(doc):
    """Body paragraphs, then table cells: a cadrage note often keeps key facts in tables."""
    yield from doc.paragraphs
    for table in doc.tables:
        for row in table.rows:
            for cell in row.cells:
                yield from cell.paragraphs


def is_heading(paragraph):
    return paragraph.style is not None and paragraph.style.name.lower().startswith(("heading", "titre", "title"))


def document_text(doc):
    lines = [("# " if is_heading(p) else "") + p.text for p in all_paragraphs(doc) if p.text.strip()]
    text = "\n".join(lines)
    if len(text) > MAX_TEXT:
        return text[:MAX_TEXT] + f"\n[… texte tronqué à {MAX_TEXT} caractères]"
    return text


def clean_target(target):
    # Models copy the "# " heading marker shown by document_text into their targets.
    return norm(target).removeprefix("# ")


def find_paragraph(doc, target):
    wanted = clean_target(target)
    return next((p for p in all_paragraphs(doc) if wanted in norm(p.text)), None)


def replace_text(paragraph, old, new):
    """Splices the match out of the runs it covers: the new text takes the formatting where
    the match starts, text around it keeps its own. Spacing may differ from the document."""
    runs = paragraph.runs
    pattern = r"\s+".join(map(re.escape, old.split()))
    match = re.search(pattern, "".join(r.text for r in runs))
    if not match:
        # paragraph.text also covers hyperlinks and fields, which paragraph.runs does not.
        raise ValueError(f"« {old[:80]} » est dans un lien ou un champ : non modifiable")
    start, end = match.span()
    pos, first = 0, True
    for run in runs:
        run_start, pos = pos, pos + len(run.text)
        if pos <= start or run_start >= end:
            continue
        head = run.text[:max(start - run_start, 0)] if first else ""
        tail = run.text[end - run_start:] if end < pos else ""
        run.text = head + (new if first else "") + tail
        first = False


def insert_after(paragraph, text, after):
    # Text inserted under a heading is body text, not another heading.
    style = None if is_heading(paragraph) else paragraph.style
    for line in text.split("\n"):
        new = paragraph_after(after, paragraph._parent)
        if style is not None:
            new.style = style
        new.add_run(line)
        after = new._p
    return after


def delete_paragraph(paragraph):
    p = paragraph._p
    parent = p.getparent()
    # A table cell needs at least one paragraph and a section break lives in its paragraph:
    # removing either corrupts the file, so those are emptied instead.
    if (parent.tag == qn("w:tc") and len(parent.findall(qn("w:p"))) == 1) or p.find(".//" + qn("w:sectPr")) is not None:
        for child in list(p):
            if child.tag != qn("w:pPr"):
                p.remove(child)
        return
    parent.remove(p)


def paragraph_after(element, parent):
    new = OxmlElement("w:p")
    element.addnext(new)
    return Paragraph(new, parent)


def add_borders(table):
    # Explicit borders rather than a named style: the user's template may not define "Table Grid".
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        line = OxmlElement(f"w:{edge}")
        for key, value in (("val", "single"), ("sz", "4"), ("color", "808080")):
            line.set(qn(f"w:{key}"), value)
        borders.append(line)
    tbl_pr = table._tbl.tblPr
    successor = next((c for c in tbl_pr if c.tag.split("}")[1] in AFTER_BORDERS), None)
    if successor is not None:
        successor.addprevious(borders)
    else:
        tbl_pr.append(borders)


def insert_table(doc, paragraph, rows, after):
    table = doc.add_table(rows=len(rows), cols=max(len(r) for r in rows))
    add_borders(table)
    for i, row in enumerate(rows):
        for j, value in enumerate(row):
            run = table.cell(i, j).paragraphs[0].add_run("" if value is None else str(value))
            run.bold = i == 0
    after.addnext(table._tbl)
    # A table cannot end a cell (Word reports the file as corrupt): always close with a paragraph.
    paragraph_after(table._tbl, paragraph._parent)
    return table._tbl


def shorten(text, font, width):
    while text and font.getlength(text + "…") > width:
        text = text[:-1]
    return text.rstrip() + "…"


def wrap(text, font, width, max_lines=3):
    lines = []
    for word in text.split():
        if lines and font.getlength(lines[-1] + " " + word) <= width:
            lines[-1] += " " + word
        else:
            lines.append(word)
    if len(lines) > max_lines:
        lines = lines[:max_lines - 1] + [shorten(" ".join(lines[max_lines - 1:]), font, width)]
    # A single word wider than the box is shortened too.
    return [line if font.getlength(line) <= width else shorten(line, font, width) for line in lines]


def box_origin(i):
    # Snake layout: odd rows run right to left, so every row change is a straight arrow down.
    row, col = divmod(i, PER_ROW)
    col = PER_ROW - 1 - col if row % 2 else col
    return MARGIN + col * (BOX_W + GAP), MARGIN + row * (BOX_H + GAP)


def arrow(draw, start, end):
    draw.line([start, end], fill=LINE, width=5)
    (x0, y0), (x1, y1) = start, end
    angle = math.atan2(y1 - y0, x1 - x0)
    head = [(x1 - 22 * math.cos(angle + d), y1 - 22 * math.sin(angle + d)) for d in (0.45, -0.45)]
    draw.polygon([end] + head, fill=LINE)


def link(draw, a, b):
    (xa, ya), (xb, yb) = box_origin(a), box_origin(b)
    if ya == yb:
        left, right = (xa, xb) if xa < xb else (xb, xa)
        start, end = (left + BOX_W, ya + BOX_H // 2), (right, ya + BOX_H // 2)
        arrow(draw, *((start, end) if xa < xb else (end, start)))
    else:
        arrow(draw, (xa + BOX_W // 2, ya + BOX_H), (xb + BOX_W // 2, yb))


def load_font():
    return ImageFont.truetype(FONT, FONT_SIZE) if os.path.exists(FONT) else ImageFont.load_default(size=FONT_SIZE)


def full_row_width():
    return 2 * MARGIN + PER_ROW * BOX_W + (PER_ROW - 1) * GAP


def draw_steps(steps):
    """PNG of numbered boxes linked by arrows (Pillow only: no charting library in the image)."""
    cols, rows = min(len(steps), PER_ROW), math.ceil(len(steps) / PER_ROW)
    image = Image.new("RGB", (2 * MARGIN + cols * BOX_W + (cols - 1) * GAP,
                              2 * MARGIN + rows * BOX_H + (rows - 1) * GAP), "white")
    draw = ImageDraw.Draw(image)
    font = load_font()
    for i, step in enumerate(steps):
        x, y = box_origin(i)
        draw.rounded_rectangle([x, y, x + BOX_W, y + BOX_H], radius=18, fill=FILL, outline=LINE, width=4)
        text = "\n".join(wrap(f"{i + 1}. {step}", font, BOX_W - 30))
        draw.multiline_text((x + BOX_W / 2, y + BOX_H / 2), text, font=font, fill=INK, anchor="mm", align="center")
        if i:
            link(draw, i - 1, i)
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def insert_diagram(paragraph, steps, after):
    png = draw_steps(steps)
    width = Image.open(io.BytesIO(png)).width
    new = paragraph_after(after, paragraph._parent)
    shape = new.add_run().add_picture(io.BytesIO(png), width=Cm(16 * width / full_row_width()))
    # Alt text: screen readers and Word's accessibility checker.
    shape._inline.docPr.set("descr", "Étapes : " + " → ".join(steps))
    return new._p


# Insertions return the element they added last, so several inserts on one target keep their order.
ACTIONS = {
    "remplacer": lambda d, p, c, a: replace_text(p, c["cible"], c.get("texte") or ""),
    "inserer_apres": lambda d, p, c, a: insert_after(p, c.get("texte") or "", a),
    "supprimer": lambda d, p, c, a: delete_paragraph(p),
    "inserer_tableau": lambda d, p, c, a: insert_table(d, p, c["lignes"], a),
    "inserer_schema_etapes": lambda d, p, c, a: insert_diagram(p, c["etapes"], a),
}


def valid_cell(value):
    return value is None or (isinstance(value, (str, int, float)) and len(str(value)) <= MAX_CELL)


def invalid_visual(change):
    action = change["action"]
    rows, steps = change.get("lignes"), change.get("etapes")
    if action == "inserer_tableau" and not (
            isinstance(rows, list) and 0 < len(rows) <= MAX_ROWS
            and all(isinstance(r, list) and 0 < len(r) <= MAX_COLS and all(map(valid_cell, r)) for r in rows)):
        return (f"inserer_tableau : « lignes » = 1 à {MAX_ROWS} lignes de 1 à {MAX_COLS} cellules "
                f"(texte ou nombre, {MAX_CELL} caractères maximum)")
    if action == "inserer_schema_etapes" and not (
            isinstance(steps, list) and 2 <= len(steps) <= MAX_STEPS
            and all(isinstance(x, str) and 0 < len(x.strip()) <= MAX_LABEL for x in steps)):
        return f"inserer_schema_etapes : « etapes » = 2 à {MAX_STEPS} libellés de {MAX_LABEL} caractères maximum"
    return None


def invalid(change):
    """Why a change from the model cannot be applied, or None."""
    if not isinstance(change, dict):
        return "modification ignorée : objet {action, cible, texte} attendu"
    if change.get("action") not in ACTIONS:
        return f"action inconnue « {change.get('action')} » ({', '.join(ACTIONS)})"
    if not isinstance(change.get("cible"), str) or clean_target(change["cible"]) in ("", "#"):
        return f"{change['action']} : « cible » manquante"
    if not isinstance(change.get("texte") or "", str):
        return f"{change['action']} : « texte » doit être du texte"
    return invalid_visual(change)


def apply_changes(doc, changes):
    """Applies what it can; returns (applied count, failure messages) so the model can retry."""
    if len(changes) > MAX_CHANGES:
        return 0, [f"{len(changes)} modifications demandées : {MAX_CHANGES} maximum par appel"]
    done, failed, last_inserted = 0, [], {}
    for change in changes:
        reason = invalid(change)
        paragraph = None if reason else find_paragraph(doc, change["cible"])
        if not reason and paragraph is None:
            reason = f"{change['action']} : texte introuvable « {change['cible'][:80]} »"
        if not reason:
            try:
                after = last_inserted.get(paragraph._p, paragraph._p)
                inserted = ACTIONS[change["action"]](doc, paragraph, change, after)
                if inserted is not None:
                    last_inserted[paragraph._p] = inserted
                done += 1
            except ValueError as e:
                reason = str(e)
        if reason:
            failed.append(reason)
    return done, failed


def pick_file(files, name):
    docx = [f for f in files or [] if f.get("type") == "file" and f.get("name", "").lower().endswith(".docx")]
    if name:
        docx = [f for f in docx if f.get("name") == name]
    if len(docx) != 1:
        found = ", ".join(f.get("name", "?") for f in docx) or "aucun"
        raise ValueError(f"Préciser un seul fichier .docx joint au chat (trouvé : {found}).")
    return docx[0]["id"]


def check_owner(file_user_id, user):
    # A chat can only reference files, but the id comes from the request: never trust it alone.
    if file_user_id != (user or {}).get("id"):
        raise PermissionError("Ce fichier n'appartient pas à l'utilisateur.")


def copy_name(filename):
    # Upload names are user-chosen: no path parts, nothing that would break the markdown link.
    stem = os.path.splitext(os.path.basename(filename or ""))[0]
    stem = norm(re.sub(r"[\[\]()<>]", " ", stem))
    return f"{stem or 'document'} (modifié).docx"


async def load_attached(files, name, user):
    # Open WebUI internals are imported here so the helpers above stay testable anywhere.
    from open_webui.models.files import Files
    from open_webui.storage.provider import Storage

    record = await Files.get_file_by_id(pick_file(files, name))
    if record is None:
        raise ValueError("Fichier introuvable.")
    check_owner(record.user_id, user)
    if not (record.filename or "").lower().endswith(".docx"):
        raise ValueError("Seuls les fichiers Word .docx sont pris en charge.")
    path = await asyncio.to_thread(Storage.get_file, record.path)
    try:
        return record.filename, Document(path)
    except Exception:
        raise ValueError(f"Document Word illisible : {record.filename}.") from None


async def store_copy(doc, filename, user):
    from open_webui.models.files import FileForm, Files
    from open_webui.storage.provider import Storage

    buffer = io.BytesIO()
    doc.save(buffer)
    file_id, name = str(uuid.uuid4()), copy_name(filename)
    buffer.seek(0)
    tags = {"OpenWebUI-User-Id": user["id"], "OpenWebUI-File-Id": file_id}
    _, path = await asyncio.to_thread(Storage.upload_file, buffer, f"{file_id}_{name}", tags)
    await Files.insert_new_file(user["id"], FileForm(id=file_id, filename=name, path=path, meta={
        "name": name, "size": buffer.getbuffer().nbytes,
        "content_type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}))
    return file_id, name


class Tools:
    async def lire_document_word(self, nom_fichier: str = "", __user__: dict = None, __files__: list = None) -> str:
        """
        Renvoie le texte intégral d'un document Word (.docx) joint au chat, titres marqués par « # ».
        À appeler avant de proposer ou d'appliquer des modifications : sans cet outil, seuls des extraits du document sont visibles.
        :param nom_fichier: Nom du fichier .docx ; vide s'il n'y en a qu'un dans le chat.
        """
        try:
            filename, doc = await load_attached(__files__, nom_fichier, __user__)
        except (ValueError, PermissionError) as e:
            return str(e)
        return f"Contenu intégral de {filename} :\n\n{document_text(doc)}"

    async def modifier_copie_word(self, modifications: list[dict], nom_fichier: str = "", __user__: dict = None, __files__: list = None) -> str:
        """
        Crée une copie modifiée d'un document Word (.docx) joint au chat, avec sa mise en forme ; l'original n'est pas modifié. Sait modifier le texte, insérer un tableau Word et un schéma des étapes (image).
        Utiliser cet outil dès que l'utilisateur demande de modifier, corriger, compléter ou illustrer le document, ou valide des propositions (« ajoute-les », « vas-y ») : ne jamais donner à la place du texte à copier-coller, ni répondre qu'il est impossible de modifier un fichier. Un « visuel » ou « graphique » = un tableau ou un schéma des étapes.
        :param modifications: Liste d'objets, chacun avec "action" et "cible" (texte exact présent dans le document, après lequel insérer ou à modifier) : {"action": "remplacer", "cible", "texte": nouveau texte} ; {"action": "inserer_apres", "cible", "texte": une ligne par paragraphe} ; {"action": "supprimer", "cible"} ; {"action": "inserer_tableau", "cible", "lignes": [["en-tête 1", "en-tête 2"], ["valeur", "valeur"]]} ; {"action": "inserer_schema_etapes", "cible", "etapes": ["étape 1", "étape 2", …] (2 à 12, libellés courts)}.
        :param nom_fichier: Nom du fichier .docx ; vide s'il n'y en a qu'un dans le chat.
        """
        if not isinstance(modifications, list):
            return "« modifications » doit être une liste d'objets {action, cible, texte}."
        try:
            filename, doc = await load_attached(__files__, nom_fichier, __user__)
        except (ValueError, PermissionError) as e:
            return str(e)
        done, failed = apply_changes(doc, modifications)
        if not done:
            return "Aucune modification appliquée : " + " ; ".join(failed)
        file_id, name = await store_copy(doc, filename, __user__)
        report = f" Non appliquées : {' ; '.join(failed)}." if failed else ""
        return (f"Copie créée avec {done} modification(s).{report} Donne ce lien à l'utilisateur tel quel : "
                f"[Télécharger {name}](/api/v1/files/{file_id}/content?attachment=true)")

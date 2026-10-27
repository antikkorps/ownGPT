# Presidio analyzer with French NLP (the official image only ships English).
# Pinned by digest: a re-pushed tag cannot change what we build on.
FROM ghcr.io/data-privacy-stack/presidio-analyzer:2.2.366@sha256:036d2f9b3c274fb36497383acef8f2d5aea528a014801c2c3040fb067990c79c

# fr_core_news_lg by default (~1.2 GB RAM): measured 1/20 false PERSON on everyday French
# prompts vs 3/20 for fr_core_news_md (~500 MB RAM, imperative verbs like « Rédige » taken for names).
ARG SPACY_MODEL=fr_core_news_lg
ARG SPACY_MODEL_VERSION=3.8.0

USER root
# The model wheel is installed from its release URL and checked against a pinned sha256
# (pip --require-hashes), instead of `spacy download` which trusts whatever is served.
# The English model is removed: it is never loaded and weighs ~600 MB.
COPY spacy-models.sha256 /tmp/spacy-models.sha256
RUN set -eu; \
    hash="$(awk -v m="${SPACY_MODEL}-${SPACY_MODEL_VERSION}" '$2 == m { print $1 }' /tmp/spacy-models.sha256)"; \
    [ -n "$hash" ] || { echo "no pinned sha256 for ${SPACY_MODEL}-${SPACY_MODEL_VERSION}" >&2; exit 1; }; \
    url="https://github.com/explosion/spacy-models/releases/download/${SPACY_MODEL}-${SPACY_MODEL_VERSION}/${SPACY_MODEL}-${SPACY_MODEL_VERSION}-py3-none-any.whl"; \
    echo "${SPACY_MODEL} @ ${url} --hash=sha256:${hash}" > /tmp/model.txt; \
    pip install --no-deps --require-hashes -r /tmp/model.txt; \
    pip uninstall -y en_core_web_lg; \
    rm -f /tmp/model.txt /tmp/spacy-models.sha256; \
    python -c "import spacy; spacy.load('${SPACY_MODEL}')"

# Custom FR_NIR recognizer (regex + mod-97 key): registered as a predefined recognizer
# so the YAML registry can load it like the built-in ones.
COPY --chown=1001:1001 recognizers/fr_nir_recognizer.py \
     /app/presidio_analyzer/predefined_recognizers/country_specific/france/fr_nir_recognizer.py
RUN touch /app/presidio_analyzer/predefined_recognizers/country_specific/france/__init__.py \
    && echo "from .country_specific.france.fr_nir_recognizer import FrNirRecognizer  # noqa: E402" \
       >> /app/presidio_analyzer/predefined_recognizers/__init__.py

COPY --chown=1001:1001 conf/ /app/presidio_analyzer/conf/fr/
RUN sed -i "s/model_name: .*/model_name: ${SPACY_MODEL}/" /app/presidio_analyzer/conf/fr/nlp-fr.yaml

ENV NLP_CONF_FILE=presidio_analyzer/conf/fr/nlp-fr.yaml \
    ANALYZER_CONF_FILE=presidio_analyzer/conf/fr/analyzer-fr.yaml \
    RECOGNIZER_REGISTRY_CONF_FILE=presidio_analyzer/conf/fr/recognizers-fr.yaml

USER 1001

# Presidio analyzer with French NLP (the official image only ships English).
ARG PRESIDIO_VERSION=2.2.366
FROM ghcr.io/data-privacy-stack/presidio-analyzer:${PRESIDIO_VERSION}

# fr_core_news_lg by default (~1.2 GB RAM): measured 1/20 false PERSON on everyday French
# prompts vs 3/20 for fr_core_news_md (~500 MB RAM, imperative verbs like « Rédige » taken for names).
ARG SPACY_MODEL=fr_core_news_lg

USER root
# spacy download resolves the model release compatible with the installed spaCy.
# The English model is removed: it is never loaded and weighs ~600 MB.
RUN python -m spacy download "${SPACY_MODEL}" \
    && pip uninstall -y en_core_web_lg \
    && python -c "import spacy; spacy.load('${SPACY_MODEL}')"

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

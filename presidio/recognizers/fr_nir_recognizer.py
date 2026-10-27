"""French social security number (NIR) recognizer with control-key validation.

A regex alone also matches unrelated 13-15 digit references (order numbers, file
ids) and would block them. The 2-digit key (97 - number mod 97) rejects almost all
of them; a NIR written without its key is only reported when context words
(« sécurité sociale », « NIR »…) are nearby.
"""
from typing import List, Optional

from presidio_analyzer import EntityRecognizer, Pattern, PatternRecognizer

# Sex (1-2; 3-4 people being registered; 7-8 temporary), birth year, month (01-12, or
# 20-99 for unknown/special cases), department (2 digits, or 2A/2B for Corsica),
# commune (3), order number (3), optional key (2).
_BODY = r"[1-478]\s?\d{2}\s?(?:0[1-9]|1[0-2]|[2-9]\d)\s?(?:\d{2}|2[AB])\s?\d{3}\s?\d{3}"


class FrNirRecognizer(PatternRecognizer):
    COUNTRY_CODE = "fr"

    PATTERNS = [
        Pattern("nir_avec_cle", rf"\b{_BODY}\s?\d{{2}}\b", 0.8),
        Pattern("nir_sans_cle", rf"\b{_BODY}\b", 0.1),
    ]
    CONTEXT = ["sécurité sociale", "securite sociale", "sécu", "nir", "insee", "carte vitale", "assuré"]

    def __init__(
        self,
        patterns: Optional[List[Pattern]] = None,
        context: Optional[List[str]] = None,
        supported_language: str = "fr",
        supported_entity: str = "FR_NIR",
        name: Optional[str] = None,
    ):
        super().__init__(
            supported_entity=supported_entity,
            patterns=patterns or self.PATTERNS,
            context=context or self.CONTEXT,
            supported_language=supported_language,
            name=name,
        )

    def validate_result(self, pattern_text: str) -> Optional[bool]:
        digits = EntityRecognizer.sanitize_value(pattern_text, [(" ", "")]).upper()
        if len(digits) == 13:
            return None  # no key to check: keep the low base score, context decides
        body, key = digits[:13], int(digits[13:])
        # Corsica: 2A and 2B are replaced by 19 and 18 for the key computation.
        body = body.replace("2A", "19").replace("2B", "18")
        return key == 97 - int(body) % 97

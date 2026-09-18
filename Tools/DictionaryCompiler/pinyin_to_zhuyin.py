from __future__ import annotations

from dataclasses import dataclass

TONE_DIGITS = "12345"

INITIALS = {
    "b": "ㄅ",
    "p": "ㄆ",
    "m": "ㄇ",
    "f": "ㄈ",
    "d": "ㄉ",
    "t": "ㄊ",
    "n": "ㄋ",
    "l": "ㄌ",
    "g": "ㄍ",
    "k": "ㄎ",
    "h": "ㄏ",
    "j": "ㄐ",
    "q": "ㄑ",
    "x": "ㄒ",
    "zh": "ㄓ",
    "ch": "ㄔ",
    "sh": "ㄕ",
    "r": "ㄖ",
    "z": "ㄗ",
    "c": "ㄘ",
    "s": "ㄙ",
}

FINALS = {
    "a": "ㄚ",
    "o": "ㄛ",
    "e": "ㄜ",
    "eh": "ㄝ",
    "ai": "ㄞ",
    "ei": "ㄟ",
    "ao": "ㄠ",
    "ou": "ㄡ",
    "an": "ㄢ",
    "en": "ㄣ",
    "ang": "ㄤ",
    "eng": "ㄥ",
    "er": "ㄦ",
    "i": "ㄧ",
    "ia": "ㄧㄚ",
    "io": "ㄧㄛ",
    "ie": "ㄧㄝ",
    "iai": "ㄧㄞ",
    "iao": "ㄧㄠ",
    "iu": "ㄧㄡ",
    "ian": "ㄧㄢ",
    "in": "ㄧㄣ",
    "iang": "ㄧㄤ",
    "ing": "ㄧㄥ",
    "iong": "ㄩㄥ",
    "u": "ㄨ",
    "ua": "ㄨㄚ",
    "uo": "ㄨㄛ",
    "uai": "ㄨㄞ",
    "ui": "ㄨㄟ",
    "uan": "ㄨㄢ",
    "un": "ㄨㄣ",
    "uang": "ㄨㄤ",
    "ueng": "ㄨㄥ",
    "ong": "ㄨㄥ",
    "v": "ㄩ",
    "ve": "ㄩㄝ",
    "van": "ㄩㄢ",
    "vn": "ㄩㄣ",
}

ZERO_INITIAL = {
    "yi": "i",
    "ya": "ia",
    "yao": "iao",
    "ye": "ie",
    "you": "iu",
    "yan": "ian",
    "yin": "in",
    "yang": "iang",
    "ying": "ing",
    "yong": "iong",
    "yu": "v",
    "yue": "ve",
    "yuan": "van",
    "yun": "vn",
    "wu": "u",
    "wa": "ua",
    "wo": "uo",
    "wai": "uai",
    "wei": "ui",
    "wan": "uan",
    "wen": "un",
    "wang": "uang",
    "weng": "ueng",
    "yo": "io",
    "yai": "iai",
    "wong": "ueng",
}

SYLLABIC_OVERRIDES = {
    "r": "ㄦ",
    "m": "ㄇ",
    "n": "ㄋ",
    "ng": "ㄫ",
}

APICAL_INITIALS = frozenset({"zh", "ch", "sh", "r", "z", "c", "s"})
LABIALS_AND_DENTALS = "bpmfdtnlgkhjqxrzcs"
JQX_HOMORGANIC = {"u": "v", "ue": "ve", "uan": "van", "un": "vn"}


class PinyinError(ValueError):
    pass


@dataclass(frozen=True)
class ZhuyinSyllable:
    base: str
    tone: int


def strip_tone(syllable: str) -> str:
    text = syllable.strip()
    if text and text[-1] in TONE_DIGITS:
        return text[:-1]
    return text


def _split_initial(body: str) -> tuple[str | None, str]:
    for initial in ("zh", "ch", "sh"):
        if body.startswith(initial):
            return initial, body[len(initial):]
    if body and body[0] in LABIALS_AND_DENTALS:
        return body[0], body[1:]
    return None, body


def convert_syllable(raw: str) -> ZhuyinSyllable:
    if not isinstance(raw, str):
        raise PinyinError(f"invalid pinyin syllable {raw!r}")
    text = raw.strip().lower()
    if not text:
        raise PinyinError("empty pinyin syllable")
    tone_digit = text[-1]
    if tone_digit not in TONE_DIGITS:
        raise PinyinError(f"pinyin syllable {raw!r} is missing a tone digit")
    tone = int(tone_digit)
    body = text[:-1].replace("u:", "v").replace("ü", "v")
    if not body or not body.isascii() or not body.isalpha():
        raise PinyinError(f"pinyin syllable {raw!r} has an invalid base")
    if body in SYLLABIC_OVERRIDES:
        return ZhuyinSyllable(SYLLABIC_OVERRIDES[body], tone)
    if body[0] in "yw":
        mapped = ZERO_INITIAL.get(body)
        if mapped is None:
            raise PinyinError(f"unknown zero-initial pinyin syllable {raw!r}")
        body = mapped
    initial, final = _split_initial(body)
    if initial in ("j", "q", "x") and final in JQX_HOMORGANIC:
        final = JQX_HOMORGANIC[final]
    if final == "i" and initial in APICAL_INITIALS:
        final = ""
    if not final:
        if initial not in APICAL_INITIALS:
            raise PinyinError(f"unknown pinyin syllable {raw!r}")
        base = INITIALS[initial]
    else:
        if initial is None:
            base = FINALS.get(final)
        else:
            final_base = FINALS.get(final)
            base = None if final_base is None else INITIALS[initial] + final_base
        if base is None:
            raise PinyinError(f"unknown pinyin syllable {raw!r}")
    return ZhuyinSyllable(base, tone)

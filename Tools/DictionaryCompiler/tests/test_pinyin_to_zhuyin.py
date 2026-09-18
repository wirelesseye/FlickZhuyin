import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pinyin_to_zhuyin import (  # noqa: E402
    PinyinError,
    convert_syllable,
    strip_tone,
)


class PinyinToZhuyinTests(unittest.TestCase):
    def assert_conversion(self, pinyin, base, tone):
        result = convert_syllable(pinyin)
        self.assertEqual((result.base, result.tone), (base, tone), pinyin)

    def test_retroflex_and_dental_apical(self):
        self.assert_conversion("zhi1", "ㄓ", 1)
        self.assert_conversion("chi2", "ㄔ", 2)
        self.assert_conversion("shi3", "ㄕ", 3)
        self.assert_conversion("ri4", "ㄖ", 4)
        self.assert_conversion("zi1", "ㄗ", 1)
        self.assert_conversion("ci2", "ㄘ", 2)
        self.assert_conversion("si4", "ㄙ", 4)

    def test_zero_initial_y_and_w(self):
        self.assert_conversion("yi1", "ㄧ", 1)
        self.assert_conversion("ya1", "ㄧㄚ", 1)
        self.assert_conversion("wu2", "ㄨ", 2)
        self.assert_conversion("weng1", "ㄨㄥ", 1)
        self.assert_conversion("yu3", "ㄩ", 3)
        self.assert_conversion("yuan2", "ㄩㄢ", 2)
        self.assert_conversion("yun2", "ㄩㄣ", 2)
        self.assert_conversion("yue4", "ㄩㄝ", 4)
        self.assert_conversion("yong3", "ㄩㄥ", 3)

    def test_jqx_uses_u_mlaut(self):
        self.assert_conversion("ju1", "ㄐㄩ", 1)
        self.assert_conversion("qu2", "ㄑㄩ", 2)
        self.assert_conversion("xu3", "ㄒㄩ", 3)
        self.assert_conversion("jue2", "ㄐㄩㄝ", 2)
        self.assert_conversion("quan2", "ㄑㄩㄢ", 2)
        self.assert_conversion("xun4", "ㄒㄩㄣ", 4)
        self.assert_conversion("jiong3", "ㄐㄩㄥ", 3)

    def test_umlaut_spellings_normalize(self):
        self.assert_conversion("lü4", "ㄌㄩ", 4)
        self.assert_conversion("nu:3", "ㄋㄩ", 3)
        self.assert_conversion("lv4", "ㄌㄩ", 4)
        self.assert_conversion("nve4", "ㄋㄩㄝ", 4)
        self.assert_conversion("lvan2", "ㄌㄩㄢ", 2)

    def test_all_tones(self):
        for digit in "12345":
            result = convert_syllable(f"ma{digit}")
            self.assertEqual((result.base, result.tone), ("ㄇㄚ", int(digit)))

    def test_neutral_r(self):
        self.assert_conversion("r5", "ㄦ", 5)

    def test_corpus_specific_syllables(self):
        self.assert_conversion("eh1", "ㄝ", 1)
        self.assert_conversion("cei4", "ㄘㄟ", 4)
        self.assert_conversion("den4", "ㄉㄣ", 4)
        self.assert_conversion("din4", "ㄉㄧㄣ", 4)
        self.assert_conversion("fiao4", "ㄈㄧㄠ", 4)
        self.assert_conversion("kei1", "ㄎㄟ", 1)
        self.assert_conversion("nia1", "ㄋㄧㄚ", 1)
        self.assert_conversion("rua2", "ㄖㄨㄚ", 2)
        self.assert_conversion("tei1", "ㄊㄟ", 1)
        self.assert_conversion("wong4", "ㄨㄥ", 4)
        self.assert_conversion("yai2", "ㄧㄞ", 2)
        self.assert_conversion("yo1", "ㄧㄛ", 1)
        self.assert_conversion("nun2", "ㄋㄨㄣ", 2)

    def test_unknown_syllables_fail(self):
        for pinyin in ("", "a", "a0", "a6", "zz1", "yuo1", "zhuang", "b1"):
            with self.subTest(pinyin=pinyin):
                with self.assertRaises(PinyinError):
                    convert_syllable(pinyin)

    def test_strip_tone(self):
        self.assertEqual(strip_tone("zhong1"), "zhong")
        self.assertEqual(strip_tone("ma5"), "ma")
        self.assertEqual(strip_tone("r5"), "r")


if __name__ == "__main__":
    unittest.main()

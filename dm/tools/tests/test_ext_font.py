"""The generated system-extension stand-in must have a drawable glyph for private-use symbols."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
LETTERS = Path('/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf')


@unittest.skipUnless(LETTERS.is_file() and importlib.util.find_spec('fontTools'), 'macOS font and fontTools required')
class ExtensionFont(unittest.TestCase):
    def test_private_use_coverage_preserves_button_shapes(self):
        from fontTools.ttLib import TTFont
        spec = importlib.util.spec_from_file_location('make_ext_font', REPO / 'dm/tools/make_ext_font.py')
        assert spec is not None and spec.loader is not None
        maker = importlib.util.module_from_spec(spec); spec.loader.exec_module(maker)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'extension.ttf'; maker.build(out, str(LETTERS))
            with TTFont(out) as font:
                cmap = font.getBestCmap()
                self.assertTrue(all(c in cmap for c in range(0xe000, 0xf900)))
                fallback = cmap[0xe06b]
                self.assertNotEqual(font.getGlyphID(fallback), 0)
                self.assertGreater(font['glyf'][fallback].numberOfContours, 0)
                self.assertGreater(font['hmtx'][fallback][0], 0)
                self.assertEqual(cmap[0xe0a0], 'btnA')
                self.assertEqual(cmap[0xe0e0], 'btnA')
                self.assertNotEqual(cmap[0xe0a0], fallback)


if __name__ == '__main__': unittest.main()

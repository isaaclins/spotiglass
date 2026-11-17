"""Release archives from both sides of the rename must keep their own tags."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'release uses BSD sed')
class RenameRelease(unittest.TestCase):
    def test_mixed_brand_archives_keep_their_filename_and_matching_tag(self):
        script = (ROOT / 'scripts/sparkle-release.sh').read_text()
        function = script[script.index('rewrite_appcast_download_urls() {'):]
        function = function[:function.index('\n}\n') + 3]
        with tempfile.TemporaryDirectory() as folder:
            feed = Path(folder) / 'appcast.xml'
            feed.write_text('''<rss><channel>
<enclosure url="https://github.com/isaaclins/spotiglass/releases/download/v0.8.45/Spotiglass-0.8.44.zip"/>
<enclosure url="https://github.com/isaaclins/spotiglass/releases/download/v0.8.45/Wax-0.8.45.zip"/>
</channel></rss>''')
            result = subprocess.run(['/bin/bash', '-c',
                'set -euo pipefail\n' + function + '\nrewrite_appcast_download_urls "$1"',
                'test', str(feed)], text=True, capture_output=True,
                env=dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin'))
            self.assertEqual(result.returncode, 0, result.stderr)
            text = feed.read_text()
            self.assertIn('/v0.8.44/Spotiglass-0.8.44.zip', text)
            self.assertIn('/v0.8.45/Wax-0.8.45.zip', text)

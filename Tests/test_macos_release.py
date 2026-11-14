import importlib.util
import pathlib
import unittest
import hashlib
import json
import tempfile
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / 'scripts/publish-macos-release.py'
spec = importlib.util.spec_from_file_location('macos_release', path)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class MacReleaseTests(unittest.TestCase):
    def record(self, identity, **changes):
        row = dict(id=identity, draft=False, prerelease=True, tag_name='v1.1.1-beta.1', body=release.MARKER,
                   assets=[dict(name='SamsungCloudNotes-1.1.1-beta.1-macOS.zip')])
        row.update(changes)
        return row

    def test_only_old_marked_mac_previews_are_retired(self):
        rows = [self.record(1), self.record(2), self.record(3, draft=True), self.record(4, prerelease=False),
                self.record(5, body='Another app'), self.record(6, assets=[dict(name='Android.apk')])]
        self.assertEqual([x['id'] for x in release.preview_records(rows, 2)], [1])

    def test_numeric_preview_order_and_final_order(self):
        self.assertGreater(release.version_key('1.2.0-beta.10'), release.version_key('1.2.0-beta.9'))
        self.assertGreater(release.version_key('1.2.0'), release.version_key('1.2.0-rc.2'))

    def test_unsupported_tags_never_enter_cleanup(self):
        self.assertEqual(release.preview_records([self.record(1, tag_name='preview'), self.record(2, tag_name='v1.1.1-beta/1')], -1), [])

    def test_cleanup_keeps_git_tags(self):
        # Publication removes release records only; it never issues a Git ref/tag deletion.
        text = path.read_text()
        self.assertNotIn('/git/refs/tags', text)
        self.assertNotIn('release", "delete', text)

    def simulate_publication(self, corrupt=False):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            name = 'SamsungCloudNotes-1.1.1-beta.2-macOS.zip'
            payload = b'fixture-package'
            (directory/name).write_bytes(payload)
            (directory/'SHA256SUMS.txt').write_text('fixture checksum')
            manifest = dict(app='samsung-cloud-notes-macos',version='1.1.1-beta.2',tag='v1.1.1-beta.2',asset=name,sha256=hashlib.sha256(payload).hexdigest())
            (directory/'macos-release.json').write_text(json.dumps(manifest))
            old = self.record(1)
            fresh = self.record(20, draft=True, tag_name='v1.1.1-beta.2',assets=[],html_url='https://github.com/owner/notes/releases/tag/v1.1.1-beta.2')
            events, bodies = [], {}

            def fake_api(path, method='GET', body=None, binary=False):
                if binary:
                    events.append('verify')
                    return b'corrupt' if corrupt else bodies[int(path.rsplit('/',1)[1])]
                if path.endswith('/git/refs'):
                    return dict(object=dict(type='commit',sha='a'*40))
                if path.endswith('/releases?per_page=100'):
                    return [old] if fresh['draft'] else [fresh,old]
                if path.endswith('/releases') and method == 'POST':
                    return fresh
                if path.endswith('/releases/20') and method == 'PATCH':
                    events.append('publish'); fresh['draft']=False; return fresh
                if path.endswith('/releases/20'):
                    return fresh
                if method == 'DELETE':
                    events.append('retire'); return None
                raise AssertionError((path,method))

            def fake_upload(command, **kwargs):
                file = pathlib.Path(command[4]); data = file.read_bytes(); identity = 100+len(bodies)
                bodies[identity]=data
                fresh['assets'].append(dict(id=identity,name=file.name,size=len(data),digest='sha256:'+hashlib.sha256(data).hexdigest()))

            with patch.object(release,'api',fake_api), patch.object(release.subprocess,'run',fake_upload):
                if corrupt:
                    with self.assertRaises(ValueError):
                        release.publish('owner/notes','preview','a'*40,directory)
                    self.assertNotIn('publish',events); self.assertNotIn('retire',events)
                else:
                    release.publish('owner/notes','preview','a'*40,directory)
                    self.assertEqual(events,['verify','verify','verify','publish','retire'])

    def test_preview_publication_verifies_before_retiring(self):
        self.simulate_publication()

    def test_bad_uploaded_asset_preserves_previous_preview(self):
        self.simulate_publication(corrupt=True)


if __name__ == '__main__':
    unittest.main()

"""Validate the byte-level dependency contract against published-image layouts."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/robot_image_contract.py'
SPEC = importlib.util.spec_from_file_location('contract', SCRIPT)
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / 'checkout'
        self.baked = Path(self.tmp.name) / 'baked'
        self.docker = Path(self.tmp.name) / 'docker'
        local_docker = self.source / 'isaac_ros_common/docker'
        local_docker.mkdir(parents=True)
        (local_docker / 'Dockerfile.thornbots').write_text('baseline')
        (local_docker / 'config').write_text('baseline')
        shutil.copytree(local_docker, self.docker)
        for directory in CONTRACT.PACKAGES:
            for root in [self.source, self.baked]:
                (root / directory).mkdir(parents=True)
                (root / directory / 'package.xml').write_text('<package/>')

    def errors(self):
        return CONTRACT.mismatches(self.source, self.docker, self.baked)

    def test_source_and_script_edits_do_not_require_pull(self):
        (self.source / 'thornbots_pkg/node.cpp').write_text('new code')
        (self.source / 'isaac_ros_common/helper.sh').write_text('new helper')
        (self.source / 'isaac_ros_common/docker/README.md').write_text('updated docs')
        (self.docker / 'notes.markdown').write_text('old docs')
        self.assertEqual(self.errors(), [])

    def test_every_manifest_is_compared_and_missing_manifest_rejected(self):
        for directory in CONTRACT.PACKAGES:
            manifest = self.baked / directory / 'package.xml'
            manifest.unlink()
            self.assertEqual(self.errors(), [f'{directory}/package.xml'])
            manifest.write_text('<package/>')
            manifest.write_text('<changed/>')
            self.assertEqual(self.errors(), [f'{directory}/package.xml'])
            manifest.write_text('<package/>')

    def test_entire_docker_tree_includes_dockerfile_config_and_extra_files(self):
        for name in ['Dockerfile.thornbots', 'config', 'new-file']:
            path = self.docker / name
            path.write_text('different')
            self.assertTrue(self.errors())
            if name == 'new-file':
                path.unlink()
            else:
                path.write_text('baseline')
        (self.docker / 'config').unlink()
        (self.docker / 'config').symlink_to('Dockerfile.thornbots')
        self.assertTrue(self.errors())

"""Signing credential lifecycle and artifact provenance, using synthetic fixtures only.
No platform Security API, native signing tool, real key or network is invoked.
"""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import textwrap
import unittest
import urllib.error
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('signing', REPO / 'scripts/mac-signing-keychain.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class FakeSecurity:
    def __init__(self, import_failure=False, restore_failure=False):
        self.calls=[]
        self.import_failure=import_failure
        self.restore_failure=restore_failure
    def search_paths(self):
        return ['/fixture/login.keychain-db']
    def create_and_import(self,path,data,password):
        assert data == b'FAKE-P12-NOT-A-KEY' and password == 'fixture-secret-password'
        path.write_bytes(b'not-a-real-keychain')
        self.calls.append('import')
        if self.import_failure:
            raise mod.SigningError('import fixture failed')
    def set_search_paths(self, paths):
        self.calls.append(('search', paths))
        if self.restore_failure and paths==self.search_paths():
            raise mod.SigningError('restore fixture failed')
    def delete(self,path):
        self.calls.append('delete')
        path.unlink()

def native_identity(argv, **kwargs):
    assert argv[:5] == ['/usr/bin/security','find-identity','-v','-p','basic']
    assert not any('fixture-secret' in x for x in argv)
    assert not any(k.startswith(('MACOS_SIGNING_','ASC_')) for k in kwargs['env'])
    return subprocess.CompletedProcess(argv,0,'  1) '+ 'A'*40 +' "Developer ID Application: Fixture (TEAMFIXTURE)"\n  2) '+ 'B'*40 +' "Developer ID Installer: Fixture (TEAMFIXTURE)"\n','')

class KeychainTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.directory=self.root/'private'
        self.env={'MACOS_SIGNING_CERT_P12_BASE64':base64.b64encode(b'FAKE-P12-NOT-A-KEY').decode(),
                  'MACOS_SIGNING_CERT_PASSWORD':'fixture-secret-password',
                  'ASC_PRIVATE_KEY_P8':'-----BEGIN PRIVATE KEY-----\nfixture-secret-not-a-key\n-----END PRIVATE KEY-----',
                  'GITHUB_ENV':str(self.root/'environment')}
    def tearDown(self): self.tmp.cleanup()
    def initialize(self, security):
        with patch.dict(os.environ,self.env,clear=True), patch.object(mod.subprocess,'run',side_effect=native_identity), contextlib.redirect_stdout(io.StringIO()):
            mod.initialize(self.directory,security)
    def test_success_private_modes_hash_only_env_and_cleanup(self):
        security=FakeSecurity()
        self.initialize(security)
        if os.name != 'nt':
            self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode),0o700)
            for name in ['state.json','AuthKey.p8']:
                self.assertEqual(stat.S_IMODE((self.directory/name).stat().st_mode),0o600)
        exported=(self.root/'environment').read_text()
        self.assertIn('DEVELOPER_ID_APPLICATION='+'A'*40,exported)
        self.assertIn('DEVELOPER_ID_INSTALLER='+'B'*40,exported)
        self.assertNotIn('fixture-secret',exported)
        self.assertNotIn('Developer ID Application:',exported)
        mod.cleanup(self.directory,security)
        self.assertFalse(self.directory.exists())
        self.assertEqual(security.calls[-2:],[('search',security.search_paths()),'delete'])
        mod.cleanup(self.directory,security)
    def test_partial_import_failure_restores_and_deletes(self):
        security=FakeSecurity(import_failure=True)
        with self.assertRaises(mod.SigningError): self.initialize(security)
        self.assertFalse(self.directory.exists())
        self.assertEqual(security.calls[-2:],[('search',security.search_paths()),'delete'])
    def test_restore_failure_still_deletes_keychain_and_private_key(self):
        security=FakeSecurity()
        self.initialize(security)
        security.restore_failure=True
        with self.assertRaises(mod.SigningError): mod.cleanup(self.directory,security)
        self.assertFalse((self.directory/'AuthKey.p8').exists())
        self.assertFalse((self.directory/'signing.keychain-db').exists())
        security.restore_failure=False
        mod.cleanup(self.directory,security)
        self.assertFalse(self.directory.exists())
    def test_cleanup_preserves_a_concurrently_added_keychain(self):
        security=FakeSecurity()
        self.initialize(security)
        with patch.object(security,'search_paths',return_value=['/fixture/login.keychain-db',
                          str(self.directory/'signing.keychain-db'),'/fixture/new.keychain-db']):
            mod.cleanup(self.directory,security)
        self.assertEqual(security.calls[-2],('search',['/fixture/login.keychain-db','/fixture/new.keychain-db']))
    def test_invalid_secret_rejected_before_mutation(self):
        for value in ['', '$NOT-BASE64']:
            self.env['MACOS_SIGNING_CERT_P12_BASE64']=value
            security=FakeSecurity()
            with self.assertRaises(mod.SigningError): self.initialize(security)
            self.assertEqual(security.calls,[])
            self.assertFalse(self.directory.exists())
    def test_missing_installer_cleans_partial_import(self):
        security=FakeSecurity()
        with patch.dict(os.environ,self.env,clear=True), patch.object(mod,'identities',side_effect=mod.SigningError('missing installer')):
            with self.assertRaises(mod.SigningError): mod.initialize(self.directory,security)
        self.assertFalse(self.directory.exists())
    def test_existing_directory_is_not_overwritten(self):
        self.directory.mkdir()
        (self.directory/'keep').write_text('keep')
        with self.assertRaises(FileExistsError): self.initialize(FakeSecurity())
        self.assertEqual((self.directory/'keep').read_text(),'keep')
    @unittest.skipIf(os.name == 'nt', 'Creating symlinks can require Windows elevation')
    def test_cleanup_rejects_symlink(self):
        (self.root/'real').mkdir()
        self.directory.symlink_to(self.root/'real',target_is_directory=True)
        with self.assertRaises(mod.SigningError): mod.cleanup(self.directory,FakeSecurity())
        self.assertTrue((self.root/'real').exists())

workflow = (REPO / '.github/workflows/mac-notarize.yml').read_text()
# Extract the embedded verifier without adding a YAML dependency to the portable suite.
match = re.search(r"^          python3 - <<'PY'\n(.*?)^          PY$", workflow, re.MULTILINE | re.DOTALL)
if not match:
    raise AssertionError('Missing embedded artifact verifier')
script = textwrap.dedent(match[1])
SHA='a'*40
class Response(io.BytesIO): pass
class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.run={'id':123,'status':'completed','conclusion':'success','repository':{'id':7,'full_name':'fixture/fork'},'head_repository':{'id':7,'full_name':'fixture/fork'},'event':'workflow_dispatch','head_sha':SHA,'workflow_id':9}
        self.workflow={'path':'.github/workflows/build.yml'}
        self.comparison={'status':'ahead','merge_base_commit':{'sha':SHA}}
        self.artifact={'id':42,'name':'TI-Revive-mac','expired':False,'workflow_run':{'id':123,'head_sha':SHA,'repository_id':7,'head_repository_id':7},'size_in_bytes':100}
        self.entries=[('TI-Revive-0.8.41-mac.zip',b'fixture-package',None)]
        self.bad_digest=False
        self.env={'GITHUB_REPOSITORY':'fixture/fork','BUILD_RUN_ID':'123','SOURCE_SHA':SHA,'GITHUB_API_URL':'https://api.github.test','GH_TOKEN':'fixture-secret-token','NOTARIZE_OUT':str(self.root/'out'),'RUNNER_TEMP':str(self.root),'GITHUB_SHA':'b'*40,'GITHUB_ENV':str(self.root/'environment')}
    def tearDown(self):self.tmp.cleanup()
    def execute(self):
        blob=io.BytesIO()
        with zipfile.ZipFile(blob,'w') as z:
            for name,body,mode in self.entries:
                if mode:
                    entry=zipfile.ZipInfo(name)
                    entry.external_attr=mode<<16
                    z.writestr(entry,body)
                else:z.writestr(name,body)
        raw=blob.getvalue()
        self.artifact['digest']='sha256:'+('0'*64 if self.bad_digest else hashlib.sha256(raw).hexdigest())
        def urlopen(req,**kwargs):
            if isinstance(req,str):
                self.assertEqual(req,'https://storage.github.test/artifact')
                return Response(raw)
            url=req.full_url
            if '/actions/runs/123/artifacts?' in url:data={'artifacts':[self.artifact]}
            elif url.endswith('/actions/runs/123'):data=self.run
            elif url.endswith('/actions/workflows/9'):data=self.workflow
            elif '/compare/' in url:data=self.comparison
            else:raise AssertionError('Unexpected network request')
            return Response(json.dumps(data).encode())
        class Opener:
            def open(self,req,**kwargs):
                raise urllib.error.HTTPError(req.full_url,302,'redirect',{'Location':'https://storage.github.test/artifact'},None)
        with patch.dict(os.environ,self.env,clear=True),patch('urllib.request.urlopen',side_effect=urlopen),patch('urllib.request.build_opener',return_value=Opener()),contextlib.redirect_stdout(io.StringIO()):
            exec(compile(script,'artifact-verifier','exec'),{})
    def test_happy_path_validates_digest_and_preserves_provenance(self):
        self.execute()
        self.assertEqual((self.root/'TI-Revive-0.8.41-mac.zip').read_bytes(),b'fixture-package')
        proof=json.loads((self.root/'out/build-provenance.json').read_text())
        self.assertEqual(proof['source_sha'],SHA)
        self.assertNotIn('fixture-secret-token',(self.root/'environment').read_text())
    def test_failed_run_is_rejected(self):
        self.run['conclusion']='failure'
        with self.assertRaises(SystemExit):self.execute()
    def test_foreign_fork_is_rejected(self):
        self.run['head_repository']['full_name']='foreign/repo'
        with self.assertRaises(SystemExit):self.execute()
    def test_pr_run_is_rejected(self):
        self.run['event']='pull_request'
        with self.assertRaises(SystemExit):self.execute()
    def test_other_workflow_is_rejected(self):
        self.workflow['path']='.github/workflows/untrusted.yml'
        with self.assertRaises(SystemExit):self.execute()
    def test_sha_mismatch_is_rejected(self):
        self.run['head_sha']='c'*40
        with self.assertRaises(SystemExit):self.execute()
    def test_unmerged_commit_is_rejected(self):
        self.comparison['status']='diverged'
        with self.assertRaises(SystemExit):self.execute()
    def test_expired_artifact_is_rejected(self):
        self.artifact['expired']=True
        with self.assertRaises(SystemExit):self.execute()
    def test_artifact_wrong_provenance_is_rejected(self):
        self.artifact['workflow_run']['repository_id']=99
        with self.assertRaises(SystemExit):self.execute()
    def test_digest_mismatch_is_rejected(self):
        self.bad_digest=True
        with self.assertRaises(SystemExit):self.execute()
    def test_zip_traversal_is_rejected(self):
        self.entries=[('../TI-Revive-0.8.41-mac.zip',b'escape',None)]
        with self.assertRaises(SystemExit):self.execute()
        self.assertFalse((self.root.parent/'TI-Revive-0.8.41-mac.zip').exists())
    def test_zip_symlink_is_rejected(self):
        self.entries=[('TI-Revive-0.8.41-mac.zip',b'escape',stat.S_IFLNK|0o777)]
        with self.assertRaises(SystemExit):self.execute()
    def test_zip_extra_file_is_rejected(self):
        self.entries.append(('unexpected',b'extra',None))
        with self.assertRaises(SystemExit):self.execute()

if __name__=='__main__':unittest.main(verbosity=2)

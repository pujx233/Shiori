"""Keep local builds on one certificate without modifying system trust settings."""
from pathlib import Path
import hashlib
import os
import secrets
import shlex
import subprocess
import sys
import tempfile


def run(arguments):
    return subprocess.run(arguments, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def main():
    app = Path(sys.argv[1]).resolve()
    root = Path.home() / 'Library/Application Support/Shiori Development/Signing'
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    keychain = root / 'Shiori.keychain-db'
    password_file = root / 'keychain-password'
    certificate = root / 'certificate.der'
    if not keychain.exists():
        password = secrets.token_urlsafe(32)
        descriptor = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            output.write(password)
        previous = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode())
        try:
            run(['/usr/bin/security', 'create-keychain', '-p', password, str(keychain)])
        finally:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous])
        with tempfile.TemporaryDirectory(dir=root) as directory:
            temporary = Path(directory)
            config = temporary / 'certificate.conf'
            config.write_text('''[req]
prompt = no
distinguished_name = name
x509_extensions = extensions
[name]
CN = Shiori Local Development
O = Shiori
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
            run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:3072', '-x509', '-sha256',
                 '-nodes', '-days', '3650', '-config', str(config), '-keyout', str(temporary / 'key.pem'),
                 '-out', str(temporary / 'cert.pem')])
            (temporary / 'key.pem').chmod(0o600)
            run(['/usr/bin/openssl', 'x509', '-in', str(temporary / 'cert.pem'), '-outform', 'DER',
                 '-out', str(certificate)])
            run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(temporary / 'key.pem'),
                 '-in', str(temporary / 'cert.pem'), '-out', str(temporary / 'identity.p12'),
                 '-passout', 'file:' + str(password_file)])
            run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
            run(['/usr/bin/security', 'import', str(temporary / 'identity.p12'), '-k', str(keychain),
                 '-P', password, '-x', '-T', '/usr/bin/codesign'])
            run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s',
                 '-k', password, str(keychain)])
    password = password_file.read_text()
    fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
    run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
    try:
        run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
             '--timestamp=none', '--identifier', 'local.sai.Shiori', str(app)])
        run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
    finally:
        run(['/usr/bin/security', 'lock-keychain', str(keychain)])
    print('Signed with Shiori Local Development')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Never include command arguments: keychain commands contain the local password.
        print(error.stderr.decode(errors='replace').strip() or 'Local signing failed.', file=sys.stderr)
        sys.exit(1)

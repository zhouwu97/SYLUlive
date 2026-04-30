import zipfile, hashlib, os, re

apk = r'D:\kaifa\xiaoyuan\shenliyuan-release.apk'

# Check signatures
z = zipfile.ZipFile(apk)
sig_files = [n for n in z.namelist() if 'META-INF' in n and (n.endswith('.RSA') or n.endswith('.DSA') or n.endswith('.EC') or n.endswith('.SF') or n.endswith('.MF'))]
print('Signature files:', sig_files)

# Check manifest
manifest = z.read('AndroidManifest.xml').decode('utf-8', 'ignore')
package_match = re.search(r'package="([^"]+)"', manifest)
version_match = re.search(r'versionName="([^"]+)"', manifest)
versioncode_match = re.search(r'versionCode="([^"]+)"', manifest)
print('Package:', package_match.group(1) if package_match else 'Not found')
print('versionName:', version_match.group(1) if version_match else 'Not found')
print('versionCode:', versioncode_match.group(1) if versioncode_match else 'Not found')

# Check native libs
native_libs = [n for n in z.namelist() if n.startswith('lib/')]
cpu_arches = set()
for lib in native_libs:
    parts = lib.split('/')
    if len(parts) >= 2:
        cpu_arches.add(parts[1])
print('CPU architectures:', cpu_arches)

# Check for duplicate signing
cert_files = [n for n in z.namelist() if n.startswith('META-INF/') and (n.endswith('.RSA') or n.endswith('.DSA') or n.endswith('.EC'))]
print('Signature files:', cert_files)

# APK info
print(f'Size: {os.path.getsize(apk)} bytes ({os.path.getsize(apk)/1024/1024:.1f} MB)')
print('SHA256:', hashlib.sha256(open(apk,'rb').read()).hexdigest().upper())
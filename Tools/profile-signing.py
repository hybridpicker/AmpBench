"""For ios/build.sh: what signing by hand with a provisioning profile needs.

Usage: profile-signing.py <decoded profile plist> <bundle id> <entitlements file to write>

Writes the profile's entitlements with this app's id in place of a wildcard, and prints the SHA-1 of the profile's
certificate that is in the keychain (nothing when none is).
"""
import hashlib
import plistlib
import subprocess
import sys

with open(sys.argv[1], "rb") as file:
    profile = plistlib.load(file)
rights = profile["Entitlements"]
wanted = rights["com.apple.developer.team-identifier"] + "." + sys.argv[2]
if rights["application-identifier"].endswith("*"):
    rights["application-identifier"] = wanted
elif rights["application-identifier"] != wanted:
    sys.exit("The profile is for another bundle id than " + sys.argv[2] + ".")
with open(sys.argv[3], "wb") as file:
    plistlib.dump(rights, file)
have = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
for certificate in profile["DeveloperCertificates"]:
    digest = hashlib.sha1(certificate).hexdigest().upper()
    if digest in have:
        print(digest)
        break

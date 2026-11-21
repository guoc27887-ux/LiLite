"""Validate the actual iOS package before copying it out of the xtool staging directory."""
import argparse
from datetime import datetime, timezone
import plistlib
import re
import struct
import subprocess
import zipfile
from apple_seal import verify_development
from pathlib import Path

MULTICAST = "com.apple.developer.networking.multicast"
BASE_BUNDLE_ID = "com.liuliuya.PiliNative"

def require(ok, reason):
    if not ok:
        raise SystemExit(reason)

def application_identity(info, signed=None, profile=None):
    """Return the unsigned identity only after checking the actual signed/profile identity.

    xtool uses XTL-<team>. for personal-team application identifiers. Its spelling is
    accepted only when the very same team is present in the verified executable and profile.
    The caller verifies both signatures before passing signed/profile values here.
    """
    bundle = info.get("CFBundleIdentifier")
    if signed is None:
        require(bundle == BASE_BUNDLE_ID, "Unexpected unsigned application identity")
        return BASE_BUNDLE_ID
    require(isinstance(profile,dict),"Missing verified development profile")
    team = signed.get("com.apple.developer.team-identifier")
    require(isinstance(team,str) and re.fullmatch(r"[A-Z0-9]{10}",team)
            and team in profile.get("TeamIdentifier",[]),"Signing team mismatch")
    require(bundle in (BASE_BUNDLE_ID,f"XTL-{team}.{BASE_BUNDLE_ID}"),"Unexpected signed application identity")
    app = signed.get("application-identifier", "")
    require(any(isinstance(p,str) and app==p+"."+bundle for p in profile.get("ApplicationIdentifierPrefix",[])),
            "Executable application ID mismatch")
    pattern = profile.get("Entitlements",{}).get("application-identifier", "")
    require(isinstance(pattern,str) and (pattern==app or (pattern.endswith(".*") and app.startswith(pattern[:-1]))),
            "Profile does not cover executable ID")
    return BASE_BUNDLE_ID

def device_executable(blob, info):
    require(len(blob)>=32 and struct.unpack_from("<II",blob)==(0xFEEDFACF,0x0100000C),"Expected arm64 Mach-O")
    kind, count, size=struct.unpack_from("<III",blob,12)
    require(kind==2 and 32+size<=len(blob),"Expected a Mach-O executable")
    offset=32;platforms=[]
    for _ in range(count):
        require(offset+8<=32+size,"Invalid load command count")
        command,length=struct.unpack_from("<II",blob,offset)
        require(length>=8 and offset+length<=32+size,"Invalid Mach-O load command length")
        if command==0x32:
            require(length>=24,"Incomplete SDK metadata")
            platforms.append(struct.unpack_from("<III",blob,offset+8))
        offset+=length
    require(offset==32+size and len(platforms)==1 and platforms[0][0]==2,"Binary is not an iOS device build")
    minimum=platforms[0][1]
    require(info.get("CFBundleSupportedPlatforms")==["iPhoneOS"],"Bundle is not marked for iPhoneOS")
    version=info.get("MinimumOSVersion","").split(".")
    require(len(version) in (2,3) and all(s.isdecimal() for s in version),"Invalid minimum iOS version")
    declared=tuple(map(int,version))+(0,)*(3-len(version))
    require(declared==(minimum>>16,(minimum>>8)&255,minimum&255) and declared==(18,0,0),"Deployment target mismatch")
    # iOS 18 fork: upstream expects 17.0 here; this fork lowers the target to 18.0
    # (Package.swift platforms + LiLite.xcodeproj IPHONEOS_DEPLOYMENT_TARGET).
    sdk=platforms[0][2]
    sdk_version=(sdk>>16,(sdk>>8)&255,sdk&255)
    name=info.get("DTSDKName", "")
    require(re.fullmatch(r"iphoneos\d+\.\d+(?:\.\d+)?",name),"Missing device SDK provenance")
    parts=tuple(map(int,name.removeprefix("iphoneos").split(".")))
    parts=parts+(0,)*(3-len(parts))
    require(sdk_version==parts and sdk_version>=(26,0,0),"Linked SDK differs from the SDK used to build the app")
    require(info.get("DTPlatformName")=="iphoneos" and info.get("DTPlatformVersion")==name.removeprefix("iphoneos")
            and bool(info.get("DTSDKBuild")),"Incomplete SDK provenance")
    require(info.get("UIDesignRequiresCompatibility") is not True,"Legacy interface compatibility is enabled")

def executable_entitlements(blob):
    commands = struct.unpack_from("<I", blob, 16)[0]
    offset = 32
    for _ in range(commands):
        cmd, size = struct.unpack_from("<II", blob, offset)
        require(size >= 8 and offset + size <= len(blob), "Invalid Mach-O load command")
        if cmd == 0x1D:
            pos, length = struct.unpack_from("<II", blob, offset + 8)
            sig = memoryview(blob)[pos:pos + length]
            if len(sig) < 12 or struct.unpack_from(">I", sig)[0] != 0xFADE0CC0:
                return {}
            for i in range(struct.unpack_from(">I", sig, 8)[0]):
                kind, start = struct.unpack_from(">II", sig, 12 + 8 * i)
                if kind == 5:
                    magic, total = struct.unpack_from(">II", sig, start)
                    require(magic == 0xFADE7171 and total >= 8 and start + total <= len(sig),
                            "Invalid Mach-O entitlements blob")
                    return plistlib.loads(bytes(sig[start + 8:start + total]).rstrip(b"\x00"))
        offset += size
    return {}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--firebase-plist", type=Path)
    parser.add_argument("--discovery", choices=("full","personal"),default="full")
    args = parser.parse_args()
    with zipfile.ZipFile(args.ipa) as z:
        names = z.namelist()
        require(len(names) == len(set(names)) and z.testzip() is None, "IPA CRC or directory invalid")
        matches = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        require(len(matches) == 1, "Expected exactly one main app")
        info = plistlib.loads(z.read(matches[0]))
        prefix = matches[0][:-len("Info.plist")]
        if args.firebase_plist:
            config = prefix + "GoogleService-Info.plist"
            require(config in names and plistlib.loads(z.read(config)) ==
                    plistlib.loads(args.firebase_plist.read_bytes()), "Firebase app configuration mismatch")
            for sdk in ("FirebaseCore", "FirebaseCrashlytics"):
                require(prefix + sdk + "_Privacy.bundle/PrivacyInfo.xcprivacy" in names,
                        "Missing privacy manifest for " + sdk)
        notices = Path(__file__).resolve().parents[1] / "Sources/PiliNative/Notices"
        required = {"PiliPlus-GPL.txt", "SwiftProtobuf-LICENSE.txt", "ZIPFoundation-LICENSE.txt", "FFmpeg-LGPL.txt", "dav1d-BSD.txt", "Anime4K.txt", "MaterialColorUtilities.txt", "FlexSeedScheme.txt", "libass-ISC.txt", "FreeType-FTL.txt", "HarfBuzz-MIT.txt", "FriBidi-LGPL.txt"}
        bundled = {p.name for p in notices.iterdir() if p.is_file()}
        require(required <= bundled, "Native source tree lacks a required third-party notice")
        for source in sorted(bundled):
            found = [n for n in names if n.startswith(prefix) and n.endswith(".bundle/Notices/"+source)]
            require(len(found)==1 and z.read(found[0]).replace(b"\r\n",b"\n")== (notices/source).read_bytes().replace(b"\r\n",b"\n"),"Missing or changed notice: "+source)
        for resource in ("Graph.json","Anime4K.msl"):
            expected = (notices.parent / "UpscaleAssets" / resource).read_bytes().replace(b"\r\n",b"\n")
            found = [n for n in names if n.startswith(prefix) and n.endswith(".bundle/UpscaleAssets/"+resource)]
            require(bool(expected) and len(found)==1 and z.read(found[0]).replace(b"\r\n",b"\n")==expected,"Missing or changed native shader resource: "+resource)
        binary = z.read(prefix + info["CFBundleExecutable"])
        device_executable(binary, info)
        if not args.signed:application_identity(info)
        use_multicast = args.discovery == "full"
        require(info.get("PiliMulticastDiscovery") is use_multicast, "Discovery mode in IPA differs from build configuration")
        require(set(info.get("NSBonjourServices", [])) >= {"_upnp._tcp","_ssdp._udp"} and info.get("NSLocalNetworkUsageDescription"),"Missing local network declarations")
        require("audio" in info.get("UIBackgroundModes", []), "Background audio mode missing")
        require(bool(info.get("NSPhotoLibraryAddUsageDescription")), "Missing add-to-photos permission description")
        require(info.get("UIApplicationSupportsIndirectInputEvents") is True, "Missing indirect input opt-in")
        require("UIInterfaceOrientationPortraitUpsideDown" in info.get("UISupportedInterfaceOrientations~ipad", []), "Missing iPad orientation")
        require(info.get("CADisableMinimumFrameDurationOnPhone") is True, "Missing high refresh rate opt-in")
        require(not any("flutter" in n.lower() or "App.framework/" in n for n in names),
                "Unexpected Flutter runtime or resources")
        if args.signed:
            require(prefix + "embedded.mobileprovision" in names, "Development profile missing")
            cms = z.read(prefix + "embedded.mobileprovision")
            profile = plistlib.loads(subprocess.check_output(
                ["openssl", "cms", "-verify", "-noverify", "-inform", "DER"],
                input=cms, stderr=subprocess.PIPE))
            verify_development(z,prefix,profile)
            expires = profile.get("ExpirationDate")
            require(isinstance(expires,datetime) and expires.replace(tzinfo=timezone.utc)>datetime.now(timezone.utc),"Development profile has expired")
            allowed=profile.get("Entitlements",{}); signed=executable_entitlements(binary)
            if use_multicast:
                require(allowed.get(MULTICAST) is True and signed.get(MULTICAST) is True,
                        "Multicast not granted in profile and executable")
            else:
                require(signed.get(MULTICAST) is not True,"Personal build must not claim multicast authorization")
            application_identity(info,signed,profile)
        print("IPA verified: native arm64,", info["CFBundleIdentifier"],
              f"| development profile and {args.discovery} discovery checked" if args.signed else "| unsigned build check")
if __name__ == "__main__":
    main()

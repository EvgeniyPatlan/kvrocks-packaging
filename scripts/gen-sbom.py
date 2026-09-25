#!/usr/bin/env python3
import argparse
import json
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

DECL = re.compile(r"FetchContent_DeclareGitHubWithMirror\(\s*(\S+)\s+(\S+)\s+(\S+)\s+(\w+)=(\w+)")
TEST_ONLY = {"gtest"}


def declarations(src):
    cmake_dir = src / "cmake"
    if not cmake_dir.is_dir():
        sys.exit(f"gen-sbom: {cmake_dir} is not a directory")
    found = {}
    for f in sorted(cmake_dir.glob("*.cmake")):
        for name, repo, tag, alg, digest in DECL.findall(f.read_text()):
            found[f"{name}-{tag}.zip"] = (name, repo, tag, alg, digest)
    return found


def shipped(src):
    deps_dir = src / "deps"
    if not deps_dir.is_dir():
        sys.exit(f"gen-sbom: {deps_dir} is not a directory")
    decls = declarations(src)
    deps = []
    archives = sorted(deps_dir.glob("*.zip"))
    if not archives:
        sys.exit(f"gen-sbom: no .zip archives found in {deps_dir}")
    for archive in archives:
        if archive.name not in decls:
            sys.exit(f"gen-sbom: no cmake declaration for {archive.name}")
        if decls[archive.name][0] not in TEST_ONLY:
            deps.append(decls[archive.name])
    return deps


def spdx_doc(name, version, deps, now):
    root = "SPDXRef-Package-" + name
    packages = [{
        "name": name, "SPDXID": root, "versionInfo": version,
        "downloadLocation": "https://github.com/apache/kvrocks",
        "licenseDeclared": "Apache-2.0", "filesAnalyzed": False,
    }]
    rels = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root}]
    for dep, repo, tag, alg, digest in deps:
        ref = "SPDXRef-Package-" + dep
        packages.append({
            "name": dep, "SPDXID": ref, "versionInfo": tag,
            "downloadLocation": f"https://github.com/{repo}/archive/{tag}.zip",
            "checksums": [{"algorithm": alg, "checksumValue": digest}],
            "licenseDeclared": "NOASSERTION", "filesAnalyzed": False,
            "externalRefs": [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                              "referenceLocator": f"pkg:github/{repo}@{tag}"}],
        })
        rels.append({"spdxElementId": root, "relationshipType": "CONTAINS", "relatedSpdxElement": ref})
    return {
        "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{name}-{version}",
        "documentNamespace": f"https://percona.com/spdx/{name}-{version}-{uuid.uuid4()}",
        "creationInfo": {"created": now, "creators": ["Organization: Percona", "Tool: gen-sbom.py"]},
        "packages": packages, "relationships": rels,
    }


def cdx_doc(name, version, deps, now):
    return {
        "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "metadata": {"timestamp": now, "component": {
            "type": "application", "name": name, "version": version,
            "licenses": [{"license": {"id": "Apache-2.0"}}],
        }},
        "components": [{
            "type": "library", "name": dep, "version": tag,
            "purl": f"pkg:github/{repo}@{tag}",
            "hashes": [{"alg": alg, "content": digest}],
            "externalReferences": [{"type": "distribution", "url": f"https://github.com/{repo}/archive/{tag}.zip"}],
        } for dep, repo, tag, alg, digest in deps],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, type=Path)
    ap.add_argument("--name", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()
    deps = shipped(a.src)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / f"{a.name}.spdx.json").write_text(json.dumps(spdx_doc(a.name, a.version, deps, now), indent=2) + "\n")
    (a.out / f"{a.name}.cdx.json").write_text(json.dumps(cdx_doc(a.name, a.version, deps, now), indent=2) + "\n")


if __name__ == "__main__":
    main()

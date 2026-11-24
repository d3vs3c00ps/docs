"""Validate Kubernetes YAML against an OpenAPI v2 spec or CRD schemas, offline.

Used by the KubeVirt note tests, which have no cluster with KubeVirt to run
`kubectl apply --dry-run=server`. It checks what the API server would: field names
(strict, like --validate=strict), types and required fields. For VirtualMachine
objects it also checks that each disk has a volume and each interface a network,
as KubeVirt's admission webhook does.

  python3 schema.py SPEC FILE [--def NAME] [--partial]

SPEC is a swagger.json, or a YAML file of CustomResourceDefinitions. FILE is YAML
(several documents allowed), or - for stdin. --def validates every document against
the named definition (for fragments of a spec). --partial ignores required fields,
and the disk and interface check unless --refs asks for it.
"""

import argparse
import copy
import json
import sys

import jsonschema
import yaml

LOOSE = {"type": ["string", "integer", "number"]}


def strict(node):
    """Forbid unknown fields wherever a schema lists its properties."""
    if isinstance(node, dict):
        if node.get("format") == "int-or-string" or node.get("x-kubernetes-int-or-string"):
            node.clear()
            node.update(LOOSE)
            return node
        for value in node.values():
            strict(value)
        if (
            "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
    elif isinstance(node, list):
        for value in node:
            strict(value)
    return node


def drop_required(node):
    if isinstance(node, dict):
        node.pop("required", None)
        for value in node.values():
            drop_required(value)
    elif isinstance(node, list):
        for value in node:
            drop_required(value)


def load_spec(path):
    """Return (definitions, index): index maps (group, version, kind) to a definition name."""
    with open(path) as f:
        text = f.read()
    defs, index = {}, {}
    if path.endswith(".json"):
        defs = json.loads(text)["definitions"]
        for name, d in defs.items():
            for gvk in d.get("x-kubernetes-group-version-kind", []):
                index[(gvk["group"], gvk["version"], gvk["kind"])] = name
    else:
        for doc in yaml.safe_load_all(text):
            if not doc or doc.get("kind") != "CustomResourceDefinition":
                continue
            spec = doc["spec"]
            for v in spec["versions"]:
                name = f'{spec["group"]}.{v["name"]}.{spec["names"]["kind"]}'
                schema = copy.deepcopy(v["schema"]["openAPIV3Schema"])
                props = schema.setdefault("properties", {})
                props.setdefault("apiVersion", {"type": "string"})
                props.setdefault("kind", {"type": "string"})
                props["metadata"] = {"type": "object"}
                defs[name] = schema
                index[(spec["group"], v["name"], spec["names"]["kind"])] = name
    return defs, index


def find(defs, index, obj):
    api, kind = obj.get("apiVersion", ""), obj.get("kind", "")
    group, _, version = api.rpartition("/")
    if (group, version, kind) in index:
        return index[(group, version, kind)]
    # KubeVirt's swagger has no group-version-kind entries: definitions are "<version>.<Kind>".
    name = f"{version}.{kind}"
    if name in defs:
        return name
    sys.exit(f"no schema for apiVersion={api} kind={kind}")


def kubevirt_refs(vmi):
    """KubeVirt's webhook: every disk needs a volume, every interface a network."""
    errors = []
    devices = vmi.get("domain", {}).get("devices", {})
    volumes = {v["name"] for v in vmi.get("volumes", [])}
    networks = {n["name"] for n in vmi.get("networks", [])}
    for d in devices.get("disks", []):
        if d["name"] not in volumes:
            errors.append(f"disk {d['name']!r} has no volume of the same name")
    for i in devices.get("interfaces", []):
        if i["name"] not in networks:
            errors.append(f"interface {i['name']!r} has no network of the same name")
    return errors


def main():
    p = argparse.ArgumentParser()
    p.add_argument("spec")
    p.add_argument("file")
    p.add_argument("--def", dest="definition")
    p.add_argument("--partial", action="store_true")
    p.add_argument("--refs", action="store_true")
    args = p.parse_args()

    defs, index = load_spec(args.spec)
    defs = strict(copy.deepcopy(defs))
    if args.partial:
        drop_required(defs)
    text = sys.stdin.read() if args.file == "-" else open(args.file).read()
    failed = False
    for n, obj in enumerate(d for d in yaml.safe_load_all(text) if d is not None):
        name = args.definition or find(defs, index, obj)
        schema = {"$ref": f"#/definitions/{name}", "definitions": defs}
        validator = jsonschema.Draft4Validator(schema)
        errors = [
            f"{'.'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
            for e in validator.iter_errors(obj)
        ]
        if args.refs or not args.partial:
            if name == "v1.VirtualMachine":
                errors += kubevirt_refs(obj.get("spec", {}).get("template", {}).get("spec", {}))
            elif name == "v1.VirtualMachineInstance":
                errors += kubevirt_refs(obj.get("spec", {}))
            elif name == "v1.VirtualMachineInstanceSpec":
                errors += kubevirt_refs(obj)
        for e in errors:
            print(f"document {n + 1} ({name}): {e}")
        failed |= bool(errors)
        if not errors:
            print(f"document {n + 1} ({name}): valid")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

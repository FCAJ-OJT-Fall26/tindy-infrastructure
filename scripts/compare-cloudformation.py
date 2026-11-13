import argparse
import subprocess

from cfnlint.decode.cfn_yaml import loads


def git(*args):
    return subprocess.check_output(["git", *args], encoding="utf-8")


def templates(revision):
    if revision == "0" * 40:
        return {}

    paths = git("ls-tree", "-r", "--name-only", revision, "--", "cloudformation/")
    return {
        path: git("show", f"{revision}:{path}")
        for path in paths.splitlines()
        if path.endswith(".yaml")
    }


def changed_keys(before, after):
    return sorted(
        key
        for key in before.keys() | after.keys()
        if key not in before or key not in after or before[key] != after[key]
    )


def compare_template(path, before_text, after_text):
    before = loads(before_text, path)
    after = loads(after_text, path)
    before_resources = before.pop("Resources", {})
    after_resources = after.pop("Resources", {})
    sections = changed_keys(before, after)

    print(f"### `{path}`")
    if sections:
        print(f"\nChanged template sections: {', '.join(sections)}.")

    resources = changed_keys(before_resources, after_resources)
    if not resources:
        print("\nNo resource definition changes.")
        return

    print("\n| Action | Logical resource | Resource type | Changed fields |")
    print("| --- | --- | --- | --- |")
    for name in resources:
        if name not in before_resources:
            action, resource, fields = "Add", after_resources[name], "—"
        elif name not in after_resources:
            action, resource, fields = "Remove", before_resources[name], "—"
        else:
            resource = after_resources[name]
            previous = before_resources[name]
            fields = changed_keys(previous, resource)
            if "Properties" in fields:
                fields.remove("Properties")
                fields.extend(
                    f"Properties.{key}"
                    for key in changed_keys(previous.get("Properties", {}), resource.get("Properties", {}))
                )
            fields = ", ".join(fields)
            action = "Modify"
        print(f"| {action} | `{name}` | `{resource['Type']}` | {fields} |")


def main():
    parser = argparse.ArgumentParser(description="Compare committed CloudFormation templates.")
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args()
    before = templates(args.base)
    after = templates(args.head)

    print("## Offline CloudFormation diff")
    print("\nCompares template definitions in Git. AWS resolves conditions and replacement during Change Set planning.")
    paths = changed_keys(before, after)
    if not paths:
        print("\nNo CloudFormation template changes.")
    for path in paths:
        print()
        compare_template(path, before.get(path, ""), after.get(path, ""))


if __name__ == "__main__":
    main()

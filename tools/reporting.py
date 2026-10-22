"""Replace machine-specific prefixes in exported verification diagnostics."""
import json
from pathlib import Path


def portable_report(value, project_root, executables=()):
    replacements = {}

    def add_path(path, label):
        path = Path(path).resolve()
        variants = {str(path), path.as_posix(), path.as_uri()}
        for variant in variants:
            replacements[variant] = label
            replacements[json.dumps(variant, ensure_ascii=False)[1:-1]] = label

    root = Path(project_root).resolve()
    home = Path.home().resolve()
    add_path(root, "<project>")
    add_path(home, "<home>")
    for name, executable in executables:
        if executable:
            add_path(executable, "<{}>".format(name))
    try:
        relative = root.relative_to(home)
        for prefix in ("~/" + relative.as_posix(), "~\\" + str(relative).replace("/", "\\")):
            replacements[prefix] = "<project>"
            replacements[json.dumps(prefix, ensure_ascii=False)[1:-1]] = "<project>"
    except ValueError:
        pass
    # A tool executable may be inside the project or home. Replace the most
    # specific prefix first so its useful role survives in command records.
    prefixes = sorted(replacements, key=len, reverse=True)

    def convert(item):
        if isinstance(item, str):
            for prefix in prefixes:
                item = item.replace(prefix, replacements[prefix])
            return item
        if isinstance(item, (list, tuple)):
            return [convert(part) for part in item]
        if isinstance(item, dict):
            return {key: convert(part) for key, part in item.items()}
        return item

    return convert(value)

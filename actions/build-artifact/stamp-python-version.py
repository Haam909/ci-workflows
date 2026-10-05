"""Write a version into the static version field of pyproject.toml.

Handles PEP 621 ([project]) and Poetry ([tool.poetry]). Projects using a
dynamic version (setuptools-scm, hatch-vcs) have no static field and are
left alone; the build action sets SETUPTOOLS_SCM_PRETEND_VERSION for those.

usage: stamp-python-version.py <pyproject.toml> <version>
"""
import pathlib
import re
import sys

path, version = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()


def stamp(text: str, table: str) -> tuple[str, bool]:
    section = re.search(rf"(?ms)^\[{re.escape(table)}\]\s*$(.*?)(?=^\[|\Z)", text)
    if not section:
        return text, False
    body, count = re.subn(
        r'(?m)^(version\s*=\s*)"[^"]*"',
        rf'\g<1>"{version}"',
        section.group(1),
        count=1,
    )
    return text[: section.start(1)] + body + text[section.end(1):], bool(count)


stamped = False
for table in ("project", "tool.poetry"):
    text, changed = stamp(text, table)
    stamped = stamped or changed

path.write_text(text)
print(
    f"pyproject.toml version -> {version}"
    if stamped
    else "No static version in pyproject.toml; relying on dynamic versioning."
)

#!/usr/bin/env python3
"""Keep XcodeGen's root-package display label independent of the checkout name."""

from pathlib import Path
import re


def normalize_project(text):
    pattern = re.compile(
        r'(?m)^(\s*)([A-F0-9]{24}) /\* ([^\n]*?) \*/ = '
        r'\{isa = PBXFileReference; lastKnownFileType = folder; '
        r'name = (?:"[^"]*"|[^;]+); path = \.; sourceTree = SOURCE_ROOT; \};$'
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError("Expected one root-package file reference in the generated project")
    match = matches[0]
    reference, old_name = match.group(2, 3)
    text = text.replace(f"{reference} /* {old_name} */", f"{reference} /* BottoCore */")
    return re.sub(
        rf'({reference} /\* BottoCore \*/ = \{{[^\n]*?name = )(?:"[^"]*"|[^;]+)(; path = \.;)',
        r'\g<1>BottoCore\2', text,
    )


if __name__ == "__main__":
    project = Path(__file__).resolve().parent.parent / "Botto.xcodeproj/project.pbxproj"
    project.write_text(normalize_project(project.read_text()))

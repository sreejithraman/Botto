#!/usr/bin/env python3
"""Keep XcodeGen's root-package file reference independent of the checkout name."""

from pathlib import Path
import re

# XcodeGen derives this reference's ID and label from the checkout directory.
STABLE_ID = "ED6D716FEDEF38800CC353C1"
BEGIN, END = "/* Begin PBXFileReference section */\n", "/* End PBXFileReference section */"


def normalize_project(text):
    pattern = re.compile(
        r'(?m)^(\s*)([A-F0-9]{24}) /\* ([^\n]*?) \*/ = '
        r'\{isa = PBXFileReference; lastKnownFileType = folder; '
        r'name = (?:"[^"]*"|[^;]+); path = \.; sourceTree = SOURCE_ROOT; \};\n'
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError("Expected one root-package file reference in the generated project")
    indent, reference, old_name = matches[0].group(1, 2, 3)
    if reference != STABLE_ID and STABLE_ID in text:
        raise ValueError("The stable root-package ID is already in use")
    text = text.replace(matches[0].group(0), "").replace(f"{reference} /* {old_name} */", f"{STABLE_ID} /* BottoCore */")
    head, rest = text.split(BEGIN, 1)
    lines = rest.split(END, 1)[0].splitlines(keepends=True)
    # Xcode keeps each section sorted by ID.
    at = next((i for i, line in enumerate(lines) if line.strip()[:24] > STABLE_ID), len(lines))
    lines.insert(at, f"{indent}{STABLE_ID} /* BottoCore */ = {{isa = PBXFileReference; lastKnownFileType = folder; "
                     "name = BottoCore; path = .; sourceTree = SOURCE_ROOT; };\n")
    return head + BEGIN + "".join(lines) + END + rest.split(END, 1)[1]


if __name__ == "__main__":
    project = Path(__file__).resolve().parent.parent / "Botto.xcodeproj/project.pbxproj"
    project.write_text(normalize_project(project.read_text()))

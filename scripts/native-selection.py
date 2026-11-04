#!/usr/bin/env python3
"""Hold focused native runs to Xcode's identifiers and recorded results.

xcodebuild's filtered inventory lists an exact parameterized selection as
disabled even when -only-testing executes it, so only the result bundle can
prove that such a selection ran.
"""

import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Dict, Iterable, Iterator, List, Optional

TARGET = "BottoTests"
DISABLED = " (disabled)"
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
SELECTOR = re.compile(rf"{NAME}(?:(?:/{NAME})+(?:\((?:{NAME}:)*\))?)?")


def validate(selector: str) -> None:
    if not SELECTOR.fullmatch(selector) or selector.split("/")[0] == TARGET:
        sys.exit(f"Expected a native suite or Suite/testFunction(...) selector without {TARGET}/.")


def selects(selector: str, identifier: str) -> bool:
    selected = selector.removesuffix("()")
    return identifier.removesuffix("()") == selected or identifier.startswith(selected + "/")


def inventory_tests(inventory: str) -> Dict[str, bool]:
    """Map each listed test identifier to whether Xcode marks it disabled."""
    lines = (line.strip() for line in inventory.splitlines())
    return {line.removesuffix(DISABLED): line.endswith(DISABLED) for line in lines
            if line.startswith(TARGET + "/")}


def discovery(selector: str, inventory: str) -> str:
    requested = f"{TARGET}/{selector}"
    tests = inventory_tests(inventory)
    active = [test for test, disabled in tests.items() if not disabled and selects(requested, test)]
    if active:
        return f"Xcode discovered {len(active)} matching test identifiers."
    if selector.endswith(":)") and requested in tests:
        return f"Xcode lists {selector}; its result bundle must show it passed."
    message = "The requested native test was not discovered by Xcode; no tests executed."
    listed = [test.removeprefix(TARGET + "/") for test in tests
              if test.partition("(")[0] == requested.partition("(")[0]]
    if listed:
        message += f" Xcode lists: {', '.join(listed)}."
    sys.exit(message)


def recorded_cases(nodes: Iterable[dict]) -> Iterator[dict]:
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            yield node
        yield from recorded_cases(node.get("children", []))


def suite_fallback(selector: Optional[str]) -> str:
    if not selector or "/" not in selector:
        return ""
    return f" Run its suite instead: ./scripts/check-native.sh {selector.rpartition('/')[0]}"


def verified_results(selector: Optional[str], summary: dict, nodes: List[dict]) -> str:
    passed = summary.get("passedTests")
    if not isinstance(passed, int) or passed < 1:
        sys.exit("Native run reported success without executing any passing tests." + suite_fallback(selector))
    if selector and not any(case.get("result") == "Passed" and selects(selector, case.get("nodeIdentifier") or "")
                            for case in recorded_cases(nodes)):
        sys.exit(f"Native run reported no passing result for {selector}." + suite_fallback(selector))
    return f"Native results: {passed} passed, {summary.get('failedTests')} failed, {summary.get('skippedTests')} skipped"


def xcresult(kind: str, bundle: str) -> dict:
    output = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", bundle],
                            check=True, stdout=subprocess.PIPE, text=True).stdout
    return json.loads(output)


def main(arguments: List[str]) -> None:
    command = arguments[0] if arguments else ""
    if command == "validate" and len(arguments) == 2:
        validate(arguments[1])
    elif command == "discovery" and len(arguments) == 3:
        print(discovery(arguments[1], Path(arguments[2]).read_text()))
    elif command == "results" and len(arguments) in (2, 3):
        selector = arguments[2] if len(arguments) == 3 else None
        nodes = xcresult("tests", arguments[1]).get("testNodes", []) if selector else []
        print(verified_results(selector, xcresult("summary", arguments[1]), nodes))
    else:
        sys.exit("Usage: native-selection.py validate SELECTOR | discovery SELECTOR INVENTORY | results XCRESULT [SELECTOR]")


if __name__ == "__main__":
    main(sys.argv[1:])

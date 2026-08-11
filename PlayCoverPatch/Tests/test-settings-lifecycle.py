#!/usr/bin/env python3
"""Regression gate for the small VRChat PlayChain/KeyCover override."""

from __future__ import annotations

import argparse
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"settings lifecycle regression: {message}")


def function_body(source: str, declaration: str) -> str:
    start = source.find(declaration)
    require(start >= 0, f"missing {declaration}")
    brace = source.find("{", start)
    require(brace >= 0, f"missing body for {declaration}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]
    raise SystemExit(f"settings lifecycle regression: unclosed {declaration}")


def check_applied(root: Path) -> None:
    settings_path = root / "PlayCover/Model/AppSettings.swift"
    play_app_path = root / "PlayCover/Model/PlayApp.swift"
    for path in (settings_path, play_app_path):
        require(path.is_file() and not path.is_symlink(), f"unsafe or missing {path}")

    settings = settings_path.read_text(encoding="utf-8")
    require("    var playChain = false" in settings, "PlayChain default is not off")
    require(
        "forKey: .playChain) ?? false" in settings,
        "missing PlayChain decode fallback is not off",
    )
    initializer = function_body(settings, "init(_ info: AppInfo)")
    require(
        "VRChatMemoryPolicyManifest.matches(" in initializer
        and "settings.playChain = false" in initializer
        and "settings.playChainDebugging = false" in initializer,
        "VRChat settings initialization does not disable PlayChain",
    )

    play_app = play_app_path.read_text(encoding="utf-8")
    for declaration in ("func unlockKeyCover() async", "func lockKeyCover()"):
        body = function_body(play_app, declaration)
        guard_position = body.find("guard !VRChatMemoryPolicyManifest.matches(")
        keycover_position = body.find("KeyCover.shared")
        require(
            0 <= guard_position < keycover_position,
            f"{declaration} does not bypass KeyCover for VRChat",
        )


def check_patch(patch: Path) -> None:
    require(patch.is_file() and not patch.is_symlink(), "unsafe or missing patch")
    text = patch.read_text(encoding="utf-8")
    for path in (
        "PlayCover/Model/AppSettings.swift",
        "PlayCover/Model/PlayApp.swift",
    ):
        require(f"diff --git a/{path} b/{path}" in text, f"patch omits {path}")
    require(
        "+    var playChain = false" in text
        and "+        playChain = try container.decodeIfPresent(Bool.self, forKey: .playChain) ?? false"
        in text,
        "patch does not default PlayChain off",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--applied-root", type=Path)
    group.add_argument("--patch", type=Path)
    args = parser.parse_args()
    if args.applied_root:
        check_applied(args.applied_root.resolve())
    else:
        check_patch(args.patch.resolve())
    print("VRChat settings lifecycle regression checks passed.")


if __name__ == "__main__":
    main()

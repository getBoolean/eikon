"""Shared pytest fixtures for the Eikon scripts.

Tests run the repo's scripts against throwaway git repositories, so they never
depend on the state of the Eikon checkout itself.
"""

from __future__ import annotations

import os
import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

# Identity and settings for fixture repos, passed per command. The user's
# global and system git config are neither read nor changed.
_GIT_ENV = {
    "GIT_AUTHOR_NAME": "Eikon Tests",
    "GIT_AUTHOR_EMAIL": "tests@example.invalid",
    "GIT_COMMITTER_NAME": "Eikon Tests",
    "GIT_COMMITTER_EMAIL": "tests@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}


def _env(extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(_GIT_ENV)
    env.pop("EIKON_BUILD_NUMBER", None)
    if extra:
        env.update(extra)
    return env


def _git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=cwd, env=_env(), check=True, capture_output=True, text=True
    )


class GitRepo:
    """A git repository in a temporary directory."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return _git(self.path, *args)

    def write(self, relpath: str, text: str) -> Path:
        target = self.path / relpath
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        return target

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "--allow-empty", "-m", message)

    def tag(self, name: str) -> None:
        self.git("tag", name)


@pytest.fixture
def make_repo(tmp_path: Path) -> Callable[[str], GitRepo]:
    """Factory for extra repos: make_repo(name) creates tmp_path/name."""

    def make(name: str) -> GitRepo:
        path = tmp_path / name
        path.mkdir(parents=True)
        _git(path, "init", "--initial-branch=main")
        return GitRepo(path)

    return make


@pytest.fixture
def git_repo(make_repo: Callable[[str], GitRepo]) -> GitRepo:
    """A new git repo with local identity configured. GitRepo offers
    write(path, text), commit(message), tag(name), git(*args) and a .path attribute."""
    return make_repo("repo")


@pytest.fixture
def run_script() -> Callable[..., subprocess.CompletedProcess[str]]:
    """run_script(script, *args, cwd=..., env=None) runs a script from the Eikon
    checkout (for example "scripts/version.sh") with its working directory set
    to `cwd`, under the same isolated git environment as the fixture repos."""

    def run(script: str, *args: str, cwd: Path, env: dict[str, str] | None = None):
        return subprocess.run(
            [str(REPO_ROOT / script), *args],
            cwd=cwd,
            env=_env(env),
            capture_output=True,
            text=True,
        )

    return run

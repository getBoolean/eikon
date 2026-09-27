"""Behaviour of scripts/version.sh, the version guard."""

VERSION_SH = "scripts/version.sh"


def _versioned(repo, version: str):
    repo.write("VERSION", f"{version}\n")
    repo.commit("Set version")
    return repo


def test_check_fails_when_a_tag_on_head_disagrees_with_version(git_repo, run_script):
    _versioned(git_repo, "1.2.3")

    git_repo.tag("v1.2.4")
    assert run_script(VERSION_SH, "--check", cwd=git_repo.path).returncode != 0

    git_repo.git("tag", "-d", "v1.2.4")
    git_repo.tag("v1.2.3")
    assert run_script(VERSION_SH, "--check", cwd=git_repo.path).returncode == 0


def test_check_tag_compares_the_given_tag_with_version(git_repo, run_script):
    _versioned(git_repo, "1.2.3")

    assert run_script(VERSION_SH, "--check-tag", "v1.2.4", cwd=git_repo.path).returncode != 0
    assert run_script(VERSION_SH, "--check-tag", "v1.2.3", cwd=git_repo.path).returncode == 0


def test_shallow_clone_needs_the_build_number_override(make_repo, run_script, tmp_path):
    origin = _versioned(make_repo("origin"), "1.2.3")
    origin.write("notes.txt", "second commit\n")
    origin.commit("Second commit")

    clone = tmp_path / "clone"
    origin.git("clone", "--depth", "1", f"file://{origin.path}", str(clone))
    generated = clone / "build" / "generated" / "Version.xcconfig"

    assert run_script(VERSION_SH, cwd=clone).returncode != 0

    result = run_script(VERSION_SH, cwd=clone, env={"EIKON_BUILD_NUMBER": "42"})
    assert result.returncode == 0, result.stderr
    assert generated.is_file()

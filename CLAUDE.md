# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

Fresh scaffold — `main.py` is a hello-world stub, `pyproject.toml` lists no dependencies, `README.md` is empty. There is no application architecture to document yet.

## Environment

The dev shell is managed by [devenv](https://devenv.sh) + direnv. Entering the directory with direnv allowed will provision Python 3.12 and `uv` automatically (see `devenv.nix`). Outside that shell, the project assumes `uv` and Python 3.12 are on PATH.

## Commands

- Run the entrypoint: `uv run python main.py`
- Add a dependency: `uv add <pkg>` (updates `pyproject.toml` + lockfile)
- Sync env after pulling: `uv sync`
- Run the devenv smoke test: `devenv test` (currently just verifies git is present)

There is no test framework, linter, or formatter configured yet — add one before claiming a "run tests" or "lint" command works.

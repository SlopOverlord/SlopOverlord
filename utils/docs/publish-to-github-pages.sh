#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

normalize_repository() {
  local repository="$1"

  repository="${repository#https://}"
  repository="${repository#http://}"
  repository="${repository#ssh://git@}"

  if [[ "$repository" == git@*:* ]]; then
    repository="${repository#git@}"
    repository="${repository/:/\/}"
  fi

  if [[ "$repository" != */* ]]; then
    echo "Invalid GitHub repository value: ${repository}" >&2
    exit 1
  fi

  if [[ "$repository" != github.com/* ]]; then
    repository="github.com/${repository}"
  fi

  if [[ "$repository" != *.git ]]; then
    repository="${repository}.git"
  fi

  printf "%s" "$repository"
}

require_env GITHUB_PAGES_TOKEN
require_env GITHUB_PAGES_REPOSITORY

build_dir="${1:-site}"
if [[ ! -d "$build_dir" ]]; then
  echo "Build directory not found: ${build_dir}" >&2
  exit 1
fi

build_dir="$(cd "$build_dir" && pwd)"
target_branch="${GITHUB_PAGES_BRANCH:-gh-pages}"
author_name="${GITHUB_PAGES_AUTHOR_NAME:-gitlab-ci[bot]}"
author_email="${GITHUB_PAGES_AUTHOR_EMAIL:-gitlab-ci@example.com}"
repository="$(normalize_repository "${GITHUB_PAGES_REPOSITORY}")"
remote_url="https://x-access-token:${GITHUB_PAGES_TOKEN}@${repository}"
work_dir="$(mktemp -d)"
publish_dir="${work_dir}/publish"

cleanup() {
  rm -rf "$work_dir"
}

trap cleanup EXIT

mkdir -p "$publish_dir"
git init "$publish_dir" >/dev/null

cd "$publish_dir"
git checkout -b "$target_branch" >/dev/null 2>&1
git remote add origin "$remote_url"

if git fetch --depth 1 origin "$target_branch" >/dev/null 2>&1; then
  git reset --hard FETCH_HEAD >/dev/null
fi

rsync -a --delete --exclude ".git" "${build_dir}/" "${publish_dir}/"
touch .nojekyll

if [[ -n "${GITHUB_PAGES_CNAME:-}" ]]; then
  printf "%s\n" "${GITHUB_PAGES_CNAME}" > CNAME
fi

if [[ -z "$(git status --porcelain)" ]]; then
  echo "No documentation changes to publish."
  exit 0
fi

git config user.name "$author_name"
git config user.email "$author_email"
git add --all
git commit -m "Deploy docs from GitLab ${CI_COMMIT_SHORT_SHA:-manual}" >/dev/null
git push --force-with-lease origin "$target_branch"

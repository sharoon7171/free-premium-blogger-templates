#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
MARKER_START='<!-- download:start -->'
MARKER_END='<!-- download:end -->'
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

title_case() {
  printf '%s' "$1" | tr '-' ' ' | awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1'
}

theme_meta() {
  local path="$1" base vendor theme_name version_label theme_slug tag asset
  path="${path#./}"
  base="${path##*/}"
  base="${base%.xml}"
  vendor="$(slugify "${path%%/*}")"
  if [[ "$base" =~ ^(.+)[[:space:]]+([0-9]+([.][0-9]+)*)$ ]]; then
    theme_name="${BASH_REMATCH[1]}"
    version_label="${BASH_REMATCH[2]}"
  else
    theme_name="$base"
    version_label="—"
  fi
  theme_slug="$(slugify "$theme_name")"
  tag="${vendor}-${theme_slug}"
  asset="${base// /-}.xml"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$tag" "$asset" "$theme_name" "$version_label" "$vendor"
}

list_theme_xmls() {
  find . -type f -name '*.xml' \
    ! -path './.git/*' \
    ! -path './tmp/*' \
    ! -path './.github/*' \
    | sed 's|^\./||' \
    | LC_ALL=C sort
}

vendor_dirs() {
  find . -mindepth 1 -maxdepth 1 -type d \
    ! -name '.*' \
    ! -name 'scripts' \
    ! -name 'tmp' \
    ! -name 'node_modules' \
    | sed 's|^\./||' \
    | LC_ALL=C sort
}

is_managed_tag() {
  local tag="$1" dir vs
  while IFS= read -r dir; do
    vs="$(slugify "$dir")"
    [[ "$tag" == "$vs"-* ]] && return 0
  done < <(vendor_dirs)
  return 1
}

release_exists() {
  gh release view "$1" --repo "$REPO" >/dev/null 2>&1
}

upload_asset() {
  local tag="$1" src="$2" asset="$3" title="$4" notes="$5" staged old
  staged="$WORKDIR/$asset"
  cp "$src" "$staged"
  if release_exists "$tag"; then
    while IFS= read -r old; do
      [[ -z "$old" || "$old" == "$asset" ]] && continue
      gh release delete-asset "$tag" "$old" --repo "$REPO" --yes
    done < <(gh release view "$tag" --repo "$REPO" --json assets -q '.assets[].name')
    gh release upload "$tag" "$staged" --repo "$REPO" --clobber
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes "$notes"
  else
    gh release create "$tag" "$staged" --repo "$REPO" \
      --title "$title" \
      --notes "$notes" \
      --latest=false
  fi
}

delete_theme_release() {
  local tag="$1"
  release_exists "$tag" || return 0
  gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag
}

sync_one() {
  local path="$1" meta tag asset theme_name version_label vendor title notes
  [[ -f "$path" ]] || return 0
  meta="$(theme_meta "$path")"
  IFS=$'\t' read -r path tag asset theme_name version_label vendor <<<"$meta"
  title="${theme_name} (${vendor})"
  notes="Cleaned free Blogger theme XML.

Source: \`${path}\`

One stable release per theme. Pushes that change this file replace the download asset in place."
  upload_asset "$tag" "$path" "$asset" "$title" "$notes"
  printf 'synced %s -> %s/%s\n' "$path" "$tag" "$asset"
}

render_readme_section() {
  local path tag asset theme_name version_label vendor prev_vendor="" url heading
  while IFS=$'\t' read -r path tag asset theme_name version_label vendor; do
    if [[ "$vendor" != "$prev_vendor" ]]; then
      [[ -n "$prev_vendor" ]] && printf '\n'
      heading="$(title_case "$vendor")"
      printf '### %s\n\n' "$heading"
      printf '| Theme | Version | Download |\n'
      printf '| --- | --- | --- |\n'
      prev_vendor="$vendor"
    fi
    url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
    printf '| **%s** | %s | [Download XML](%s) |\n' "$theme_name" "$version_label" "$url"
  done < <(
    while IFS= read -r path; do
      theme_meta "$path"
    done < <(list_theme_xmls)
  )
}

update_readme() {
  local readme="$ROOT/README.md" section_file="$WORKDIR/section.md" out="$WORKDIR/README.out"
  [[ -f "$readme" ]] || return 0
  render_readme_section >"$section_file"

  if grep -Fq "$MARKER_START" "$readme" && grep -Fq "$MARKER_END" "$readme"; then
    awk -v start="$MARKER_START" -v end="$MARKER_END" -v sf="$section_file" '
      $0 == start {
        print
        while ((getline line < sf) > 0) print line
        close(sf)
        skip=1
        next
      }
      $0 == end { skip=0; print; next }
      !skip { print }
    ' "$readme" >"$out"
  else
    awk -v sf="$section_file" '
      /^## Download$/ {
        print
        print ""
        print "Themes are grouped by vendor. New vendor sections will be added as more cleaned XMLs are published."
        print ""
        print "<!-- download:start -->"
        while ((getline line < sf) > 0) print line
        close(sf)
        print "<!-- download:end -->"
        print ""
        skip=1
        next
      }
      skip && /^## / { skip=0 }
      !skip { print }
    ' "$readme" >"$out"
  fi
  mv "$out" "$readme"
}

FULL_SYNC=0
SYNC_PATHS=()
DELETE_PATHS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) FULL_SYNC=1; shift ;;
    --sync)
      shift
      [[ $# -gt 0 ]] || { echo "missing path after --sync" >&2; exit 1; }
      SYNC_PATHS+=("$1")
      shift
      ;;
    --delete)
      shift
      [[ $# -gt 0 ]] || { echo "missing path after --delete" >&2; exit 1; }
      DELETE_PATHS+=("$1")
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

EXPECTED_TAGS="$WORKDIR/expected.tags"
: >"$EXPECTED_TAGS"

if [[ "$FULL_SYNC" -eq 1 ]]; then
  SYNC_PATHS=()
  while IFS= read -r path; do
    SYNC_PATHS+=("$path")
  done < <(list_theme_xmls)
fi

for path in "${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}"; do
  [[ -z "${path:-}" ]] && continue
  IFS=$'\t' read -r _ tag _ _ _ _ <<<"$(theme_meta "$path")"
  printf '%s\n' "$tag" >>"$EXPECTED_TAGS"
done

if [[ "$FULL_SYNC" -eq 1 ]]; then
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    is_managed_tag "$tag" || continue
    grep -Fxq "$tag" "$EXPECTED_TAGS" && continue
    delete_theme_release "$tag"
    printf 'removed orphan release %s\n' "$tag"
  done < <(gh release list --repo "$REPO" --limit 1000 --json tagName -q '.[].tagName')
fi

for path in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
  [[ -z "${path:-}" ]] && continue
  IFS=$'\t' read -r _ tag _ _ _ _ <<<"$(theme_meta "$path")"
  delete_theme_release "$tag"
  printf 'deleted release for %s (%s)\n' "$path" "$tag"
done

for path in "${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}"; do
  [[ -z "${path:-}" ]] && continue
  sync_one "$path"
done

update_readme
printf 'README download section refreshed\n'

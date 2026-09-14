#!/bin/bash
# Rename video files into Jellyfin's folder/file layout, using TMDB to look up
# the proper title, year and IMDb id.
# Usage:
#   ./jellyfin-renamer.sh /path/to/folder      # scan, look up, review, rename
#   ./jellyfin-renamer.sh -n /path/to/folder   # dry run: print the plan, touch nothing
#
# Needs curl, jq, and TMDB_API_KEY set in config.sh (or exported in the env).
# Renames happen in place, inside the folder you pass:
#   Films: Title (Year) [imdbid-tt0000000]/Title (Year) [imdbid-tt0000000].mkv
#   TV:    Show (Year) [imdbid-tt0000000]/Season 01/Show (Year) - S01E02.mkv
# Anything ambiguous (several TMDB hits, or none) is shown as a numbered list
# so you can pick, search again with a different title, or skip the file.
set -euo pipefail

CONFIG="$(dirname "$0")/config.sh"
[[ -f "$CONFIG" ]] && source "$CONFIG"
TMDB_API_KEY="${TMDB_API_KEY:-}"
TMDB_BASE="${TMDB_BASE:-https://api.themoviedb.org/3}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) ROOT="$1" ;;
  esac
  shift
done

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "Error: $tool is required but not installed." >&2; exit 1; }
done
if [[ -z "$TMDB_API_KEY" ]]; then
  echo "Error: TMDB_API_KEY is not set. Add it to config.sh (free key: themoviedb.org → Settings → API)." >&2
  exit 1
fi
if [[ -z "$ROOT" ]]; then
  echo "Error: no folder given." >&2; usage >&2; exit 1
fi
if [[ ! -d "$ROOT" ]]; then
  echo "Error: folder does not exist: $ROOT" >&2; exit 1
fi
ROOT="$(cd "$ROOT" && pwd)"

# ---------------------------------------------------------------------------
# Filename parsing
# ---------------------------------------------------------------------------

# Strip release-group noise (resolution, codec, source, group tags) from a title.
clean_title() {
  sed -E \
    -e 's/[._]+/ /g' \
    -e 's/\b(1080p|2160p|720p|480p|4k|uhd|hdr|dv|x264|x265|h264|h265|hevc|avc|aac|ac3|dts|dd5 ?1|ddp ?5 ?1|atmos|bluray|blu-ray|brrip|bdrip|webrip|web-dl|webdl|hdtv|dvdrip|remux|proper|repack|extended|unrated|internal|amzn|nf|dsnp|hmax|multi|dual|subbed|dubbed|10bit|8bit)\b/ /Ig' \
    -e 's/\b(yify|yts|rarbg|evo|fgt|ntb|tgx|galaxytv|ettv|eztv|sparks|cmrg|edith|flux|ntg|tepes|successfulcrab)\b/ /Ig' \
    -e 's/[][(){}]/ /g' \
    -e 's/-[[:space:]]*$//' \
    -e 's/ {2,}/ /g' \
    -e 's/^ +//; s/ +$//' <<<"$1"
}

# Sets P_TYPE (tv|movie), P_TITLE, P_YEAR, P_SEASON, P_EPISODE from a basename.
parse_name() {
  local base="${1%.*}"
  P_TYPE="" P_TITLE="" P_YEAR="" P_SEASON="" P_EPISODE=""
  local re_sxe='^(.*)[. _-]+[sS]([0-9]{1,2})[. _-]*[eE]([0-9]{1,3})'
  local re_xx='^(.*)[. _-]+([0-9]{1,2})x([0-9]{1,3})([^0-9]|$)'
  local re_year='(^|[^0-9])((19|20)[0-9]{2})([^0-9]|$)'
  local re_movie='^(.*)[. _(-]+((19|20)[0-9]{2})([^0-9]|$)'
  local re_trailing_year='^(.*) ((19|20)[0-9]{2})$'

  if [[ $base =~ $re_sxe ]] || [[ $base =~ $re_xx ]]; then
    P_TYPE=tv
    P_TITLE="$(clean_title "${BASH_REMATCH[1]}")"
    P_SEASON=$((10#${BASH_REMATCH[2]}))
    P_EPISODE=$((10#${BASH_REMATCH[3]}))
    [[ $base =~ $re_year ]] && P_YEAR="${BASH_REMATCH[2]}"
    # "Show 2019" → title "Show", year 2019
    if [[ $P_TITLE =~ $re_trailing_year ]]; then
      P_TITLE="${BASH_REMATCH[1]}"; P_YEAR="${BASH_REMATCH[2]}"
    fi
  elif [[ $base =~ $re_movie ]]; then
    P_TYPE=movie
    P_TITLE="$(clean_title "${BASH_REMATCH[1]}")"
    P_YEAR="${BASH_REMATCH[2]}"
  else
    P_TYPE=movie
    P_TITLE="$(clean_title "$base")"
  fi
}

# ---------------------------------------------------------------------------
# TMDB
# ---------------------------------------------------------------------------

tmdb_get() {
  local path="$1"; shift
  curl -fsS --get "$TMDB_BASE$path" --data-urlencode "api_key=$TMDB_API_KEY" "$@"
}

# Fills CANDS with "id<TAB>title<TAB>year<TAB>overview" lines (max 6).
# Retries without the year if a year-filtered search comes back empty.
search_tmdb() {
  local type="$1" query="$2" year="${3:-}" json filter
  local endpoint year_param
  if [[ $type == tv ]]; then
    endpoint=/search/tv; year_param=first_air_date_year
    filter='.results[:6][] | [.id, .name, ((.first_air_date // "")[:4]), ((.overview // "")[:110] | gsub("\\s+"; " "))] | @tsv'
  else
    endpoint=/search/movie; year_param=year
    filter='.results[:6][] | [.id, .title, ((.release_date // "")[:4]), ((.overview // "")[:110] | gsub("\\s+"; " "))] | @tsv'
  fi
  CANDS=()
  if [[ -n $year ]]; then
    json="$(tmdb_get "$endpoint" --data-urlencode "query=$query" --data-urlencode "$year_param=$year")" || return 1
    mapfile -t CANDS < <(jq -r "$filter" <<<"$json")
    [[ ${#CANDS[@]} -gt 0 ]] && return 0
  fi
  json="$(tmdb_get "$endpoint" --data-urlencode "query=$query")" || return 1
  mapfile -t CANDS < <(jq -r "$filter" <<<"$json")
}

imdb_id() {
  local type="$1" id="$2"
  if [[ $type == tv ]]; then
    tmdb_get "/tv/$id/external_ids" | jq -r '.imdb_id // empty'
  else
    tmdb_get "/movie/$id" | jq -r '.imdb_id // empty'
  fi
}

# ---------------------------------------------------------------------------
# Resolving a file to a TMDB entry
# ---------------------------------------------------------------------------

# Interactive picker. Uses P_* and CANDS; sets CHOSEN (tsv line) or returns 1 to skip.
choose() {
  local rel="$1" ans i line id title year overview
  while true; do
    echo
    echo "── $rel"
    echo "   parsed as: \"$P_TITLE\"${P_YEAR:+ ($P_YEAR)} · $P_TYPE${P_SEASON:+ S${P_SEASON}E${P_EPISODE}}"
    if [[ ${#CANDS[@]} -eq 0 ]]; then
      echo "   no TMDB results for that title"
    else
      i=0
      for line in "${CANDS[@]}"; do
        i=$((i+1))
        IFS=$'\t' read -r id title year overview <<<"$line"
        printf '   %d) %s%s\n' "$i" "$title" "${year:+ ($year)}"
        [[ -n $overview ]] && printf '      %s…\n' "$overview"
      done
    fi
    echo "   s) skip this file   q) search with a different title   t) treat as $([[ $P_TYPE == tv ]] && echo film || echo TV)"
    read -rp "   choice: " ans </dev/tty
    case "$ans" in
      s|S) return 1 ;;
      q|Q)
        read -rp "   search for: " P_TITLE </dev/tty
        read -rp "   year (blank for any): " P_YEAR </dev/tty
        search_tmdb "$P_TYPE" "$P_TITLE" "$P_YEAR" || echo "   TMDB request failed, try again"
        ;;
      t|T)
        if [[ $P_TYPE == tv ]]; then
          P_TYPE=movie; P_SEASON=""; P_EPISODE=""
        else
          P_TYPE=tv
          read -rp "   season number: " P_SEASON </dev/tty
          read -rp "   episode number: " P_EPISODE </dev/tty
          P_SEASON=$((10#$P_SEASON)); P_EPISODE=$((10#$P_EPISODE))
        fi
        search_tmdb "$P_TYPE" "$P_TITLE" "$P_YEAR" || echo "   TMDB request failed, try again"
        ;;
      ''|*[!0-9]*) echo "   ?" ;;
      *)
        if (( ans >= 1 && ans <= ${#CANDS[@]} )); then
          CHOSEN="${CANDS[ans-1]}"; return 0
        fi
        echo "   ?"
        ;;
    esac
  done
}

# Sets CHOSEN to "id<TAB>title<TAB>year" and CHOSEN_IMDB, or returns 1 to skip.
# Auto-accepts a single hit or a unique exact title(+year) match; otherwise asks.
resolve() {
  local rel="$1" exact=() line id title year _
  search_tmdb "$P_TYPE" "$P_TITLE" "$P_YEAR" || { echo "   TMDB request failed for $rel" >&2; return 1; }
  CHOSEN=""
  if [[ ${#CANDS[@]} -eq 1 ]]; then
    CHOSEN="${CANDS[0]}"
  elif [[ ${#CANDS[@]} -gt 1 ]]; then
    for line in "${CANDS[@]}"; do
      IFS=$'\t' read -r id title year _ <<<"$line"
      if [[ ${title,,} == "${P_TITLE,,}" && ( -z $P_YEAR || $year == "$P_YEAR" ) ]]; then
        exact+=("$line")
      fi
    done
    [[ ${#exact[@]} -eq 1 ]] && CHOSEN="${exact[0]}"
  fi
  if [[ -z $CHOSEN ]]; then
    choose "$rel" || return 1
  fi
  IFS=$'\t' read -r id _ _ _ <<<"$CHOSEN"
  CHOSEN_IMDB="$(imdb_id "$P_TYPE" "$id" || true)"
}

# Strip characters that are illegal in filenames.
sanitize() { sed 's#[/\\:*?"<>|]##g; s/  */ /g; s/^ //; s/ $//' <<<"$1"; }

# Builds the destination path (relative to ROOT) from P_*, CHOSEN, CHOSEN_IMDB, and the extension.
build_dest() {
  local ext="$1" id title year _ base tag
  IFS=$'\t' read -r id title year _ <<<"$CHOSEN"
  title="$(sanitize "$title")"
  year="${year:-$P_YEAR}"
  base="$title${year:+ ($year)}"
  tag="${CHOSEN_IMDB:+ [imdbid-$CHOSEN_IMDB]}"
  if [[ $P_TYPE == tv ]]; then
    printf '%s%s/Season %02d/%s - S%02dE%02d.%s' "$base" "$tag" "$P_SEASON" "$base" "$P_SEASON" "$P_EPISODE" "$ext"
  else
    printf '%s%s/%s%s.%s' "$base" "$tag" "$base" "$tag" "$ext"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mapfile -d '' -t FILES < <(
  find "$ROOT" -type f -regextype posix-extended \
    -iregex '.*\.(mkv|mp4|avi|mov|m4v|wmv|flv|webm|mpg|mpeg|ts|m2ts)$' -print0 | sort -z
)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No video files found under $ROOT"
  exit 0
fi

echo "Jellyfin renamer"
echo "  folder: $ROOT"
echo "  files:  ${#FILES[@]}"
[[ $DRY_RUN -eq 1 ]] && echo "  mode:   dry run (nothing will be renamed)"
echo

# Cache lookups per parsed title so a whole season only asks once.
declare -A CACHE
PLAN_SRC=() PLAN_DEST=()
SKIPPED=() ALREADY=()

i=0
for f in "${FILES[@]}"; do
  i=$((i+1))
  rel="${f#"$ROOT/"}"
  name="$(basename "$f")"
  ext="${name##*.}"; ext="${ext,,}"
  parse_name "$name"
  echo "[$i/${#FILES[@]}] $rel"

  key="$P_TYPE|${P_TITLE,,}|$P_YEAR"
  if [[ -v CACHE[$key] ]]; then
    cached="${CACHE[$key]}"
  else
    if resolve "$rel"; then
      # keep the resolved type/season alongside the choice in case the user toggled it
      cached="$P_TYPE"$'\x1f'"$CHOSEN"$'\x1f'"$CHOSEN_IMDB"
    else
      cached="SKIP"
    fi
    CACHE[$key]="$cached"
  fi

  if [[ $cached == SKIP ]]; then
    SKIPPED+=("$rel"); echo "    skipped"; continue
  fi
  IFS=$'\x1f' read -r P_TYPE CHOSEN CHOSEN_IMDB <<<"$cached"
  dest="$(build_dest "$ext")"
  if [[ $rel == "$dest" ]]; then
    ALREADY+=("$rel"); echo "    already in place"; continue
  fi
  PLAN_SRC+=("$rel"); PLAN_DEST+=("$dest")
  echo "    → $dest"
done

echo
echo "Plan: ${#PLAN_SRC[@]} to rename, ${#ALREADY[@]} already in place, ${#SKIPPED[@]} skipped"
if [[ ${#PLAN_SRC[@]} -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi
echo
for idx in "${!PLAN_SRC[@]}"; do
  echo "  ${PLAN_SRC[idx]}"
  echo "    → ${PLAN_DEST[idx]}"
done
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run — nothing renamed."
  exit 0
fi

read -rp "Apply ${#PLAN_SRC[@]} rename(s) inside $ROOT? [y/N] " ans </dev/tty
[[ $ans == y || $ans == Y ]] || { echo "Aborted."; exit 0; }
echo

done_count=0
for idx in "${!PLAN_SRC[@]}"; do
  src="$ROOT/${PLAN_SRC[idx]}"
  dst="$ROOT/${PLAN_DEST[idx]}"
  if [[ -e $dst ]]; then
    echo "  ✗ exists, left alone: ${PLAN_DEST[idx]}"
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  mv -n "$src" "$dst"
  done_count=$((done_count+1))
  echo "  ✓ ${PLAN_DEST[idx]}"
  # remove now-empty folders the file came from, stopping at ROOT
  d="$(dirname "$src")"
  while [[ $d != "$ROOT" ]] && rmdir "$d" 2>/dev/null; do
    d="$(dirname "$d")"
  done
done

echo
echo "Done. $done_count/${#PLAN_SRC[@]} renamed into Jellyfin structure."

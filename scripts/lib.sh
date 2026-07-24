#!/usr/bin/env bash

is_clean_review() {
  local file=${1:?review file is required}
  local stripped
  stripped=$(tr -d '[:space:]' < "$file")
  [ -z "$stripped" ] \
    || [ "$stripped" = "Noissuesfound." ] \
    || [ "$stripped" = "Noissuesfound" ]
}

is_complete_clean_review() {
  local work_dir=${1:?work directory is required}
  [ ! -s "$work_dir/overflow.note" ] \
    && [ ! -s "$work_dir/review.failures" ] \
    && [ "$(tr -d '[:space:]' < "$work_dir/review.md")" = "Noissuesfound." ]
}

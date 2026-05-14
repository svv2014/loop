#!/usr/bin/env bash
# lib/stage.sh — loop:stage:* label helpers.
#
# Provides the stage → trigger label mapping and derivation logic used by the
# reconciler and the backfill script.  Relies on lib/workflow.sh (must be
# sourced first) so the mapping is workflow-aware rather than hardcoded.
#
# Public API:
#   loop_stage_for_labels  <slug> <labels_csv>      → stage name or ""
#   loop_trigger_label_for_stage <slug> <stage>     → trigger label string
#   loop_ensure_stage_labels_exist <repo>           → gh label create idempotent
#
# Bash 3.x compatible (no associative arrays).

# Idempotent guard.
if [ "${_LOOP_STAGE_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_LOOP_STAGE_LOADED=1

# Ordered list of (stage trigger-canonical) pairs, highest priority first.
# Used by loop_stage_for_labels to pick the winning stage when a ticket has
# multiple trigger labels.  The "canonical" is the workflow-stage id so we
# can call loop_stage_trigger to get the project-specific actual label.
#
# Format: "<stage_name> <workflow_stage_id>"
# blocked / done are terminal and handled specially (no workflow stage).
_LOOP_STAGE_PRIORITY="merge qa review dev po"

# Colour palette for loop:stage:* labels (hex, no leading #).
_LOOP_STAGE_COLOR_PO="1D76DB"
_LOOP_STAGE_COLOR_DEV="0075CA"
_LOOP_STAGE_COLOR_REVIEW="9370DB"
_LOOP_STAGE_COLOR_QA="FFD700"
_LOOP_STAGE_COLOR_MERGE="32CD32"
_LOOP_STAGE_COLOR_BLOCKED="8B0000"
_LOOP_STAGE_COLOR_DONE="006400"

# loop_trigger_label_for_stage <slug> <stage_name>
# Returns the actual trigger label for a pipeline stage, honouring per-project
# workflow overrides via loop_stage_trigger (lib/workflow.sh).
# For terminal stages (blocked, done) returns the label name directly since
# they are not workflow-defined trigger stages.
loop_trigger_label_for_stage() {
    local slug="$1" stage="$2"
    case "$stage" in
        po)      loop_stage_trigger "$slug" po      issue 2>/dev/null || echo "loop:action:po" ;;
        dev)     loop_stage_trigger "$slug" dev     issue 2>/dev/null || echo "loop:action:dev" ;;
        review)  loop_stage_trigger "$slug" review  pr    2>/dev/null || echo "loop:action:review" ;;
        qa)      loop_stage_trigger "$slug" qa      pr    2>/dev/null || echo "loop:action:qa" ;;
        merge)   loop_stage_trigger "$slug" merge   pr    2>/dev/null || echo "loop:result:qa-pass" ;;
        blocked) echo "loop:result:blocked" ;;
        done)    echo "loop:result:done" ;;
        *)       return 1 ;;
    esac
}

# loop_stage_for_labels <slug> <labels_csv>
# Given a comma-separated list of labels currently on a ticket, returns the
# highest-priority pipeline stage name.  Returns "" when no known trigger
# label is present.
loop_stage_for_labels() {
    local slug="$1" labels_csv="$2"
    local stage actual

    # Blocked and done are terminal — check first, highest precedence.
    case ",$labels_csv," in
        *",loop:result:blocked,"*|*",blocked,"*) echo "blocked"; return 0 ;;
    esac

    for stage in $_LOOP_STAGE_PRIORITY; do
        actual=$(loop_trigger_label_for_stage "$slug" "$stage" 2>/dev/null) || continue
        [ -z "$actual" ] && continue
        case ",$labels_csv," in
            *",${actual},"*) echo "$stage"; return 0 ;;
        esac
        # Also check deprecated synonyms for this stage (belt-and-suspenders,
        # so backfill works on repos that haven't gone through alias-rename yet).
        case "$stage" in
            po)
                case ",$labels_csv," in
                    *",po-review,"*|*",needs-po,"*) echo "po"; return 0 ;;
                esac ;;
            dev)
                case ",$labels_csv," in
                    *",dev,"*|*",plan,"*|*",in-progress,"*|*",needs-dev,"*) echo "dev"; return 0 ;;
                esac ;;
            review)
                case ",$labels_csv," in
                    *",review-pending,"*|*",needs-review,"*) echo "review"; return 0 ;;
                esac ;;
            qa)
                case ",$labels_csv," in
                    *",ready-for-qa,"*|*",needs-qa,"*) echo "qa"; return 0 ;;
                esac ;;
            merge)
                case ",$labels_csv," in
                    *",qa-pass,"*|*",loop:result:qa-pass,"*) echo "merge"; return 0 ;;
                esac ;;
        esac
    done

    echo ""
}

# loop_ensure_stage_labels_exist <repo>
# Creates all loop:stage:* labels in <repo> if they do not exist.
# Idempotent — gh label create with ||true.
loop_ensure_stage_labels_exist() {
    local repo="$1"
    local existing
    existing=$(gh label list --repo "$repo" --limit 200 --json name \
               --jq '.[].name' 2>/dev/null || echo "")

    _create_stage_label() {
        local name="$1" desc="$2" color="$3"
        if ! printf '%s\n' "$existing" | grep -qxF "$name"; then
            gh label create "$name" --repo "$repo" \
               --description "$desc" --color "$color" 2>/dev/null || true
        fi
    }

    _create_stage_label "loop:stage:po"      "Pipeline stage: PO triage"        "$_LOOP_STAGE_COLOR_PO"
    _create_stage_label "loop:stage:dev"     "Pipeline stage: development"       "$_LOOP_STAGE_COLOR_DEV"
    _create_stage_label "loop:stage:review"  "Pipeline stage: human review"      "$_LOOP_STAGE_COLOR_REVIEW"
    _create_stage_label "loop:stage:qa"      "Pipeline stage: QA"                "$_LOOP_STAGE_COLOR_QA"
    _create_stage_label "loop:stage:merge"   "Pipeline stage: ready to merge"    "$_LOOP_STAGE_COLOR_MERGE"
    _create_stage_label "loop:stage:blocked" "Pipeline stage: blocked"           "$_LOOP_STAGE_COLOR_BLOCKED"
    _create_stage_label "loop:stage:done"    "Pipeline stage: done/merged"       "$_LOOP_STAGE_COLOR_DONE"
}

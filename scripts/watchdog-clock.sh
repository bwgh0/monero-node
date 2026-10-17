#!/usr/bin/env bash
# The clock of the watchdog: an AWS EventBridge rule sends a workflow_dispatch
# event for .github/workflows/watchdog.yml every 10 minutes. GitHub drops or
# delays scheduled runs, so the clock is outside GitHub. See "The clock" in
# docs/monitoring.md.
#
# Run it by hand on the laptop. It uses the AWS CLI with the profile
# "default" (the Monero One account) and the region us-east-1.
# WATCHDOG_CLOCK_PROFILE sets a different profile. It makes no change on
# the boxes.
#
# The parts. All have the name monero-node-watchdog-clock:
#   connection       An EventBridge connection with API key auth. The key is
#                    the header "Authorization: Bearer <token>". EventBridge
#                    keeps the token in Secrets Manager.
#   api destination  POST to the dispatches endpoint of watchdog.yml.
#   role             An IAM role for events.amazonaws.com. Its only
#                    permission is events:InvokeApiDestination on that API
#                    destination.
#   rule             rate(10 minutes) on the default event bus. Its target
#                    sends the body {"ref":"main"} and the headers Accept and
#                    X-GitHub-Api-Version. EventBridge sets the User-Agent
#                    and the Content-Type (application/json). The AWS docs
#                    list the headers that an API destination removes or
#                    sets. Accept and X-GitHub-Api-Version are not on them.
#
# The token is a fine-grained GitHub token for the repository
# bwgh0/monero-node only, with the permission Actions: read and write. Keep
# it in the macOS Keychain:
#   security add-generic-password -U -s monero-node-watchdog-clock -a github -w
# The last -w asks for the token, so the token stays off the command line.
# This script reads the token into a mode-600 file in a temp dir and gives
# the file to the AWS CLI (file://). A trap deletes the dir. The script never
# prints the token, and it turns off set -x while it holds the token.

set -euo pipefail

NAME=monero-node-watchdog-clock
REGION=us-east-1
PROFILE=${WATCHDOG_CLOCK_PROFILE:-default}
POLICY_NAME=invoke-watchdog-api-destination
TARGET_ID=github-dispatch
REPO=bwgh0/monero-node
ENDPOINT="https://api.github.com/repos/${REPO}/actions/workflows/watchdog.yml/dispatches"
RUNS_URL="https://api.github.com/repos/${REPO}/actions/workflows/watchdog.yml/runs?per_page=5"
KEYCHAIN_SERVICE=$NAME
KEYCHAIN_ACCOUNT=github
# A fine-grained token. A classic token (ghp_...) can reach all the
# repositories of the account, so the script refuses it.
TOKEN_RE='^github_pat_[A-Za-z0-9_]{20,}$'
NOT_FOUND_RE='ResourceNotFoundException|NoSuchEntity'
export AWS_PAGER=""

usage() {
    cat <<'EOF'
Usage: scripts/watchdog-clock.sh [--dry-run] [--yes] COMMAND

Commands:
  apply         Creates the parts that are missing and updates the others.
                You can run it again at any time. It keeps the token of a
                connection that exists (rotate-token changes the token).
  status        Shows the state of the parts, the invocations of the last
                2 hours and the last 5 watchdog runs on GitHub. It exits 1
                when a part is missing or not in its good state.
  rotate-token  Gives the connection the token that is now in the Keychain.
  delete        Removes all the parts. It asks first, unless --yes.

Options:
  --dry-run     Runs only the calls that read. Prints the calls that make
                changes, and the JSON files that they get.
  --yes         delete asks no question.
EOF
}

die() { printf 'watchdog-clock: %s\n' "$*" >&2; exit 1; }
warn() { printf 'watchdog-clock: WARNING: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }

DRY_RUN=0
YES=0
CMD=""
while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=1 ;;
        --yes) YES=1 ;;
        -h | --help) usage; exit 0 ;;
        apply | status | rotate-token | delete)
            [[ -z $CMD ]] || die "give one command only"
            CMD=$1
            ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
[[ -n $CMD ]] || { usage >&2; exit 2; }

umask 077
tmp_root=${TMPDIR:-/tmp}
TMP=$(mktemp -d "${tmp_root%/}/watchdog-clock.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The dry-run lines go to fd 3, so a $(...) around a call keeps only the
# output of AWS.
exec 3>&1

aws_cmd() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

# A call that makes a change. With --dry-run it prints the call.
aws_write() {
    if ((DRY_RUN)); then
        printf 'would run: aws --profile %q --region %q' "$PROFILE" "$REGION" >&3
        printf ' %q' "$@" >&3
        printf '\n' >&3
        return 0
    fi
    aws_cmd "$@"
}

# With --dry-run, prints a JSON file that a call gets.
show_file() {
    ((DRY_RUN)) || return 0
    printf '  with %s:\n' "${2##*/}" >&3
    sed 's/^/    /' "$2" >&3
    printf '  (%s)\n' "$1" >&3
}

# A call that reads. It puts the output in OUT and returns 1 when the part
# does not exist. It stops the script on all other errors.
lookup() {
    OUT=""
    if OUT=$(aws_cmd "$@" 2>"$TMP/err"); then
        return 0
    fi
    if grep -Eq "$NOT_FOUND_RE" "$TMP/err"; then
        return 1
    fi
    cat "$TMP/err" >&2
    die "the call aws $1 $2 failed"
}

whoami_aws() {
    ACCOUNT=$(aws_cmd sts get-caller-identity --query Account --output text) ||
        die "no AWS login for the profile $PROFILE. Check: aws sts get-caller-identity --profile $PROFILE"
    local mode=""
    ((DRY_RUN)) && mode=", dry run (no changes)"
    note "AWS account $ACCOUNT, profile $PROFILE, region ${REGION}${mode}"
}

# Writes the --auth-parameters file of the connection, mode 600. With
# --dry-run it checks the token and writes a placeholder in its place.
write_auth_file() {
    local xtrace=0 token=""
    [[ $- == *x* ]] && xtrace=1
    set +x
    command -v security >/dev/null 2>&1 || die "the macOS command security is missing. Run this script on the laptop."
    token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null) ||
        die "no token in the Keychain. Add it with: security add-generic-password -U -s $KEYCHAIN_SERVICE -a $KEYCHAIN_ACCOUNT -w"
    if ! [[ $token =~ $TOKEN_RE ]]; then
        token=""
        die "the Keychain item $KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT is not a fine-grained GitHub token (github_pat_...)"
    fi
    ((DRY_RUN)) && token="<the token from the Keychain>"
    AUTH_FILE="$TMP/auth-parameters.json"
    : >"$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    printf '{"ApiKeyAuthParameters":{"ApiKeyName":"Authorization","ApiKeyValue":"Bearer %s"}}\n' \
        "$token" >"$AUTH_FILE"
    token=""
    ((xtrace)) && set -x
    return 0
}

wait_authorized() {
    local i state=""
    if ((DRY_RUN)); then
        note "would wait until the connection is AUTHORIZED"
        return 0
    fi
    for ((i = 0; i < 30; i++)); do
        state=$(aws_cmd events describe-connection --name "$NAME" --query ConnectionState --output text)
        if [[ $state == AUTHORIZED ]]; then
            note "connection: AUTHORIZED. AWS has the token. The next dispatch shows if GitHub takes it."
            return 0
        fi
        sleep 2
    done
    die "the connection is $state after 60 seconds. It must be AUTHORIZED."
}

cmd_apply() {
    whoami_aws
    local conn_arn conn_state dest_arn role_arn failed

    # 1. The connection. Only a new connection gets the token.
    if lookup events describe-connection --name "$NAME" \
        --query '[ConnectionArn,ConnectionState]' --output text; then
        read -r conn_arn conn_state <<<"$OUT"
        note "connection: exists, $conn_state. apply keeps its token."
        [[ $conn_state == AUTHORIZED ]] ||
            warn "the connection is $conn_state. Put a good token in the Keychain and run: scripts/watchdog-clock.sh rotate-token"
    else
        write_auth_file
        conn_arn=$(aws_write events create-connection --name "$NAME" --authorization-type API_KEY \
            --description "GitHub token that dispatches the watchdog of $REPO" \
            --auth-parameters "file://$AUTH_FILE" --query ConnectionArn --output text)
        show_file "the token is in the real file only" "$AUTH_FILE"
        rm -f "$AUTH_FILE"
        if ((DRY_RUN)); then
            conn_arn="<the ConnectionArn of the new connection>"
        else
            note "connection: created"
        fi
        wait_authorized
    fi

    # 2. The API destination
    local dest_args=(--name "$NAME" --connection-arn "$conn_arn" --invocation-endpoint "$ENDPOINT"
        --http-method POST --invocation-rate-limit-per-second 1
        --description "Dispatches the watchdog workflow of $REPO")
    if lookup events describe-api-destination --name "$NAME" --query ApiDestinationArn --output text; then
        dest_arn=$OUT
        aws_write events update-api-destination "${dest_args[@]}" >/dev/null
        ((DRY_RUN)) || note "api destination: updated"
    else
        dest_arn=$(aws_write events create-api-destination "${dest_args[@]}" \
            --query ApiDestinationArn --output text)
        if ((DRY_RUN)); then
            dest_arn="<the ApiDestinationArn of the new API destination>"
        else
            note "api destination: created"
        fi
    fi

    # 3. The role. Its trust policy and its permission get written each time.
    printf '%s\n' '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",' \
        '"Principal":{"Service":"events.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >"$TMP/trust.json"
    printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"events:InvokeApiDestination","Resource":"%s"}]}\n' \
        "$dest_arn" >"$TMP/policy.json"
    if lookup iam get-role --role-name "$NAME" --query Role.Arn --output text; then
        role_arn=$OUT
        aws_write iam update-assume-role-policy --role-name "$NAME" \
            --policy-document "file://$TMP/trust.json"
    else
        role_arn="arn:aws:iam::${ACCOUNT}:role/${NAME}"
        aws_write iam create-role --role-name "$NAME" \
            --description "Lets EventBridge dispatch the watchdog of $REPO" \
            --assume-role-policy-document "file://$TMP/trust.json" >/dev/null
    fi
    show_file "the trust policy" "$TMP/trust.json"
    aws_write iam put-role-policy --role-name "$NAME" --policy-name "$POLICY_NAME" \
        --policy-document "file://$TMP/policy.json"
    show_file "the only permission of the role" "$TMP/policy.json"
    ((DRY_RUN)) || note "role: $role_arn"

    # 4. The rule and its target
    aws_write events put-rule --name "$NAME" --schedule-expression 'rate(10 minutes)' --state ENABLED \
        --description "Dispatches .github/workflows/watchdog.yml of $REPO (scripts/watchdog-clock.sh)" >/dev/null
    printf '[{"Id":"%s","Arn":"%s","RoleArn":"%s","Input":"{\\"ref\\":\\"main\\"}",%s,%s}]\n' \
        "$TARGET_ID" "$dest_arn" "$role_arn" \
        '"HttpParameters":{"HeaderParameters":{"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"}}' \
        '"RetryPolicy":{"MaximumRetryAttempts":2,"MaximumEventAgeInSeconds":300}' >"$TMP/targets.json"
    failed=$(aws_write events put-targets --rule "$NAME" --targets "file://$TMP/targets.json" \
        --query 'FailedEntries[].[TargetId,ErrorCode,ErrorMessage]' --output text)
    show_file "the target" "$TMP/targets.json"
    [[ -z $failed ]] || die "put-targets failed: $failed"
    if ((DRY_RUN)); then
        note "Dry run: no changes."
    else
        note "rule: ENABLED, rate(10 minutes), target $TARGET_ID"
        note "The first dispatch comes in 10 minutes or less. Then run: scripts/watchdog-clock.sh status"
    fi
}

cmd_rotate_token() {
    whoami_aws
    lookup events describe-connection --name "$NAME" --query ConnectionState --output text ||
        die "there is no connection $NAME. Run: scripts/watchdog-clock.sh apply"
    note "connection: exists, $OUT"
    write_auth_file
    aws_write events update-connection --name "$NAME" --authorization-type API_KEY \
        --auth-parameters "file://$AUTH_FILE" >/dev/null
    show_file "the token is in the real file only" "$AUTH_FILE"
    rm -f "$AUTH_FILE"
    wait_authorized
    ((DRY_RUN)) || note "Run scripts/watchdog-clock.sh status in 10 minutes. It must show a new workflow_dispatch run."
}

# The sum of an AWS/Events metric of the rule in the last 2 hours
metric_sum() {
    local now start end
    now=$(date +%s)
    start=$(date -u -r $((now - 7200)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
        date -u -d "@$((now - 7200))" +%Y-%m-%dT%H:%M:%SZ)
    end=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)
    aws_cmd cloudwatch get-metric-statistics --namespace AWS/Events --metric-name "$1" \
        --dimensions "Name=RuleName,Value=$NAME" --start-time "$start" --end-time "$end" \
        --period 600 --statistics Sum --query 'sum(Datapoints[].Sum)' --output text
}

cmd_status() {
    whoami_aws
    local bad=0 state rest invocations failed tab=$'\t'
    if lookup events describe-connection --name "$NAME" \
        --query '[ConnectionState,AuthorizationType,LastAuthorizedTime,StateReason]' --output text; then
        read -r state rest <<<"$OUT"
        rest=${rest//$tab/, }
        note "connection       $state ($rest)"
        [[ $state == AUTHORIZED ]] || bad=1
    else
        note "connection       missing"
        bad=1
    fi
    if lookup events describe-api-destination --name "$NAME" \
        --query '[ApiDestinationState,HttpMethod,InvocationEndpoint]' --output text; then
        read -r state rest <<<"$OUT"
        rest=${rest//$tab/, }
        note "api destination  $state ($rest)"
        [[ $state == ACTIVE ]] || bad=1
    else
        note "api destination  missing"
        bad=1
    fi
    if lookup events describe-rule --name "$NAME" --query '[State,ScheduleExpression]' --output text; then
        read -r state rest <<<"$OUT"
        rest=${rest//$tab/, }
        note "rule             $state ($rest)"
        [[ $state == ENABLED ]] || bad=1
        if lookup events list-targets-by-rule --rule "$NAME" \
            --query "Targets[?Id=='$TARGET_ID'].[Id,Input]" --output text && [[ -n $OUT ]]; then
            note "target           ${OUT//$tab/, }"
        else
            note "target           missing"
            bad=1
        fi
    else
        note "rule             missing"
        bad=1
    fi
    if lookup iam get-role-policy --role-name "$NAME" --policy-name "$POLICY_NAME" \
        --query PolicyName --output text; then
        note "role             $NAME with the policy $OUT"
    else
        note "role             missing, or it has no policy $POLICY_NAME"
        bad=1
    fi
    invocations=$(metric_sum Invocations) || invocations="?"
    failed=$(metric_sum FailedInvocations) || failed="?"
    note "last 2 hours     ${invocations%.0} invocations, ${failed%.0} failed invocations"
    if command -v security >/dev/null 2>&1 &&
        security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
        note "keychain         the token item is there"
    else
        note "keychain         no item $KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT on this machine"
    fi
    note "last watchdog runs (public GitHub API):"
    if curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$RUNS_URL" >"$TMP/runs.json" 2>"$TMP/err"; then
        python3 - "$TMP/runs.json" <<'EOF' || note "  the answer of the GitHub API is not in the known format"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    runs = json.load(f)["workflow_runs"]
for r in runs:
    print("  {}  {:<17} {:<6} {:<11} {}".format(
        r["created_at"], r["event"], r["head_branch"], r["status"], r.get("conclusion") or "-"))
if not runs:
    print("  none")
EOF
    else
        note "  the GitHub API call failed: $(head -n 1 "$TMP/err")"
    fi
    return "$bad"
}

# A call that deletes. A part that is gone already is OK.
gone_ok() {
    if ((DRY_RUN)); then
        aws_write "$@"
        return 0
    fi
    if aws_cmd "$@" >/dev/null 2>"$TMP/err"; then
        note "done: $1 $2"
    elif grep -Eq "$NOT_FOUND_RE" "$TMP/err"; then
        note "gone already: $1 $2"
    else
        cat "$TMP/err" >&2
        die "the call aws $1 $2 failed"
    fi
}

cmd_delete() {
    whoami_aws
    local answer=""
    if ((!YES && !DRY_RUN)); then
        [[ -t 0 ]] || die "delete asks a question first. Add --yes to run it with no terminal."
        read -r -p "Delete the watchdog clock in the AWS account $ACCOUNT? The watchdog then gets no runs. Type yes: " answer
        [[ $answer == yes ]] || die "nothing deleted"
    fi
    gone_ok events remove-targets --rule "$NAME" --ids "$TARGET_ID"
    gone_ok events delete-rule --name "$NAME"
    gone_ok events delete-api-destination --name "$NAME"
    gone_ok events delete-connection --name "$NAME"
    gone_ok iam delete-role-policy --role-name "$NAME" --policy-name "$POLICY_NAME"
    gone_ok iam delete-role --role-name "$NAME"
    if ((DRY_RUN)); then
        note "Dry run: no changes."
    else
        note "Deleted. The watchdog gets no more runs, so Watchdog Silent fires on the boxes in 40 minutes."
    fi
}

case $CMD in
    apply) cmd_apply ;;
    status) cmd_status ;;
    rotate-token) cmd_rotate_token ;;
    delete) cmd_delete ;;
esac

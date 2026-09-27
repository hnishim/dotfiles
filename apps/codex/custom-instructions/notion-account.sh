#!/bin/bash

# Shared account selection for the setup command and the installed sync job.
# Tokens stay in shell memory and are supplied only through NOTION_API_TOKEN.

notion_config_value() {
    local file=$1
    local key=$2
    local count

    count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$file")
    [ "$count" -le 1 ] || return 2
    [ "$count" -eq 1 ] || return 0
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

notion_valid_id() {
    printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f]{32}$|^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
}

notion_ids_equal() {
    local actual=$1
    local expected=$2

    if ! notion_valid_id "$actual" || ! notion_valid_id "$expected"; then
        [ "$actual" = "$expected" ]
        return $?
    fi
    actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]' | tr -d '-')
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]' | tr -d '-')
    [ "$actual" = "$expected" ]
}

notion_account_load_config() {
    local config=$1
    local allow_legacy=${2:-0}
    local has_account_fields=false
    local notion_id

    ACCOUNT_ID=$(notion_config_value "$config" account_id) || return 1
    CREDENTIAL_SOURCE=$(notion_config_value "$config" credential_source) || return 1
    EXPECTED_USER_ID=$(notion_config_value "$config" expected_user_id) || return 1
    ACCOUNT_WORKSPACE_ID=$(notion_config_value "$config" workspace_id) || return 1
    ACCOUNT_CUSTOM_PAGE_ID=$(notion_config_value "$config" custom_instructions_page_id) || return 1
    ACCOUNT_PROFILE_PAGE_ID=$(notion_config_value "$config" user_profile_page_id) || return 1
    ACCOUNT_SKILLS_DATA_SOURCE_ID=$(notion_config_value "$config" skills_data_source_id) || return 1

    if grep -Eq '^(account_id|credential_source|expected_user_id)=' "$config"; then
        has_account_fields=true
    fi
    ACCOUNT_CONFIG_LEGACY=false
    if [ "$has_account_fields" = false ] && [ "$allow_legacy" = 1 ] &&
       [ "$(basename -- "$config")" = notion-pages.conf ]; then
        ACCOUNT_ID=molcure
        CREDENTIAL_SOURCE=ntn-default
        EXPECTED_USER_ID=''
        ACCOUNT_CONFIG_LEGACY=true
    elif [ "$has_account_fields" = false ]; then
        printf '[ERROR] Notion設定に明示的なaccount_idとcredential_sourceがありません。\n' >&2
        return 1
    fi

    case "$ACCOUNT_ID" in
        molcure|personal) ;;
        *) printf '[ERROR] 未知のNotion account_idです。\n' >&2; return 1 ;;
    esac
    case "$CREDENTIAL_SOURCE" in
        ntn-default)
            [ "$ACCOUNT_ID" = molcure ] || {
                printf '[ERROR] ntn既定認証はMOLCURE以外に指定できません。\n' >&2
                return 1
            }
            ;;
        keychain) ;;
        *) printf '[ERROR] 未知のNotion credential_sourceです。\n' >&2; return 1 ;;
    esac
    if [ "$ACCOUNT_ID" = personal ] && [ "$CREDENTIAL_SOURCE" != keychain ]; then
        printf '[ERROR] 個人用Notion認証にはKeychainを指定してください。\n' >&2
        return 1
    fi
    for notion_id in \
        "$ACCOUNT_WORKSPACE_ID" \
        "$ACCOUNT_CUSTOM_PAGE_ID" \
        "$ACCOUNT_PROFILE_PAGE_ID" \
        "$ACCOUNT_SKILLS_DATA_SOURCE_ID"; do
        notion_valid_id "$notion_id" || {
            printf '[ERROR] Notion設定に不正または未設定のIDがあります。\n' >&2
            return 1
        }
    done
}

notion_account_select_credential() {
    local security_executable
    ACCOUNT_TOKEN=''
    ACCOUNT_USE_NTN_DEFAULT=false

    case "$CREDENTIAL_SOURCE" in
        ntn-default)
            if [ "${ACCOUNT_CONFIG_LEGACY:-false}" = true ]; then
                ACCOUNT_USE_NTN_DEFAULT=true
                return 0
            fi
            if ! ACCOUNT_TOKEN=$(unset NOTION_API_TOKEN NOTION_KEYRING NOTION_WORKSPACE_ID
                "$NTN_EXECUTABLE" auth token < /dev/null 2>/dev/null); then
                ACCOUNT_TOKEN=''
            fi
            ;;
        keychain)
            security_executable=$(command -v security 2>/dev/null || true)
            [ -n "$security_executable" ] || return 1
            if ! ACCOUNT_TOKEN=$("$security_executable" find-generic-password \
                -s "my.notion.$ACCOUNT_ID" -w < /dev/null 2>/dev/null); then
                ACCOUNT_TOKEN=''
            fi
            ;;
        *) return 1 ;;
    esac

    [ -n "$ACCOUNT_TOKEN" ]
}

notion_account_run_cli() {
    if [ "${ACCOUNT_USE_NTN_DEFAULT:-false}" = true ]; then
        (
            unset NOTION_API_TOKEN
            NOTION_WORKSPACE_ID="$ACCOUNT_WORKSPACE_ID" "$NTN_EXECUTABLE" "$@"
        )
        return $?
    fi
    [ -n "${ACCOUNT_TOKEN:-}" ] || return 1
    NOTION_API_TOKEN="$ACCOUNT_TOKEN" \
    NOTION_WORKSPACE_ID="$ACCOUNT_WORKSPACE_ID" \
        "$NTN_EXECUTABLE" "$@"
}

notion_account_verify_identity() {
    local expected_user_id=$1
    local expected_workspace_id=$2
    local response_file=$3
    local jq_executable=${4:-/usr/bin/jq}

    NOTION_ACTUAL_USER_ID=''
    NOTION_ACTUAL_WORKSPACE_ID=''
    if ! notion_account_run_cli whoami --json < /dev/null >"$response_file" 2>/dev/null; then
        return 1
    fi
    NOTION_ACTUAL_USER_ID=$("$jq_executable" -er '.bot.owner.user.id // .user.id // empty' "$response_file" 2>/dev/null) || return 1
    NOTION_ACTUAL_WORKSPACE_ID=$("$jq_executable" -er '.bot.workspace_id // .workspace_id // empty' "$response_file" 2>/dev/null) || return 1
    [ -n "$NOTION_ACTUAL_USER_ID" ] && [ -n "$NOTION_ACTUAL_WORKSPACE_ID" ] || return 1
    notion_ids_equal "$NOTION_ACTUAL_WORKSPACE_ID" "$expected_workspace_id" || return 1
    [ -z "$expected_user_id" ] || notion_ids_equal "$NOTION_ACTUAL_USER_ID" "$expected_user_id"
}

notion_account_verify_resource() {
    local kind=$1
    local expected_id=$2
    local expected_workspace_id=$3
    local response_file=$4
    local allow_legacy_shape=${5:-0}
    local jq_executable=${6:-/usr/bin/jq}
    local expected_object actual_object actual_id actual_workspace parent_type legacy_data_source_shape=false

    case "$kind" in
        page) expected_object=page ;;
        data_source) expected_object=data_source ;;
        *) return 1 ;;
    esac
    actual_object=$("$jq_executable" -er '.object // empty' "$response_file" 2>/dev/null) || return 1
    actual_id=$("$jq_executable" -er '.id // empty' "$response_file" 2>/dev/null) || return 1
    notion_ids_equal "$actual_id" "$expected_id" || return 1
    if [ "$actual_object" != "$expected_object" ]; then
        if [ "$allow_legacy_shape" = 1 ] && [ "$kind" = data_source ] && [ "$actual_object" = page ]; then
            legacy_data_source_shape=true
        else
            return 1
        fi
    fi

    actual_workspace=$("$jq_executable" -r '.workspace_id // .parent.workspace_id // empty' "$response_file" 2>/dev/null) || return 1
    parent_type=$("$jq_executable" -r '.parent.type // empty' "$response_file" 2>/dev/null) || return 1
    if [ "$legacy_data_source_shape" = true ]; then
        [ -z "$actual_workspace" ] && [ -z "$parent_type" ] || return 1
        return 0
    fi
    if [ -n "$actual_workspace" ]; then
        notion_ids_equal "$actual_workspace" "$expected_workspace_id" || return 1
        return 0
    fi

    if [ "$allow_legacy_shape" = 1 ] && [ -z "$parent_type" ]; then
        return 0
    fi
    case "$kind:$parent_type" in
        page:workspace|page:page_id|page:block_id|page:data_source_id|data_source:database_id|data_source:data_source_id)
            return 0
            ;;
        *) return 1 ;;
    esac
}

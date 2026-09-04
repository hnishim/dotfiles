#!/bin/bash

set -euo pipefail

domain='com.if.Amphetamine'

write_integer_and_verify() {
    local key="$1"
    local value="$2"

    defaults write "$domain" "$key" -int "$value"
    [ "$(defaults read "$domain" "$key")" = "$value" ]
    [ "$(defaults read-type "$domain" "$key")" = "Type is integer" ]
}

write_integer_and_verify 'Start Session At Launch' 0
write_integer_and_verify 'Start Session On Wake' 0
write_integer_and_verify 'Enable Triggers' 1

trigger_data_plist='(
    {
        AllowDisplaySleep = 1;
        App = ChatGPT;
        Enabled = 1;
        Name = ChatGPT;
        TypeIDs = (1);
    }
)'
defaults write "$domain" 'Trigger Data' "$trigger_data_plist"

trigger_data=$(defaults read "$domain" 'Trigger Data')
[ "$(defaults read-type "$domain" 'Trigger Data')" = "Type is array" ]
first_line=$(printf '%s\n' "$trigger_data" | sed -n '1p')
last_line=$(printf '%s\n' "$trigger_data" | tail -n 1)
[ "$first_line" = "(" ]
[ "$last_line" = ")" ]
[ "$(printf '%s\n' "$trigger_data" | grep -Fc '{')" -eq 1 ]
for field in 'AllowDisplaySleep = 1;' 'App = ChatGPT;' 'Enabled = 1;' \
    'Name = ChatGPT;' 'TypeIDs =         (' '        );'; do
    grep -Fq -- "$field" <<<"$trigger_data"
done
grep -Fxq '            1' <<<"$trigger_data"
printf '%s\n' "$trigger_data" | plutil -convert xml1 -o - - >/dev/null

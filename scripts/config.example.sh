# cc-alarm-larkcli recipient config
# Copy to ~/.config/cc-alarm-larkcli/config.sh.
#
# RECIPIENT IS OPTIONAL. If you leave BOTH RECIPIENT_USER_ID and
# RECIPIENT_CHAT_ID unset/empty, notify.sh resolves the CURRENT LOGGED-IN
# USER via `lark-cli auth status` and sends to YOU. So after
# `lark-cli auth login`, no recipient config is needed — it just works.
#
# Set ONE of the two below ONLY to override the default (DM someone else, or
# send to a group). Setting BOTH is an error (ambiguous) → exit 2.

# OPTIONAL: DM a user (open_id, ou_xxx). Leave unset to send to yourself.
RECIPIENT_USER_ID="ou_REPLACE_ME"

# OPTIONAL: send to a chat (chat_id, oc_xxx). Leave commented/unset to send
# to yourself. Mutually exclusive with RECIPIENT_USER_ID.
# RECIPIENT_CHAT_ID="oc_REPLACE_ME"

# Optional: sender identity passed to `lark-cli --as`. Defaults to 'bot', so
# notifications work out of the box with the scopes already granted by
# `lark-cli auth login`. Set AS="user" ONLY if you want messages to appear
# FROM YOURSELF — that requires granting the `im:message.send_as_user` scope
# (see the lark-shared skill); leave it unset for the default bot path.
# AS="bot"

# Optional: min seconds between 'progress' sends. Default 300.
# THROTTLE_SECONDS=300

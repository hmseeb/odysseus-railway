#!/bin/sh
# Write the JSON-enabled settings file, then hand over to SearXNG's own
# entrypoint. Mirrors what upstream's compose does with an inline entrypoint
# and a bind-mounted template, minus the bind mount that Railway cannot provide.
set -eu

TEMPLATE=/usr/local/share/odysseus/searxng-settings.yml
TARGET=/etc/searxng/settings.yml

# Regenerate when the file is missing, empty, or still carries the placeholder
# from an earlier boot of this image. An operator who has edited their own
# settings in place keeps them.
if [ ! -s "$TARGET" ] || grep -q '__SEARXNG_SECRET__' "$TARGET"; then
    secret="${SEARXNG_SECRET:-}"
    if [ -z "$secret" ]; then
        secret="$(python -c 'import secrets; print(secrets.token_urlsafe(48))')"
    fi
    mkdir -p /etc/searxng
    sed "s|__SEARXNG_SECRET__|${secret}|g" "$TEMPLATE" > "$TARGET"
fi

exec /usr/local/searxng/entrypoint.sh "$@"

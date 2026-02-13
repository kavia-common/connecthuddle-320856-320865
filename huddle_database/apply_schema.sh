#!/bin/bash
set -euo pipefail

# Apply ConnectHuddle PostgreSQL schema (idempotent)
# - Uses db_connection.txt as the authoritative connection source
# - Executes SQL statements ONE AT A TIME (per container rules)
# - Safe to re-run: uses IF NOT EXISTS and DO blocks with existence checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "❌ db_connection.txt not found. Start the database first (startup.sh) so it can be generated."
  exit 1
fi

CONN="$(cat db_connection.txt)"

echo "Applying PostgreSQL schema using: ${CONN}"

run_sql () {
  local sql="$1"
  # Use ON_ERROR_STOP so any failure stops the script.
  ${CONN} -v ON_ERROR_STOP=1 -c "$sql"
}

echo "== Extensions =="
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

echo "== Tables =="
# Users
run_sql "CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  display_name text NOT NULL,
  avatar_url text,
  password_hash text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_email_format_chk CHECK (position('@' in email) > 1)
);"

# Case-insensitive unique email (via expression index)
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS users_email_ci_uq ON users (lower(email));"

# Huddles
run_sql "CREATE TABLE IF NOT EXISTS huddles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  host_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  is_private boolean NOT NULL DEFAULT false,
  join_code text,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  CONSTRAINT huddles_status_chk CHECK (status IN ('active','ended','archived')),
  CONSTRAINT huddles_join_code_len_chk CHECK (join_code IS NULL OR length(join_code) BETWEEN 6 AND 32)
);"

# Unique join codes when present
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS huddles_join_code_uq ON huddles (join_code) WHERE join_code IS NOT NULL;"
run_sql "CREATE INDEX IF NOT EXISTS huddles_host_user_id_idx ON huddles (host_user_id);"
run_sql "CREATE INDEX IF NOT EXISTS huddles_status_created_at_idx ON huddles (status, created_at DESC);"

# Participants / members
run_sql "CREATE TABLE IF NOT EXISTS huddle_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  huddle_id uuid NOT NULL REFERENCES huddles(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member',
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz,
  is_muted boolean NOT NULL DEFAULT false,
  is_video_enabled boolean NOT NULL DEFAULT true,
  CONSTRAINT huddle_participants_role_chk CHECK (role IN ('host','moderator','member'))
);"

# A user should not be duplicated in the same huddle (prevents duplicate rows in participant lists)
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS huddle_participants_huddle_user_uq ON huddle_participants (huddle_id, user_id);"
# Core queries: list participants in a huddle, list huddles for a user
run_sql "CREATE INDEX IF NOT EXISTS huddle_participants_huddle_joined_idx ON huddle_participants (huddle_id, joined_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS huddle_participants_user_joined_idx ON huddle_participants (user_id, joined_at DESC);"

# Chat messages
run_sql "CREATE TABLE IF NOT EXISTS chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  huddle_id uuid NOT NULL REFERENCES huddles(id) ON DELETE CASCADE,
  sender_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  message_type text NOT NULL DEFAULT 'text',
  content text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_messages_type_chk CHECK (message_type IN ('text','system','media')),
  CONSTRAINT chat_messages_content_chk CHECK (
    (message_type = 'text' AND content IS NOT NULL AND length(content) > 0)
    OR (message_type <> 'text')
  )
);"

# Core queries: load recent messages for a huddle; user message history
run_sql "CREATE INDEX IF NOT EXISTS chat_messages_huddle_created_idx ON chat_messages (huddle_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS chat_messages_sender_created_idx ON chat_messages (sender_user_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS chat_messages_metadata_gin_idx ON chat_messages USING GIN (metadata);"

# Notifications
run_sql "CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  huddle_id uuid REFERENCES huddles(id) ON DELETE CASCADE,
  notification_type text NOT NULL,
  title text,
  body text,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  CONSTRAINT notifications_read_time_chk CHECK ((is_read = false AND read_at IS NULL) OR (is_read = true))
);"

# Core queries: unread notifications for user, sorted newest first
run_sql "CREATE INDEX IF NOT EXISTS notifications_user_created_idx ON notifications (user_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS notifications_user_unread_idx ON notifications (user_id, created_at DESC) WHERE is_read = false;"
run_sql "CREATE INDEX IF NOT EXISTS notifications_data_gin_idx ON notifications USING GIN (data);"

echo "== Updated-at triggers =="
# A lightweight trigger function to update updated_at on row update.
run_sql "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'set_updated_at') THEN
    CREATE FUNCTION set_updated_at()
    RETURNS trigger
    LANGUAGE plpgsql
    AS \$fn\$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    \$fn\$;
  END IF;
END
\$\$;"

# Attach triggers (only if not already present).
run_sql "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_set_updated_at') THEN
    CREATE TRIGGER trg_users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_huddles_set_updated_at') THEN
    CREATE TRIGGER trg_huddles_set_updated_at
    BEFORE UPDATE ON huddles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END
\$\$;"

echo "✅ Schema applied successfully."

package main

import (
	"database/sql"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// ClearUnreadCount must never move last_read_at backwards. RecalculateUnreadCounts()
// rebuilds unread from that column on every startup, so a regressed timestamp
// resurrects already-read messages -- the exact failure that left this account with
// thousands of phantom unread after the LID migration.
func TestClearUnreadCountNeverRegressesLastReadAt(t *testing.T) {
	db, err := sql.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE chats (jid TEXT PRIMARY KEY, name TEXT,
		last_message_time TIMESTAMP, unread_count INTEGER DEFAULT 0,
		marked_as_unread BOOLEAN DEFAULT 0, last_read_at TIMESTAMP)`); err != nil {
		t.Fatal(err)
	}
	store := &MessageStore{db: db}

	readAt := func(jid string) string {
		var got string
		if err := db.QueryRow("SELECT COALESCE(last_read_at,'') FROM chats WHERE jid = ?", jid).Scan(&got); err != nil {
			t.Fatal(err)
		}
		return got
	}

	base := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	older, newer := base.Add(-time.Hour), base.Add(time.Hour)

	for _, seed := range []struct {
		name, jid string
		initial   any
	}{
		{"null", "a@s.whatsapp.net", nil},
		{"empty string", "b@s.whatsapp.net", ""}, // migrations left rows like this
	} {
		if _, err := db.Exec("INSERT INTO chats (jid, unread_count, last_read_at) VALUES (?, 5, ?)", seed.jid, seed.initial); err != nil {
			t.Fatal(err)
		}

		// First read stamps the column regardless of its prior emptiness.
		if err := store.ClearUnreadCount(seed.jid, base); err != nil {
			t.Fatal(err)
		}
		stamped := readAt(seed.jid)
		if stamped == "" {
			t.Fatalf("%s: last_read_at still empty after clear", seed.name)
		}

		// A late receipt for an earlier read must not drag it back.
		if err := store.ClearUnreadCount(seed.jid, older); err != nil {
			t.Fatal(err)
		}
		if got := readAt(seed.jid); got != stamped {
			t.Errorf("%s: regressed on older receipt: %q -> %q", seed.name, stamped, got)
		}

		// A genuinely newer read still advances it.
		if err := store.ClearUnreadCount(seed.jid, newer); err != nil {
			t.Fatal(err)
		}
		if got := readAt(seed.jid); got == stamped {
			t.Errorf("%s: failed to advance on newer receipt (stuck at %q)", seed.name, got)
		}

		var unread int
		var marked bool
		if err := db.QueryRow("SELECT unread_count, marked_as_unread FROM chats WHERE jid = ?", seed.jid).Scan(&unread, &marked); err != nil {
			t.Fatal(err)
		}
		if unread != 0 || marked {
			t.Errorf("%s: unread_count=%d marked_as_unread=%v, want 0/false", seed.name, unread, marked)
		}
	}
}

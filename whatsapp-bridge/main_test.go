package main

import (
	"database/sql"
	"fmt"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// The unread count history sync reports is WhatsApp's own, and it has to survive
// RecalculateUnreadCounts() running seconds later on connect. Before SetUnreadCount
// anchored last_read_at, recalc rebuilt the number from a stale timestamp and
// overwrote the authoritative one -- a chat WhatsApp reported as 2 drifted to 146.
func TestHistorySyncUnreadSurvivesRecalculate(t *testing.T) {
	db, err := sql.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`
		CREATE TABLE chats (jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP,
			unread_count INTEGER DEFAULT 0, marked_as_unread BOOLEAN DEFAULT 0, last_read_at TIMESTAMP);
		CREATE TABLE messages (id TEXT, chat_jid TEXT, sender TEXT, content TEXT,
			timestamp TIMESTAMP, is_from_me BOOLEAN, media_type TEXT, filename TEXT, url TEXT,
			media_key BLOB, file_sha256 BLOB, file_enc_sha256 BLOB, file_length INTEGER,
			PRIMARY KEY (id, chat_jid));`); err != nil {
		t.Fatal(err)
	}
	store := &MessageStore{db: db}

	const jid = "group@g.us"
	// A stale last_read_at with plenty of incoming traffic after it: left alone,
	// recalc would call all 20 of these unread.
	if _, err := db.Exec("INSERT INTO chats (jid, unread_count, last_read_at) VALUES (?, 146, ?)",
		jid, time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	for i := 0; i < 20; i++ {
		if _, err := db.Exec(`INSERT INTO messages (id, chat_jid, sender, content, timestamp, is_from_me)
			VALUES (?, ?, 'them', 'hi', ?, 0)`, fmt.Sprintf("m%d", i), jid, base.Add(time.Duration(i)*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}

	// History sync reports the truth: only 2 are actually unread.
	if err := store.SetUnreadCount(jid, 2, false); err != nil {
		t.Fatal(err)
	}
	var got int
	if err := db.QueryRow("SELECT unread_count FROM chats WHERE jid = ?", jid).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != 2 {
		t.Fatalf("SetUnreadCount stored %d, want 2", got)
	}

	// ...and it must still be 2 after the connect-time rebuild.
	if err := store.RecalculateUnreadCounts(); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow("SELECT unread_count FROM chats WHERE jid = ?", jid).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != 2 {
		t.Errorf("recalculate overwrote the authoritative count: got %d, want 2", got)
	}
}

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

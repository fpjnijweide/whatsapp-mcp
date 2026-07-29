-- Reconcile unread state against the phone, which is authoritative.
--
-- The bridge derives unread from receipts it happened to observe while running.
-- Reads that happened otherwise are never learned, so counts only ever drift
-- upward: Donjons & Dragons sat at 146 against the phone's 2, and several group
-- backlogs (moroccan tunes 243, CS Nerds 187, Robert van der Klis 191) had been
-- fully read for months. The phone's unread filter listed exactly 24 chats; this
-- transcribes that list and clears everything else.
--
-- A green dot on the phone means "manually marked unread" -> unread_count 0 with
-- marked_as_unread 1. A number means that many genuinely unread messages.
--
-- Run with the bridge stopped.

CREATE TEMP TABLE truth(jid TEXT PRIMARY KEY, unread INTEGER, flagged INTEGER);
INSERT INTO truth VALUES
  ('447756644416@s.whatsapp.net',  0, 1),  -- Adam Oxley (read, then re-marked unread)
  ('120363426014319746@g.us',      3, 0),  -- Utrecht zuipen
  ('120363279906714441@g.us',      0, 1),  -- Fall guys
  ('14038700963@s.whatsapp.net',   0, 1),  -- nim
  ('31626113744@s.whatsapp.net',   2, 0),  -- Paul Nijweide
  ('31610634490@s.whatsapp.net',   2, 0),  -- Emily Rendel
  ('120363166686168593@g.us',      2, 0),  -- Donjons & Dragons
  ('14388348001@s.whatsapp.net',   0, 1),  -- Ben Hudson
  ('31644588165@s.whatsapp.net',   2, 0),  -- Shreyash Ravi
  ('31634017769@s.whatsapp.net',   0, 1),  -- Frederik Nijweide (You)
  ('31681681048@s.whatsapp.net',   2, 0),  -- Thijs Rakels
  ('31616792002@s.whatsapp.net',   0, 1),  -- Linda Goorts
  ('31648786484@s.whatsapp.net',   0, 1),  -- Ilya Da Vinci
  ('447557992045@s.whatsapp.net',  0, 1),  -- +44 7557 992045
  ('31618017240@s.whatsapp.net',   3, 0),  -- Marco Nijweide
  ('31681704948@s.whatsapp.net',   0, 1),  -- Jeffrey Zwart
  ('31613992236@s.whatsapp.net',   0, 1),  -- Siep ten Thije
  ('31681255137@s.whatsapp.net',   3, 0),  -- Francesco Zaccarian
  ('31623770665@s.whatsapp.net',   2, 0),  -- Lennart Kerkvliet
  ('31681087123@s.whatsapp.net',   1, 0),  -- Frank ten Have
  ('31623514243@s.whatsapp.net',   7, 0),  -- Noé Corneille
  ('31642489964@s.whatsapp.net',   2, 0),  -- Yorrit van de Kamp
  ('31612482834@s.whatsapp.net',   1, 0),  -- +31 6 12482834
  ('34646299973@s.whatsapp.net',   0, 1);  -- Alex van Melinda

BEGIN;

-- 1. Anything the phone did not list is read.
UPDATE chats SET unread_count = 0, marked_as_unread = 0
 WHERE jid NOT IN (SELECT jid FROM truth);

-- 2. Apply the phone's numbers.
UPDATE chats
   SET unread_count     = (SELECT unread  FROM truth WHERE truth.jid = chats.jid),
       marked_as_unread = (SELECT flagged FROM truth WHERE truth.jid = chats.jid)
 WHERE jid IN (SELECT jid FROM truth);

-- 3. Anchor last_read_at so the counts survive a restart.
--
--    RecalculateUnreadCounts() rebuilds unread_count on every startup as
--    "incoming messages newer than last_read_at". Setting counts without moving
--    that timestamp would let the next restart re-derive the very numbers this
--    script just corrected. Anchoring on the (unread_count+1)-th newest incoming
--    message makes recalc reproduce the phone's number exactly: the comparison is
--    strictly greater-than, so that message is excluded and precisely
--    unread_count newer ones are counted.
WITH ranked AS (
    SELECT chat_jid, timestamp,
           ROW_NUMBER() OVER (PARTITION BY chat_jid ORDER BY timestamp DESC) AS rn
      FROM messages
     WHERE is_from_me = 0
)
UPDATE chats
   SET last_read_at = COALESCE(
           (SELECT timestamp FROM ranked
             WHERE ranked.chat_jid = chats.jid
               AND ranked.rn = chats.unread_count + 1),
           last_read_at);

COMMIT;

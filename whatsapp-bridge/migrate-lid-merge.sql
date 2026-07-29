-- Merge LID-forked chats back onto their phone-number rows.
--
-- WhatsApp migrated this account to LID addressing on ~2026-07-27. From then on
-- every 1:1 message arrived under a new xxx@lid JID, so each contact ended up
-- with two chat rows: the old @s.whatsapp.net row (real name + all history, now
-- silent) and a new @lid row (live messages, numeric name). This collapses them.
--
-- Run with whatsapp.db attached as `w` and the bridge stopped.

CREATE TEMP TABLE jidmap AS
SELECT lid || '@lid'            AS lid_jid,
       pn  || '@s.whatsapp.net' AS pn_jid,
       lid                      AS lid_user,
       pn                       AS pn_user
FROM w.whatsmeow_lid_map;

CREATE INDEX temp.jidmap_lid ON jidmap(lid_jid);
CREATE INDEX temp.jidmap_pn  ON jidmap(pn_jid);

BEGIN;

-- 1. Repoint messages onto the phone JID. OR IGNORE skips rows whose (id, chat_jid)
--    already exists under the phone JID -- those are the same message delivered
--    twice by history sync, once per address form.
UPDATE OR IGNORE messages
   SET chat_jid = (SELECT pn_jid FROM jidmap WHERE lid_jid = messages.chat_jid)
 WHERE chat_jid IN (SELECT lid_jid FROM jidmap);

-- Whatever is still on a LID chat_jid collided above, i.e. is a duplicate.
DELETE FROM messages WHERE chat_jid IN (SELECT lid_jid FROM jidmap);

-- 2. Normalise sender, which is stored bare for phone users but as a full
--    'xxx@lid' string for LID ones (group participants migrated too).
UPDATE messages
   SET sender = (SELECT pn_user FROM jidmap WHERE lid_jid = messages.sender)
 WHERE sender IN (SELECT lid_jid FROM jidmap);

UPDATE messages
   SET sender = (SELECT pn_user FROM jidmap WHERE lid_user = messages.sender)
 WHERE sender IN (SELECT lid_user FROM jidmap);

-- 3. Carry the LID row's unread state onto the phone row before dropping it.
--    The LID row is the live one, so its counters are the truthful ones; the
--    phone row's counters froze at the migration.
UPDATE chats
   SET unread_count = COALESCE(
           (SELECT l.unread_count FROM chats l JOIN jidmap j ON l.jid = j.lid_jid
             WHERE j.pn_jid = chats.jid), chats.unread_count),
       marked_as_unread = COALESCE(
           (SELECT MAX(l.marked_as_unread, chats.marked_as_unread) FROM chats l JOIN jidmap j ON l.jid = j.lid_jid
             WHERE j.pn_jid = chats.jid), chats.marked_as_unread),
       last_read_at = COALESCE(
           (SELECT MAX(COALESCE(l.last_read_at, ''), COALESCE(chats.last_read_at, '')) FROM chats l JOIN jidmap j ON l.jid = j.lid_jid
             WHERE j.pn_jid = chats.jid), chats.last_read_at)
 WHERE jid IN (SELECT j.pn_jid FROM jidmap j JOIN chats l ON l.jid = j.lid_jid);

DELETE FROM chats
 WHERE jid IN (SELECT j.lid_jid FROM jidmap j JOIN chats p ON p.jid = j.pn_jid);

-- 4. LID rows with a known mapping but no phone twin: just rekey them.
UPDATE chats
   SET jid = (SELECT pn_jid FROM jidmap WHERE lid_jid = chats.jid)
 WHERE jid IN (SELECT lid_jid FROM jidmap);

-- 5. Rebuild last_message_time from the merged message set.
UPDATE chats
   SET last_message_time = COALESCE(
           (SELECT MAX(timestamp) FROM messages WHERE chat_jid = chats.jid),
           last_message_time);

-- 6. Resolve names that are still raw digits, now that rows are phone-keyed and
--    whatsmeow_contacts (also phone-keyed) can actually match.
UPDATE chats
   SET name = COALESCE(
           NULLIF((SELECT c.full_name  FROM w.whatsmeow_contacts c WHERE c.their_jid = chats.jid), ''),
           NULLIF((SELECT c.push_name  FROM w.whatsmeow_contacts c WHERE c.their_jid = chats.jid), ''),
           name)
 WHERE name IS NULL OR name = '' OR name GLOB '[0-9]*';

-- 7. Drop phantom unread counts. If the newest message in a chat is one I sent,
--    nothing after it can be unread -- this is what left Maurits on 284 and Paul
--    on 200. The manual marked_as_unread flag is deliberately left alone.
--
UPDATE chats
   SET unread_count = 0
 WHERE unread_count > 0
   AND (SELECT is_from_me FROM messages WHERE chat_jid = chats.jid
         ORDER BY timestamp DESC LIMIT 1) = 1;

-- 8. Make last_read_at agree with the unread_count we just settled on.
--
--    Everything above is otherwise undone on the next bridge start.
--    RecalculateUnreadCounts() rebuilds unread_count from scratch as "incoming
--    messages newer than last_read_at" for every row where last_read_at is set,
--    so a merged count sitting behind a stale pre-migration timestamp is
--    re-inflated on restart -- Maurits back to 277, Ralph back to 37.
--
--    Anchoring last_read_at on the (unread_count+1)-th newest incoming message
--    makes recalc a no-op: the comparison is strictly greater-than, so that
--    message is excluded and exactly unread_count newer ones are counted. At
--    unread_count = 0 this is the newest incoming message, which counts nothing.
--    Rows with a NULL last_read_at are left alone -- recalc skips them too.
--    Ranked with a window function rather than LIMIT 1 OFFSET unread_count,
--    because SQLite will not resolve a correlated outer column inside OFFSET.
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
           last_read_at)
 WHERE last_read_at IS NOT NULL;

COMMIT;

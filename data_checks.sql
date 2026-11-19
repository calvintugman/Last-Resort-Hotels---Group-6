-- ============================================================
-- DATA CHECKS for hotel.db (hotel_schema.sql + hotel_data.sql)
-- Run:  sqlite3 /tmp/hotel.db < data_checks.sql
-- Each check prints a label and its result. "Expected" is in the comment.
-- ============================================================
.headers on
.mode box

-- 1. Database file is internally sound.                     Expected: ok
PRAGMA integrity_check;

-- 2. No row points to a missing parent row.                 Expected: (no rows)
PRAGMA foreign_key_check;

-- 3. Row counts for the main tables.
--    Expected: 5447 | 4259 | 53 | 368 | 20050 | 5312 | 30825 | 5140 | 55243
SELECT (SELECT COUNT(*) FROM reservation)     AS reservations,
       (SELECT COUNT(*) FROM room_assignment) AS assignments,
       (SELECT COUNT(*) FROM event)           AS events,
       (SELECT COUNT(*) FROM meeting_booking) AS bookings,
       (SELECT COUNT(*) FROM service_usage)   AS usages,
       (SELECT COUNT(*) FROM invoice)         AS invoices,
       (SELECT COUNT(*) FROM invoice_line)    AS invoice_lines,
       (SELECT COUNT(*) FROM payment)         AS payments,
       (SELECT COUNT(*) FROM access_log)      AS access_logs;

-- 4. Reservation status matches the stay times ("now" = 2026-11-17 22:00).
--    Expected: every count in the "wrong" columns is 0
SELECT r.status,
       COUNT(*) AS assignments,
       SUM(r.status = 'Checked Out' AND a.checkOutDateTime >  '2026-11-17 22:00:00') AS wrong_out,
       SUM(r.status = 'Checked In'  AND NOT (a.checkInDateTime <= '2026-11-17 22:00:00'
                                         AND a.checkOutDateTime > '2026-11-17 22:00:00')) AS wrong_in,
       SUM(r.status = 'Confirmed'   AND a.checkInDateTime  <= '2026-11-17 22:00:00') AS wrong_conf
FROM reservation r JOIN room_assignment a ON a.reservationId = r.reservationId
GROUP BY r.status;

-- 5. Cancelled and no-show reservations never got a room.   Expected: 0
SELECT COUNT(*) AS bad
FROM reservation r JOIN room_assignment a ON a.reservationId = r.reservationId
WHERE r.status IN ('Cancelled', 'No Show');

-- 6. Every room has enough beds for the guests on the reservation. Expected: 0
SELECT COUNT(*) AS over_capacity FROM (
    SELECT r.reservationId, r.numGuests, SUM(rm.sleepingCapacity) AS cap
    FROM reservation r
    JOIN room_assignment a ON a.reservationId = r.reservationId
    JOIN room rm ON rm.roomId = a.roomId
    WHERE NOT EXISTS (SELECT 1 FROM room_assignment b      -- skip the 2nd half of a room switch
                      WHERE b.reservationId = a.reservationId
                        AND b.assignmentId < a.assignmentId
                        AND b.checkOutDateTime <= a.checkInDateTime)
    GROUP BY r.reservationId)
WHERE numGuests > cap;

-- 7. Nobody needing handicap access got a room without it. Expected: 0
SELECT COUNT(*) AS bad
FROM reservation r
JOIN room_assignment a ON a.reservationId = r.reservationId
JOIN room rm ON rm.roomId = a.roomId
JOIN wing w  ON w.wingId  = rm.wingId
WHERE r.needsHandicapAccess = 1 AND w.handicapAccess = 0;

-- 8. Each invoice: total = charges + tax - deposit, and status matches payments.
--    Expected: Paid 4979, all fully paid (6 show nothing_paid because the deposit
--              covered the whole bill); Issued 113 and Overdue 214 not fully paid;
--              Partially Paid 6 with some payment; overpaid and overdue_not_due = 0
WITH t AS (
    SELECT i.invoiceId, i.status, i.dueDate,
           ROUND((SELECT SUM(amount) FROM invoice_line l WHERE l.invoiceId = i.invoiceId), 2) AS total,
           ROUND((SELECT COALESCE(SUM(amount), 0) FROM payment p WHERE p.invoiceId = i.invoiceId), 2) AS paid
    FROM invoice i)
SELECT status, COUNT(*) AS invoices,
       SUM(paid >= total) AS fully_paid,
       SUM(paid = 0)      AS nothing_paid,
       SUM(paid > total)  AS overpaid,
       SUM(status = 'Overdue' AND dueDate >= '2026-11-17') AS overdue_not_due
FROM t GROUP BY status;

-- 9. Tax is exactly 12.5% of taxable lines on every invoice. Expected: 5312 | 0
SELECT COUNT(*) AS tax_lines,
       SUM(ABS(t.amount - ROUND(0.125 * (SELECT SUM(amount) FROM invoice_line l
                                         WHERE l.invoiceId = t.invoiceId
                                           AND l.lineType IN ('Room','Meeting Room','Service','Extension')), 2)) > 0.011) AS wrong
FROM invoice_line t WHERE t.lineType = 'Tax';

-- 10. Service lines = quantity x unit price.               Expected: 19680 | 0
SELECT COUNT(*) AS service_lines,
       SUM(ABS(l.amount - u.quantity * s.unitPrice) > 0.01) AS wrong
FROM invoice_line l
JOIN service_usage u  ON u.usageId   = l.usageId
JOIN allied_service s ON s.serviceId = u.serviceId;

-- 11. chargeStatus agrees with invoicing: Billed usages are on an invoice, others are not.
--     Expected: Authorized 0 | 167, Billed 19680 | 0, Expected 0 | 203
SELECT u.chargeStatus,
       SUM(l.usageId IS NOT NULL) AS on_invoice,
       SUM(l.usageId IS NULL)     AS not_on_invoice
FROM service_usage u LEFT JOIN invoice_line l ON l.usageId = u.usageId
GROUP BY u.chargeStatus;

-- 12. Services were used during the stay, not before or after. Expected: 0
SELECT COUNT(*) AS outside_stay
FROM service_usage u JOIN reservation r ON r.reservationId = u.reservationId
WHERE u.chargeStatus <> 'Expected'
  AND (date(u.usageDateTime) < date(r.startDate, '-1 day') OR date(u.usageDateTime) > r.endDate);

-- 13. Card access: every granted swipe had a valid permission, every denied one did not.
--     Expected: 0 | 0
SELECT
  (SELECT COUNT(*) FROM access_log l WHERE accessGranted = 1 AND NOT EXISTS (
       SELECT 1 FROM access_permission p WHERE p.cardId = l.cardId AND p.readerId = l.readerId
          AND l.accessDateTime BETWEEN p.validFrom AND p.validTo)) AS granted_without_permission,
  (SELECT COUNT(*) FROM access_log l WHERE accessGranted = 0 AND EXISTS (
       SELECT 1 FROM access_permission p WHERE p.cardId = l.cardId AND p.readerId = l.readerId
          AND l.accessDateTime BETWEEN p.validFrom AND p.validTo)) AS denied_with_permission;

-- 14. Nothing happens in the future: no logs, payments or messages after "now".
--     Expected: 0 | 0 | 0
SELECT (SELECT COUNT(*) FROM access_log    WHERE accessDateTime > '2026-11-17 22:00:00') AS future_logs,
       (SELECT COUNT(*) FROM payment       WHERE paymentDate    > '2026-11-17')          AS future_payments,
       (SELECT COUNT(*) FROM guest_message WHERE sentDateTime   > '2026-11-17 22:00:00') AS future_messages;

-- 15. Case rule: extensions up to 2 hours are free, longer ones are charged.
--     Expected: 1 h 66|0, 2 h 63|0, 3 h 0|39, 4 h 0|8
SELECT hoursExtended, SUM(surchargeFee = 0) AS free, SUM(surchargeFee > 0) AS charged
FROM stay_extension GROUP BY hoursExtended;

-- 16. Case rule: overnight event guests never exceed attendance. Expected: 53 | 0
SELECT COUNT(*) AS events,
       SUM(guests > estimatedAttendance) AS too_many
FROM (SELECT e.eventId, e.estimatedAttendance,
             COALESCE((SELECT SUM(r.numGuests) FROM reservation r
                       WHERE r.eventId = e.eventId
                         AND r.status NOT IN ('Cancelled','No Show')
                         AND NOT EXISTS (SELECT 1 FROM reservation_party rp     -- skip host bookings
                                         WHERE rp.reservationId = r.reservationId
                                           AND rp.guestTypeId = 5)), 0) AS guests
      FROM event e);

-- 17. Case rule: rooms are filled lowest wing first, so use falls with wing sequence.
--     Expected: A 1717 > B 1490 > C 505 in Main Tower; E 547 in the Annex
SELECT b.buildingName, w.wingCode, w.wingSeqNo, COUNT(*) AS assignments
FROM room_assignment a
JOIN room rm    ON rm.roomId    = a.roomId
JOIN wing w     ON w.wingId     = rm.wingId
JOIN building b ON b.buildingId = w.buildingId
GROUP BY w.wingId ORDER BY b.buildingId, w.wingSeqNo;

-- 18. Current room status matches who is in the rooms right now.
--     Expected: Available 25, Maintenance 1, Occupied 54, Out of Service 1 (meeting rooms
--               count as Available); then 53 checked-in stays (one family has 2 rooms = 54)
SELECT s.statusType, COUNT(*) AS rooms FROM room r JOIN room_status s ON s.statusId = r.statusId
GROUP BY s.statusType;
SELECT COUNT(*) AS checked_in_stays FROM reservation WHERE status = 'Checked In'
  AND EXISTS (SELECT 1 FROM room_assignment a WHERE a.reservationId = reservation.reservationId);

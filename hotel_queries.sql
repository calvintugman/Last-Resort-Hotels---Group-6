-- Query 1: Bed size requests and how often they were met
-- Which bed sizes do guests request most, and how often did they get a room with that bed?
-- (Helps managers decide which bed types to add when furnishing or renovating rooms.)
SELECT bed_size.bedSizeName,
       COUNT(DISTINCT reservation.reservationId) AS staysWithRequest,
       COUNT(DISTINCT CASE WHEN room_bed.roomId IS NOT NULL
                           THEN reservation.reservationId END) AS requestMet,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN room_bed.roomId IS NOT NULL
                                         THEN reservation.reservationId END)
             / COUNT(DISTINCT reservation.reservationId), 1) AS percentMet
FROM reservation
JOIN bed_size ON reservation.bedSizeId = bed_size.bedSizeId
JOIN room_assignment ON reservation.reservationId = room_assignment.reservationId
LEFT JOIN room_bed ON room_bed.roomId = room_assignment.roomId
                  AND room_bed.bedSizeId = reservation.bedSizeId
GROUP BY bed_size.bedSizeName
ORDER BY staysWithRequest DESC;

-- Query 2: Monthly revenue by service category
-- Which kinds of allied services generate the most revenue, and how does this change month to month?
-- (Helps management identify profitable services and track revenue trends.)
SELECT strftime('%Y-%m', service_usage.usageDateTime) AS month,
       allied_service.serviceCategory,
       COUNT(*) AS numUsages,
       ROUND(SUM(invoice_line.amount), 2) AS revenue
FROM invoice_line
JOIN service_usage ON invoice_line.usageId = service_usage.usageId
JOIN allied_service ON service_usage.serviceId = allied_service.serviceId
GROUP BY month, allied_service.serviceCategory
ORDER BY month, revenue DESC;

-- Query 3: Outstanding invoice balances
-- Which billing parties still owe money, and how much do they owe?
-- (Helps the finance team identify outstanding balances and prioritize collections.)
SELECT invoice.invoiceId,
       party.partyName AS billingParty,
       party.partyType,
       invoice.dueDate,
       invoice.status,
       ROUND(lineTotals.totalDue, 2) AS totalDue,
       ROUND(COALESCE(paid.totalPaid, 0), 2) AS totalPaid,
       ROUND(lineTotals.totalDue - COALESCE(paid.totalPaid, 0), 2) AS balance
FROM invoice
JOIN party ON invoice.billingPartyId = party.partyId
JOIN (SELECT invoiceId, SUM(amount) AS totalDue
      FROM invoice_line
      GROUP BY invoiceId) AS lineTotals
     ON invoice.invoiceId = lineTotals.invoiceId
LEFT JOIN (SELECT invoiceId, SUM(amount) AS totalPaid
           FROM payment
           GROUP BY invoiceId) AS paid
     ON invoice.invoiceId = paid.invoiceId
WHERE ROUND(lineTotals.totalDue - COALESCE(paid.totalPaid, 0), 2) > 0
ORDER BY balance DESC
LIMIT 15;

-- Query 4: Facility traffic from card swipes
-- Which hotel facilities receive the most traffic,
-- and how many access attempts are granted or denied?
-- (Helps management understand facility usage and allocate resources.)
-- Each visit logs an 'In' and an 'Out' swipe, so entries count 'In' swipes only.
SELECT facility.facilityName,
       facility.facilityType,
       SUM(access_log.accessGranted = 1 AND access_log.direction = 'In') AS grantedEntries,
       COUNT(DISTINCT access_log.cardId) AS distinctCards,
       SUM(access_log.accessGranted = 0) AS deniedAttempts
FROM access_log
JOIN card_reader ON access_log.readerId = card_reader.readerId
JOIN facility ON card_reader.facilityId = facility.facilityId
GROUP BY facility.facilityId, facility.facilityName, facility.facilityType
ORDER BY grantedEntries DESC;

-- Query 5: Most frequent returning guests
-- Which individual guests have completed the most stays, and how many nights did they stay?
-- (Helps management identify loyal customers for rewards programs.)
SELECT party.partyName,
       COUNT(reservation.reservationId) AS completedStays,
       SUM(julianday(reservation.endDate) - julianday(reservation.startDate)) AS totalNights
FROM party
JOIN reservation ON party.partyId = reservation.partyId
WHERE party.partyType = 'Individual'
  AND reservation.status = 'Checked Out'
GROUP BY party.partyId, party.partyName
HAVING COUNT(reservation.reservationId) > 1
ORDER BY completedStays DESC, totalNights DESC
LIMIT 10;

-- Query 6: Room assignment frequency by wing
-- Which hotel wings have the most room assignments relative to their number of rooms?
-- (Helps management compare room activity and allocate housekeeping resources.)
SELECT wing.wingCode,
       COUNT(DISTINCT room.roomId) AS roomCount,
       COUNT(room_assignment.assignmentId) AS assignmentCount,
       ROUND(1.0 * COUNT(room_assignment.assignmentId) /
             COUNT(DISTINCT room.roomId), 1) AS assignmentsPerRoom
FROM wing
JOIN room ON wing.wingId = room.wingId
LEFT JOIN room_assignment ON room.roomId = room_assignment.roomId
GROUP BY wing.wingId, wing.wingCode
ORDER BY assignmentsPerRoom DESC;

-- Query 7: Event-related revenue
-- Which hotel events bring in the most room revenue from attendees,
-- and how much does each event pay for meeting rooms?
-- (Helps management identify events that generate additional booking revenue.)
-- Room revenue counts 'Room' invoice lines only (no tax, deposits or services).
SELECT event.eventName,
       COUNT(DISTINCT CASE WHEN invoice_line.lineType = 'Room'
                           THEN reservation.reservationId END) AS roomBookings,
       ROUND(SUM(CASE WHEN invoice_line.lineType = 'Room'
                      THEN invoice_line.amount ELSE 0 END), 2) AS roomRevenue,
       (SELECT ROUND(SUM(meeting_booking.charge), 2)
        FROM meeting_booking
        WHERE meeting_booking.eventId = event.eventId) AS meetingRoomCharges
FROM event
JOIN reservation ON event.eventId = reservation.eventId
JOIN invoice ON reservation.reservationId = invoice.reservationId
JOIN invoice_line ON invoice.invoiceId = invoice_line.invoiceId
GROUP BY event.eventId, event.eventName
ORDER BY roomRevenue DESC;

-- Query 8: Monthly occupancy rate
-- What share of sleeping rooms was occupied each night, by month?
-- (Helps management spot busy and slow seasons for pricing and staffing.)
-- Builds one row per night, counts rooms occupied that night, then
-- occupancy = room-nights sold / (nights in period x sleeping rooms).
WITH RECURSIVE days(d) AS (
    SELECT '2026-06-01'
    UNION ALL
    SELECT date(d, '+1 day') FROM days WHERE d < '2026-11-16'
),
nightly AS (
    SELECT d,
           (SELECT COUNT(*) FROM room_assignment
            WHERE date(room_assignment.checkInDateTime) <= d
              AND d < date(room_assignment.checkOutDateTime)) AS occupied
    FROM days
)
SELECT strftime('%Y-%m', d) AS month,
       COUNT(*) AS nights,
       SUM(occupied) AS roomNightsSold,
       ROUND(100.0 * SUM(occupied) /
             (COUNT(*) * (SELECT COUNT(*) FROM room
                          WHERE roomUse IN ('Sleeping', 'Suite'))), 1) AS occupancyPct
FROM nightly
GROUP BY month
ORDER BY month;

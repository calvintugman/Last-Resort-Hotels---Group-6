-- ============================================================
-- Hotel Management Database (SQLite) -- FULL SCHEMA
--
-- Conventions
--   * Tables snake_case, columns camelCase.
--   * Dates are TEXT 'YYYY-MM-DD'; datetimes are TEXT 'YYYY-MM-DD HH:MM:SS';
--     clock times are TEXT 'HH:MM'.
--   * Flags are INTEGER 0/1 (SQLite has no BOOLEAN type).
--   * Money is REAL (SQLite has no DECIMAL type; round to 2 dp in queries).
--   * Room charges on invoice_line include a weekend premium, so they will
--     not always equal nights x room.baseDailyRate. invoice_line.amount is
--     the price frozen at billing time.
--   * Meeting rooms are booked per time slot through meeting_booking, so an
--     event can use several rooms across several slots. This replaces the
--     old event.assignmentId, which created a circular foreign key
--     (event -> room_assignment -> reservation -> event).
-- ============================================================

PRAGMA foreign_keys = OFF;

-- ---------- Re-runnable: drop everything (children first) ----------
DROP TRIGGER IF EXISTS trg_room_assignment_no_overlap_ins;
DROP TRIGGER IF EXISTS trg_room_assignment_no_overlap_upd;
DROP TRIGGER IF EXISTS trg_meeting_booking_valid;

DROP TABLE IF EXISTS payment;
DROP TABLE IF EXISTS invoice_line;
DROP TABLE IF EXISTS invoice;
DROP TABLE IF EXISTS service_usage;
DROP TABLE IF EXISTS allied_service;
DROP TABLE IF EXISTS access_log;
DROP TABLE IF EXISTS access_permission;
DROP TABLE IF EXISTS card_reader;
DROP TABLE IF EXISTS card;
DROP TABLE IF EXISTS guest_message;
DROP TABLE IF EXISTS customer_history;
DROP TABLE IF EXISTS stay_extension;
DROP TABLE IF EXISTS room_assignment;
DROP TABLE IF EXISTS reservation_party;
DROP TABLE IF EXISTS reservation;
DROP TABLE IF EXISTS meeting_booking;
DROP TABLE IF EXISTS event;
DROP TABLE IF EXISTS party;
DROP TABLE IF EXISTS guest_type;
DROP TABLE IF EXISTS staff;
DROP TABLE IF EXISTS time_slot;
DROP TABLE IF EXISTS room_bed;
DROP TABLE IF EXISTS room_adjacency;
DROP TABLE IF EXISTS room;
DROP TABLE IF EXISTS bed_size;
DROP TABLE IF EXISTS room_status;
DROP TABLE IF EXISTS facility;
DROP TABLE IF EXISTS wing;
DROP TABLE IF EXISTS building;
DROP TABLE IF EXISTS hotel;

PRAGMA foreign_keys = ON;

-- ============================================================
-- Property structure
-- ============================================================
CREATE TABLE hotel (
    hotelId    INTEGER PRIMARY KEY,
    hotelName  TEXT NOT NULL,
    location   TEXT NOT NULL
);

CREATE TABLE building (
    buildingId    INTEGER PRIMARY KEY,
    hotelId       INTEGER NOT NULL REFERENCES hotel(hotelId),
    buildingName  TEXT    NOT NULL,
    UNIQUE (hotelId, buildingName)
);

CREATE TABLE wing (
    wingId           INTEGER PRIMARY KEY,
    buildingId       INTEGER NOT NULL REFERENCES building(buildingId),
    wingCode         TEXT    NOT NULL,                 -- e.g. 'A', 'North'
    wingSeqNo        INTEGER NOT NULL CHECK (wingSeqNo > 0),
    nearIndoorPool   INTEGER NOT NULL DEFAULT 0 CHECK (nearIndoorPool  IN (0,1)),
    nearOutdoorPool  INTEGER NOT NULL DEFAULT 0 CHECK (nearOutdoorPool IN (0,1)),
    nearGarage       INTEGER NOT NULL DEFAULT 0 CHECK (nearGarage      IN (0,1)),
    handicapAccess   INTEGER NOT NULL DEFAULT 0 CHECK (handicapAccess  IN (0,1)),
    UNIQUE (buildingId, wingCode),
    UNIQUE (buildingId, wingSeqNo)
);

CREATE TABLE facility (
    facilityId    INTEGER PRIMARY KEY,
    buildingId    INTEGER NOT NULL REFERENCES building(buildingId),
    facilityName  TEXT    NOT NULL,
    facilityType  TEXT    NOT NULL
        CHECK (facilityType IN ('Pool','Restaurant','Garage','Conference Center',
                                'Gym','Lobby','Spa','Business Center','Other')),
    UNIQUE (buildingId, facilityName)
);

-- ============================================================
-- Rooms
-- ============================================================
CREATE TABLE room_status (
    statusId    INTEGER PRIMARY KEY,
    statusType  TEXT NOT NULL UNIQUE      -- Available, Occupied, Cleaning, Out of Service ...
);

CREATE TABLE bed_size (
    bedSizeId    INTEGER PRIMARY KEY,
    bedSizeName  TEXT NOT NULL UNIQUE     -- Twin, Double, Queen, King ...
);

-- canSleep / canMeet are capability flags, not derived values: a meeting room
-- with a toilet can sleep guests on rollaway beds even though its
-- sleepingCapacity is 0, and a suite can be booked as a meeting room only.
CREATE TABLE room (
    roomId            INTEGER PRIMARY KEY,
    wingId            INTEGER NOT NULL REFERENCES wing(wingId),
    statusId          INTEGER NOT NULL REFERENCES room_status(statusId),
    roomNumber        TEXT    NOT NULL,   -- floor digits + 2-digit room number, e.g. '512', '1204'
    roomUse           TEXT    NOT NULL CHECK (roomUse IN ('Sleeping','Meeting','Suite')),
    sleepingCapacity  INTEGER NOT NULL DEFAULT 0 CHECK (sleepingCapacity >= 0),
    seatingCapacity   INTEGER NOT NULL DEFAULT 0 CHECK (seatingCapacity  >= 0),
    hasWallBed        INTEGER NOT NULL DEFAULT 0 CHECK (hasWallBed IN (0,1)),
    smoking           INTEGER NOT NULL DEFAULT 0 CHECK (smoking    IN (0,1)),
    hasToilet         INTEGER NOT NULL DEFAULT 1 CHECK (hasToilet  IN (0,1)),
    canSleep          INTEGER NOT NULL CHECK (canSleep IN (0,1)),
    canMeet           INTEGER NOT NULL CHECK (canMeet  IN (0,1)),
    baseDailyRate     REAL    NOT NULL CHECK (baseDailyRate >= 0),
    UNIQUE (wingId, roomNumber),
    CHECK (roomNumber GLOB '[0-9][0-9][0-9]' OR roomNumber GLOB '[0-9][0-9][0-9][0-9]'),
    CHECK (canSleep = 0 OR hasToilet = 1),          -- only rooms with a toilet can sleep people
    CHECK (canMeet  = 0 OR seatingCapacity > 0),    -- a meeting-capable room needs seats
    CHECK (canSleep = 1 OR canMeet = 1)             -- every room has at least one use
);

CREATE TABLE room_adjacency (
    roomId          INTEGER NOT NULL REFERENCES room(roomId),
    adjacentRoomId  INTEGER NOT NULL REFERENCES room(roomId),
    PRIMARY KEY (roomId, adjacentRoomId),
    CHECK (roomId <> adjacentRoomId)
);

CREATE TABLE room_bed (
    roomId       INTEGER NOT NULL REFERENCES room(roomId),
    bedSizeId    INTEGER NOT NULL REFERENCES bed_size(bedSizeId),
    bedQuantity  INTEGER NOT NULL CHECK (bedQuantity > 0),
    PRIMARY KEY (roomId, bedSizeId)
);

-- Fixed meeting-room usage periods. isEatingSlot drives pricing: non-eating
-- slots are charged at half the eating rate (pricing is computed by the app).
CREATE TABLE time_slot (
    slotId        INTEGER PRIMARY KEY,
    slotName      TEXT    NOT NULL UNIQUE
        CHECK (slotName IN ('Breakfast','Morning','Lunch','Afternoon','Supper','Evening','Night')),
    isEatingSlot  INTEGER NOT NULL CHECK (isEatingSlot IN (0,1)),
    startTime     TEXT    NOT NULL CHECK (time(startTime) IS startTime || ':00'),
    endTime       TEXT    NOT NULL CHECK (time(endTime)   IS endTime   || ':00')
);

-- ============================================================
-- Staff
-- ============================================================
CREATE TABLE staff (
    staffId    INTEGER PRIMARY KEY,
    firstName  TEXT NOT NULL,
    lastName   TEXT NOT NULL,
    jobTitle   TEXT NOT NULL,
    hireDate   TEXT NOT NULL CHECK (date(hireDate) IS hireDate)
);

-- ============================================================
-- Guests and bookings
-- ============================================================
CREATE TABLE guest_type (
    guestTypeId  INTEGER PRIMARY KEY,
    typeName     TEXT NOT NULL UNIQUE     -- Adult, Child, Infant, Senior, VIP ...
);

-- affiliationPartyId: the organization an individual works for.
-- contactPartyId: the individual acting on behalf of an organization.
CREATE TABLE party (
    partyId                   INTEGER PRIMARY KEY,
    partyType                 TEXT NOT NULL CHECK (partyType IN ('Individual','Organization')),
    partyName                 TEXT NOT NULL,
    email                     TEXT,
    phone                     TEXT,
    affiliationPartyId        INTEGER REFERENCES party(partyId),
    contactPartyId            INTEGER REFERENCES party(partyId),
    keepLocationConfidential  INTEGER NOT NULL DEFAULT 0
        CHECK (keepLocationConfidential IN (0,1)),
    CHECK (email IS NOT NULL OR phone IS NOT NULL),
    CHECK (partyType = 'Organization' OR contactPartyId IS NULL),
    CHECK (partyType = 'Individual'   OR affiliationPartyId IS NULL),
    CHECK (affiliationPartyId IS NULL OR affiliationPartyId <> partyId),
    CHECK (contactPartyId     IS NULL OR contactPartyId     <> partyId)
);

CREATE TABLE event (
    eventId              INTEGER PRIMARY KEY,
    eventName            TEXT    NOT NULL,
    hostPartyId          INTEGER NOT NULL REFERENCES party(partyId),
    startDate            TEXT    NOT NULL CHECK (date(startDate) IS startDate),
    endDate              TEXT    NOT NULL CHECK (date(endDate)   IS endDate),
    estimatedAttendance  INTEGER NOT NULL CHECK (estimatedAttendance > 0),
    estimatedGuests      INTEGER CHECK (estimatedGuests >= 0),   -- attendees staying overnight
    CHECK (endDate >= startDate),
    CHECK (estimatedGuests IS NULL OR estimatedGuests <= estimatedAttendance)
);

-- One row per room per time slot per day used by an event.
CREATE TABLE meeting_booking (
    bookingId    INTEGER PRIMARY KEY,
    eventId      INTEGER NOT NULL REFERENCES event(eventId),
    roomId       INTEGER NOT NULL REFERENCES room(roomId),
    slotId       INTEGER NOT NULL REFERENCES time_slot(slotId),
    bookingDate  TEXT    NOT NULL CHECK (date(bookingDate) IS bookingDate),
    hasPaidBar   INTEGER NOT NULL DEFAULT 0 CHECK (hasPaidBar IN (0,1)),  -- a paid bar counts as eating
    charge       REAL    NOT NULL DEFAULT 0 CHECK (charge >= 0),
    UNIQUE (roomId, slotId, bookingDate)   -- one booking per room per slot per day
);

CREATE TABLE reservation (
    reservationId        INTEGER PRIMARY KEY,
    partyId              INTEGER NOT NULL REFERENCES party(partyId),
    eventId              INTEGER REFERENCES event(eventId),
    bedSizeId            INTEGER REFERENCES bed_size(bedSizeId),       -- preferred bed size
    preferredBuildingId  INTEGER REFERENCES building(buildingId),      -- preferred location
    reservationDate      TEXT    NOT NULL CHECK (date(reservationDate) IS reservationDate),
    startDate            TEXT    NOT NULL CHECK (date(startDate) IS startDate),
    endDate              TEXT    NOT NULL CHECK (date(endDate) IS endDate),
    numGuests            INTEGER NOT NULL CHECK (numGuests > 0),
    smokingPreference    INTEGER NOT NULL DEFAULT 0 CHECK (smokingPreference   IN (0,1)),
    wantsNearPool        INTEGER NOT NULL DEFAULT 0 CHECK (wantsNearPool       IN (0,1)),
    wantsNearGarage      INTEGER NOT NULL DEFAULT 0 CHECK (wantsNearGarage     IN (0,1)),
    needsHandicapAccess  INTEGER NOT NULL DEFAULT 0 CHECK (needsHandicapAccess IN (0,1)),
    depositAmount        REAL    NOT NULL DEFAULT 0 CHECK (depositAmount >= 0),
    status               TEXT    NOT NULL DEFAULT 'Confirmed'
        CHECK (status IN ('Pending','Confirmed','Checked In','Checked Out','Cancelled','No Show')),
    CHECK (endDate > startDate),
    CHECK (reservationDate <= startDate)
);

-- guestTypeId implements the guest_type "classifies" relationship:
-- each guest on a reservation is classified (adult, child, ...).
CREATE TABLE reservation_party (
    reservationId  INTEGER NOT NULL REFERENCES reservation(reservationId),
    partyId        INTEGER NOT NULL REFERENCES party(partyId),
    guestTypeId    INTEGER NOT NULL REFERENCES guest_type(guestTypeId),
    PRIMARY KEY (reservationId, partyId)
);

-- A reservation can have several assignments: several rooms at once, or a
-- guest switching rooms mid-stay (still one composite bill per reservation).
CREATE TABLE room_assignment (
    assignmentId      INTEGER PRIMARY KEY,
    reservationId     INTEGER NOT NULL REFERENCES reservation(reservationId),
    roomId            INTEGER NOT NULL REFERENCES room(roomId),
    partyId           INTEGER NOT NULL REFERENCES party(partyId),   -- guest occupying the room
    checkInDateTime   TEXT    NOT NULL CHECK (datetime(checkInDateTime)  IS checkInDateTime),
    checkOutDateTime  TEXT    NOT NULL CHECK (datetime(checkOutDateTime) IS checkOutDateTime),
    CHECK (checkOutDateTime > checkInDateTime)
);

-- Extensions of up to 2 hours are granted free; longer ones carry a flat surcharge.
CREATE TABLE stay_extension (
    extensionId       INTEGER PRIMARY KEY,
    assignmentId      INTEGER NOT NULL REFERENCES room_assignment(assignmentId),
    approvedByStaffId INTEGER NOT NULL REFERENCES staff(staffId),
    extensionType     TEXT    NOT NULL
        CHECK (extensionType IN ('Late Checkout','Early Check-in')),
    hoursExtended     INTEGER NOT NULL CHECK (hoursExtended > 0),
    surchargeFee      REAL    NOT NULL DEFAULT 0 CHECK (surchargeFee >= 0),
    requestTime       TEXT    NOT NULL CHECK (datetime(requestTime) IS requestTime),
    CHECK (hoursExtended > 2 OR surchargeFee = 0)
);

CREATE TABLE customer_history (
    historyId      INTEGER PRIMARY KEY,
    partyId        INTEGER NOT NULL REFERENCES party(partyId),
    reservationId  INTEGER NOT NULL REFERENCES reservation(reservationId),
    ratingScore    INTEGER NOT NULL CHECK (ratingScore BETWEEN 1 AND 5),
    notes          TEXT,
    recordedDate   TEXT    NOT NULL CHECK (date(recordedDate) IS recordedDate)
);

-- 'Outgoing Greeting': recorded by the guest on their room phone (no staff).
-- 'Staff Taken': a caller's message taken by staff and relayed to the guest.
-- 'Hotel Notice': a message from the hotel to the guest.
CREATE TABLE guest_message (
    messageId     INTEGER PRIMARY KEY,
    reservationId INTEGER NOT NULL REFERENCES reservation(reservationId),
    partyId       INTEGER NOT NULL REFERENCES party(partyId),   -- guest the message is for/from
    staffId       INTEGER REFERENCES staff(staffId),
    messageType   TEXT    NOT NULL
        CHECK (messageType IN ('Outgoing Greeting','Staff Taken','Hotel Notice')),
    messageText   TEXT    NOT NULL,
    sentDateTime  TEXT    NOT NULL CHECK (datetime(sentDateTime) IS sentDateTime),
    isRead        INTEGER NOT NULL DEFAULT 0 CHECK (isRead IN (0,1)),
    CHECK ((messageType = 'Outgoing Greeting') = (staffId IS NULL))
);

-- ============================================================
-- Access control
-- ============================================================
CREATE TABLE card (
    cardId      INTEGER PRIMARY KEY,
    staffId     INTEGER REFERENCES staff(staffId),
    partyId     INTEGER REFERENCES party(partyId),
    cardType    TEXT NOT NULL CHECK (cardType IN ('Room Key','Staff','Master','Facility')),
    pinHash     TEXT,                    -- hashed PIN, never the raw PIN
    issueDate   TEXT NOT NULL CHECK (date(issueDate) IS issueDate),
    expiryDate  TEXT NOT NULL CHECK (date(expiryDate) IS expiryDate),
    status      TEXT NOT NULL DEFAULT 'Active'
        CHECK (status IN ('Active','Expired','Lost','Revoked')),
    CHECK (expiryDate >= issueDate),
    -- a card belongs to exactly one holder: a staff member OR a guest party
    CHECK ((staffId IS NOT NULL) + (partyId IS NOT NULL) = 1),
    -- guest cards come with a PIN
    CHECK (partyId IS NULL OR pinHash IS NOT NULL)
);

CREATE TABLE card_reader (
    readerId        INTEGER PRIMARY KEY,
    roomId          INTEGER REFERENCES room(roomId),
    facilityId      INTEGER REFERENCES facility(facilityId),
    readerLocation  TEXT NOT NULL,
    -- a reader sits on a room door OR at a facility, never both / neither
    CHECK ((roomId IS NOT NULL) + (facilityId IS NOT NULL) = 1)
);

CREATE TABLE access_permission (
    cardId     INTEGER NOT NULL REFERENCES card(cardId),
    readerId   INTEGER NOT NULL REFERENCES card_reader(readerId),
    validFrom  TEXT    NOT NULL CHECK (datetime(validFrom) IS validFrom),
    validTo    TEXT    NOT NULL CHECK (datetime(validTo) IS validTo),
    PRIMARY KEY (cardId, readerId),
    CHECK (validTo >= validFrom)
);

-- Each reader has two slots: 'In' (entering) and 'Out' (leaving).
CREATE TABLE access_log (
    logId           INTEGER PRIMARY KEY,
    cardId          INTEGER NOT NULL REFERENCES card(cardId),
    readerId        INTEGER NOT NULL REFERENCES card_reader(readerId),
    accessDateTime  TEXT    NOT NULL CHECK (datetime(accessDateTime) IS accessDateTime),
    direction       TEXT    NOT NULL CHECK (direction IN ('In','Out')),
    accessGranted   INTEGER NOT NULL CHECK (accessGranted IN (0,1))
);

-- ============================================================
-- Services and billing
-- ============================================================
CREATE TABLE allied_service (
    serviceId        INTEGER PRIMARY KEY,
    serviceName      TEXT NOT NULL UNIQUE,
    serviceCategory  TEXT NOT NULL,           -- Dining, Spa, Laundry, Transport ...
    unitPrice        REAL NOT NULL CHECK (unitPrice >= 0)
);

-- chargeStatus lets the hotel record expected and authorized charges ahead of
-- time (e.g. during the reservation process), not only billed ones.
CREATE TABLE service_usage (
    usageId        INTEGER PRIMARY KEY,
    reservationId  INTEGER NOT NULL REFERENCES reservation(reservationId),
    serviceId      INTEGER NOT NULL REFERENCES allied_service(serviceId),
    partyId        INTEGER NOT NULL REFERENCES party(partyId),        -- guest who used it
    facilityId     INTEGER REFERENCES facility(facilityId),           -- where it happened
    usageDateTime  TEXT    NOT NULL CHECK (datetime(usageDateTime) IS usageDateTime),
    quantity       INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    chargeStatus   TEXT    NOT NULL DEFAULT 'Billed'
        CHECK (chargeStatus IN ('Expected','Authorized','Billed'))
);

-- Split billing: a reservation can have several invoices, one per billing
-- party (e.g. room charges to an organization, incidentals to the guest).
CREATE TABLE invoice (
    invoiceId       INTEGER PRIMARY KEY,
    reservationId   INTEGER NOT NULL REFERENCES reservation(reservationId),
    billingPartyId  INTEGER NOT NULL REFERENCES party(partyId),
    issueDate       TEXT    NOT NULL CHECK (date(issueDate) IS issueDate),
    dueDate         TEXT    NOT NULL CHECK (date(dueDate) IS dueDate),
    status          TEXT    NOT NULL DEFAULT 'Issued'
        CHECK (status IN ('Draft','Issued','Partially Paid','Paid','Overdue','Void')),
    CHECK (dueDate >= issueDate)
);

CREATE TABLE invoice_line (
    invoiceId    INTEGER NOT NULL REFERENCES invoice(invoiceId),
    lineNumber   INTEGER NOT NULL CHECK (lineNumber > 0),
    lineType     TEXT    NOT NULL
        CHECK (lineType IN ('Room','Meeting Room','Service','Extension','Tax','Deposit','Adjustment')),
    description  TEXT    NOT NULL,
    amount       REAL    NOT NULL,            -- may be negative (deposit credit, adjustment)
    usageId      INTEGER UNIQUE REFERENCES service_usage(usageId),        -- a usage is billed at most once
    bookingId    INTEGER UNIQUE REFERENCES meeting_booking(bookingId),    -- a booking is billed at most once
    PRIMARY KEY (invoiceId, lineNumber),
    -- service lines point at the usage they bill; meeting-room lines at the booking
    CHECK ((lineType = 'Service')      = (usageId   IS NOT NULL)),
    CHECK ((lineType = 'Meeting Room') = (bookingId IS NOT NULL))
);

CREATE TABLE payment (
    paymentId      INTEGER PRIMARY KEY,
    invoiceId      INTEGER NOT NULL REFERENCES invoice(invoiceId),
    paymentMethod  TEXT    NOT NULL
        CHECK (paymentMethod IN ('Credit Card','Debit Card','Cash','Bank Transfer','Check', 'Corporate Account')),
    amount         REAL    NOT NULL CHECK (amount > 0),
    paymentDate    TEXT    NOT NULL CHECK (date(paymentDate) IS paymentDate)
);

-- ============================================================
-- Triggers: a room cannot be assigned to two stays at the same time.
-- Intervals are half-open, so a 11:00 check-out and 15:00 check-in
-- (or a same-time turnover) do not count as an overlap.
-- ============================================================
CREATE TRIGGER trg_room_assignment_no_overlap_ins
BEFORE INSERT ON room_assignment
WHEN EXISTS (
    SELECT 1 FROM room_assignment ra
    WHERE ra.roomId = NEW.roomId
      AND ra.checkInDateTime  < NEW.checkOutDateTime
      AND NEW.checkInDateTime < ra.checkOutDateTime
)
BEGIN
    SELECT RAISE(ABORT, 'Room is already assigned for an overlapping period');
END;

CREATE TRIGGER trg_room_assignment_no_overlap_upd
BEFORE UPDATE OF roomId, checkInDateTime, checkOutDateTime ON room_assignment
WHEN EXISTS (
    SELECT 1 FROM room_assignment ra
    WHERE ra.roomId = NEW.roomId
      AND ra.assignmentId <> NEW.assignmentId
      AND ra.checkInDateTime  < NEW.checkOutDateTime
      AND NEW.checkInDateTime < ra.checkOutDateTime
)
BEGIN
    SELECT RAISE(ABORT, 'Room is already assigned for an overlapping period');
END;

-- ============================================================
-- Trigger: a meeting booking must use a meeting-capable room and
-- fall within the event's dates (cross-table rules a CHECK cannot express).
-- ============================================================
CREATE TRIGGER trg_meeting_booking_valid
BEFORE INSERT ON meeting_booking
BEGIN
    SELECT RAISE(ABORT, 'Room cannot be used for meetings')
    WHERE (SELECT canMeet FROM room WHERE roomId = NEW.roomId) = 0;

    SELECT RAISE(ABORT, 'Booking date is outside the event dates')
    WHERE NEW.bookingDate NOT BETWEEN
          (SELECT startDate FROM event WHERE eventId = NEW.eventId)
      AND (SELECT endDate   FROM event WHERE eventId = NEW.eventId);
END;

-- ============================================================
-- Indexes on foreign keys (SQLite does not create these automatically).
-- They speed up the joins used by the reporting queries.
-- ============================================================
CREATE INDEX idx_building_hotelId              ON building(hotelId);
CREATE INDEX idx_wing_buildingId               ON wing(buildingId);
CREATE INDEX idx_facility_buildingId           ON facility(buildingId);
CREATE INDEX idx_room_wingId                   ON room(wingId);
CREATE INDEX idx_room_statusId                 ON room(statusId);
CREATE INDEX idx_room_bed_bedSizeId            ON room_bed(bedSizeId);
CREATE INDEX idx_room_adjacency_adjacentRoomId ON room_adjacency(adjacentRoomId);
CREATE INDEX idx_party_affiliationPartyId      ON party(affiliationPartyId);
CREATE INDEX idx_party_contactPartyId          ON party(contactPartyId);
CREATE INDEX idx_event_hostPartyId             ON event(hostPartyId);
CREATE INDEX idx_meeting_booking_eventId       ON meeting_booking(eventId);
CREATE INDEX idx_meeting_booking_slotId        ON meeting_booking(slotId);
CREATE INDEX idx_reservation_partyId           ON reservation(partyId);
CREATE INDEX idx_reservation_eventId           ON reservation(eventId);
CREATE INDEX idx_reservation_bedSizeId         ON reservation(bedSizeId);
CREATE INDEX idx_reservation_preferredBuilding ON reservation(preferredBuildingId);
CREATE INDEX idx_reservation_party_partyId     ON reservation_party(partyId);
CREATE INDEX idx_reservation_party_guestTypeId ON reservation_party(guestTypeId);
CREATE INDEX idx_room_assignment_reservationId ON room_assignment(reservationId);
CREATE INDEX idx_room_assignment_roomId        ON room_assignment(roomId);
CREATE INDEX idx_room_assignment_partyId       ON room_assignment(partyId);
CREATE INDEX idx_stay_extension_assignmentId   ON stay_extension(assignmentId);
CREATE INDEX idx_stay_extension_staffId        ON stay_extension(approvedByStaffId);
CREATE INDEX idx_customer_history_partyId      ON customer_history(partyId);
CREATE INDEX idx_customer_history_reservation  ON customer_history(reservationId);
CREATE INDEX idx_guest_message_reservationId   ON guest_message(reservationId);
CREATE INDEX idx_guest_message_partyId         ON guest_message(partyId);
CREATE INDEX idx_guest_message_staffId         ON guest_message(staffId);
CREATE INDEX idx_card_staffId                  ON card(staffId);
CREATE INDEX idx_card_partyId                  ON card(partyId);
CREATE INDEX idx_card_reader_roomId            ON card_reader(roomId);
CREATE INDEX idx_card_reader_facilityId        ON card_reader(facilityId);
CREATE INDEX idx_access_permission_readerId    ON access_permission(readerId);
CREATE INDEX idx_access_log_cardId             ON access_log(cardId);
CREATE INDEX idx_access_log_readerId           ON access_log(readerId);
CREATE INDEX idx_service_usage_reservationId   ON service_usage(reservationId);
CREATE INDEX idx_service_usage_serviceId       ON service_usage(serviceId);
CREATE INDEX idx_service_usage_partyId         ON service_usage(partyId);
CREATE INDEX idx_service_usage_facilityId      ON service_usage(facilityId);
CREATE INDEX idx_invoice_reservationId         ON invoice(reservationId);
CREATE INDEX idx_invoice_billingPartyId        ON invoice(billingPartyId);
CREATE INDEX idx_payment_invoiceId             ON payment(invoiceId);

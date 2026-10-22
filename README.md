# Group 6 – Last Resort Hotels

CSCI-UA.0060 Database Design and Web Implementation, Fall 2026

---

## Team Statement

We will divide responsibilities across each of the major parts of the project to make sure that every member contributes appropriately. For the Entity Relationship Diagram, we assigned each member certain tables to design and collaborated on establishing their relationships and cardinalities. For database implementation, each member will also be responsible for implementing and populating their respective tables. The analysis report and other written components will be divided into four sections, with one member responsible for compiling and editing the final document for cohesiveness. For the source code, we will divide responsibilities for developing SQL queries and building the web interface with all members contributing to testing and integration. The presentation will then be broken down into four speaking sections and each member is responsible for creating their respective slides. We will then review the final presentation together to make sure the flow is smooth and cohesive. To maintain accountability, we will also review each other's progress and meet regularly to maintain consistent communication. We will make sure to support each other and redistribute tasks as needed to keep a well-balanced workload.

---

## Draft Analysis

### Key design decisions

- Location follows a one to many relationship: hotels -> building -> wing -> room. Room numbers are only unique within a wing, so each room gets its own roomId. Wing features are stored on wing. Nonsmoking floors are tracked through room.smoking instead of a separate floor table.
- One room table with can_sleep and can_meet flags replaces the separate sleeping, suite and meeting room tables. This supports rooms that serve multiple purposes without duplicating functions.
- Beds use a bed_size lookup and a room_bed table, which allows a room to have two different bed types.
- Adjacency is stored in room_adjacency, where both columns point to room. This covers every adjacency type in the case, since two rooms are adjacent whenever a door connects them.
- Booking is split into reservation (the request), room_assingment (the actual room) and stay_extension (early or late extensions and surcharges). This matches the case, where rooms are assigned late and extensions are given at checkout.
- Billing is split into invoice, invoice_line, payment and service_usage, so every charge is itemized and the bill stays current.
- The ERD has 28 tables, all in 3NF

### Assumptions

#### Reservations, rooms and stays

- A reservation records the customer's request and dates only. Specific room assignment is a separate step because assignments are made late and change at the last minute.
- A guest may switch rooms during a stay but still receives one composite bill per reservation. Invoices therefore attach to reservationId, not to a room.
- The same room can serve several functions (suite as sleeping or meeting room). We assume the current function is stored on the room and is not a separate table.
- Business rules the ERD cannot express are enforced by the application, not the schema: a room with permanent beds cannot be a meeting room, adjacency limits between sleeping and meeting rooms, and the lowest-wing-first allocation algorithm.

#### Parties and billing

- Guests, hosts, billing parties and organizations are all stored as one party (with a role/type) instead of separate tables. The role a party plays in a reservation is recorded in reservation_party.guestTypeId.
- The billing party can differ from the guest. invoice.billingPartyId points to party, not to the guest, which supports an outside host or organization paying.
- Split billing: one reservation can produce several invoices with different billing parties (e.g. room billed to one party, phone calls billed to the occupant). Each service_usage row records which party used the service, and each invoice line points to the usage it charges.
- When an organization is the billing party, a named individual acts on its behalf. We assume this contact person is a party record linked to the organization, owned by the Rooms & Events module.
- Room charges and surcharges appear as invoice lines with a null usageId. Services such as meals, phone calls and spa visits link to service_usage.
- Totals, balances and amounts due are derived by queries and are not stored. This avoids transitive dependencies and keeps the tables in 3NF.
- Prices live in allied_service.unitPrice. Pricing rules for meeting rooms (half rate for non-eating slots, one free slot per paid eating slot, waived fees) are computed by the application, not modeled.
- Advance deposits are an optional amount on the reservation and are handled by Rooms & Events. If a deposit has to appear on the bill, it is applied as an invoice line.

#### Access cards and messages

- A card belongs to exactly one holder, either a staff member or a guest party, never both. card.staffId and card.partyId are each nullable, and exactly one is filled in.
- Each reader belongs to a room. We assume restaurants and the health club are modeled as room entries (as the case treats outdoor courtyards as meeting rooms), so readers need no separate facility table.
- The two reader slots (entering/leaving) are stored as accessLog.accessGranted plus the timestamp. We do not model a separate direction field.
- Messages attach to the reservation, not an individual guest, because the hotel contacts the reserving party. The "keep my whereabouts confidential" flag is a party-level attribute in Rooms & Events.
- Card readers are not tied to specific cards. They accept any cards granted permission.

### Tradeoffs or limitations

- Separating reservations from room assignments allows the hotel to take last-minute room changes but it also makes checking for availability more complicated since reservation dates, current or existing room assignments, and the current status of rooms must be considered to prevent double bookings.
- Using a single party table for guests, hosts, organizations, and billing parties reduces duplicated information but differentiating the various roles a party might play would need additional relationships and validation.
- Separating invoices, invoice lines, payments, and service usage would allow splitting the billing between multiple parties, but this introduces additional relationships and would need more complex queries to calculate balances and ensure charges are assigned correctly.

### Ambiguities to be handled

#### Modeling choices

- Guests, hosts and billing parties: The text treats these as overlapping roles, so we used one table called guestType.
- Sleeping and meeting rooms: Rooms can serve both purposes, so we used a single Room table instead of subtypes. can_sleep and can_meet flags show the uses, with separate sleeping and seating capacities.
- Adjacency: Rooms can have many neighbors, so Room_Adjacency handles the many-to-many relationship. The rules about how many sleeping and meeting rooms can be adjacent are business rules that an ERD can't show, so they're left to the application.
- A room can have two bed types, so Room_Bed uses a composite key of room and bed size, and Bed_Size is a lookup table.
- Each bill has one responsible party, billed via one invoice. But one invoice could be paid through many payments.
- Bed size, guest count, smoking is determined by the room, and a party who wishes to reserve rooms with these qualities will be booked rooms that have such qualities without each room's qualities having to change.

# OpsFlow V1 · ER diagrams by module

Generated from `opsflow-erd.mermaid` (the full diagram). Tables shown with only a name are owned by another module.
Every tenant table also has `org_id` to `organizations`; child tables inherit that edge from their parent.

## Identity, organization and people

Login identities are global; everything a person does inside a company hangs off their membership in that company.

```mermaid
erDiagram
    users ||--o{ user_identities : "signs in with"
    users ||--o{ sessions : "has"
    users ||--o{ email_tokens : "receives"
    users ||--o{ memberships : "works as"
    organizations ||--o{ memberships : "employs"
    organizations ||--o{ departments : "has"
    organizations ||--o{ teams : "has"
    organizations ||--o{ invitations : "sends"
    organizations ||--o{ org_counters : "numbers with"
    departments |o--o{ memberships : "groups"
    departments |o--o{ teams : "contains"
    memberships |o--o{ memberships : "manages"
    teams ||--o{ team_members : "has"
    memberships ||--o{ team_members : "belongs via"
    memberships ||--o{ invitations : "invites"

    users {
        uuid id PK
        citext email UK
        text password_hash "argon2id, null for Google-only"
        text display_name
        timestamptz email_verified_at
    }
    user_identities {
        uuid id PK
        uuid user_id FK
        text provider "google"
        text provider_subject UK
    }
    sessions {
        uuid id PK
        uuid user_id FK
        bytea token_hash UK "SHA-256 of cookie"
        timestamptz expires_at
        timestamptz revoked_at
    }
    email_tokens {
        uuid id PK
        uuid user_id FK
        text purpose "verify_email or reset_password"
        bytea token_hash UK
        timestamptz used_at
    }
    organizations {
        uuid id PK
        text slug UK
        text name
        text timezone "validated by trigger"
        smallint_array working_days "ISO 1-7"
        smallint leave_year_start_month
        uuid logo_file_id FK
    }
    departments {
        uuid id PK
        uuid org_id FK
        text name "unique per org"
    }
    memberships {
        uuid id PK
        uuid org_id FK
        uuid user_id FK "unique per org"
        text role "owner admin manager employee"
        text status "active or deactivated"
        text employee_code "unique per org"
        uuid department_id FK
        uuid manager_id FK "reporting line"
        int version
    }
    teams {
        uuid id PK
        uuid org_id FK
        uuid department_id FK
        text name "unique per org"
    }
    team_members {
        uuid team_id PK, FK
        uuid membership_id PK, FK
        uuid org_id FK
        boolean is_lead
    }
    invitations {
        uuid id PK
        uuid org_id FK
        citext email "one open invite per org"
        text role
        uuid invited_by FK
        bytea token_hash UK
        timestamptz expires_at
    }
    org_counters {
        uuid org_id PK, FK
        text scope PK "task or ticket"
        bigint next_value
    }
```

## Leave and WFH

Each request is split into per-leave-year allocations at submission. Approval writes one debit per allocation to the append-only ledger, and a balance is the sum of the ledger for that year.

```mermaid
erDiagram
    organizations ||--o{ leave_types : "defines"
    organizations ||--o{ holidays : "observes"
    leave_types ||--o{ leave_requests : "type of"
    memberships ||--o{ leave_requests : "requests"
    memberships |o--o{ leave_requests : "approves"
    leave_requests ||--|{ leave_request_allocations : "splits into"
    leave_request_allocations |o--o{ leave_ledger : "debited by"
    memberships ||--o{ leave_ledger : "balance of"
    leave_types ||--o{ leave_ledger : "balance in"
    leave_requests ||--o{ leave_request_attachments : "has"
    files ||--o{ leave_request_attachments : "attached as"

    leave_types {
        uuid id PK
        uuid org_id FK
        text name "unique per org"
        text category "leave or wfh"
        boolean deducts_balance
        numeric annual_quota "null = no limit"
        boolean allow_half_day
    }
    holidays {
        uuid id PK
        uuid org_id FK
        date holiday_date "unique per org"
        text name
    }
    leave_requests {
        uuid id PK
        uuid org_id FK
        uuid member_id FK "no overlapping live requests"
        uuid leave_type_id FK
        date start_date
        date end_date
        text start_half "full first second"
        text end_half "full first second"
        numeric days "steps of 0.5"
        text status "pending approved rejected cancelled"
        uuid approver_id FK "snapshot at submit"
        uuid decided_by FK "never the requester"
        int version
    }
    leave_request_allocations {
        uuid request_id PK, FK
        smallint period_year PK "leave year"
        uuid org_id FK
        numeric days "rows sum to request days"
    }
    leave_ledger {
        uuid id PK
        uuid org_id FK
        uuid member_id FK
        uuid leave_type_id FK
        smallint period_year
        text kind "accrual carry_forward debit reversal adjustment"
        numeric delta "balance = SUM(delta)"
        uuid request_id FK "with period_year: must match an allocation"
    }
    leave_request_attachments {
        uuid request_id PK, FK
        uuid file_id PK, FK
        uuid org_id FK
    }
```

## Tasks, tickets and files

Tickets route to a category, and the category names the team whose members work the queue.

```mermaid
erDiagram
    organizations ||--o{ files : "stores"
    memberships ||--o{ files : "uploads"
    files |o--o| organizations : "is logo of"
    memberships ||--o{ tasks : "creates"
    memberships |o--o{ tasks : "assigned"
    teams |o--o{ tasks : "owns"
    tasks ||--o{ task_comments : "has"
    memberships ||--o{ task_comments : "writes"
    tasks ||--o{ task_attachments : "has"
    files ||--o{ task_attachments : "attached as"
    organizations ||--o{ ticket_categories : "defines"
    teams ||--o{ ticket_categories : "handles"
    ticket_categories ||--o{ tickets : "routes"
    memberships ||--o{ tickets : "raises"
    memberships |o--o{ tickets : "works on"
    tickets ||--o{ ticket_comments : "has"
    memberships ||--o{ ticket_comments : "writes"
    tickets ||--o{ ticket_attachments : "has"
    files ||--o{ ticket_attachments : "attached as"

    tasks {
        uuid id PK
        uuid org_id FK
        int number "TASK-n, unique per org"
        text title
        text status "todo in_progress blocked done cancelled"
        text priority
        uuid assignee_id FK
        uuid created_by FK
        uuid team_id FK
        timestamptz due_at
        tsvector search "full-text"
        int version
    }
    task_comments {
        uuid id PK
        uuid org_id FK
        uuid task_id FK
        uuid author_id FK
        text body
        timestamptz deleted_at
    }
    task_attachments {
        uuid task_id PK, FK
        uuid file_id PK, FK
        uuid org_id FK
        uuid added_by FK
    }
    ticket_categories {
        uuid id PK
        uuid org_id FK
        text name "unique per org"
        uuid handling_team_id FK "this team works the queue"
    }
    tickets {
        uuid id PK
        uuid org_id FK
        int number "TKT-n, unique per org"
        uuid category_id FK
        uuid requester_id FK
        uuid assignee_id FK
        text status "open assigned in_progress waiting resolved closed"
        text priority
        int version
    }
    ticket_comments {
        uuid id PK
        uuid org_id FK
        uuid ticket_id FK
        uuid author_id FK
        boolean is_internal "hidden from requester"
        text body
    }
    ticket_attachments {
        uuid ticket_id PK, FK
        uuid file_id PK, FK
        uuid org_id FK
        uuid added_by FK
    }
    files {
        uuid id PK
        uuid org_id FK
        uuid uploaded_by FK
        text storage_key UK
        text mime_type
        bigint size_bytes "max 25 MB"
        text status "pending uploaded clean infected"
    }
```

## Calendar and announcements

An event or announcement is either for the whole company or targeted; each targeted audience row names exactly one department, team or person.

```mermaid
erDiagram
    organizations ||--o{ events : "schedules"
    memberships ||--o{ events : "creates"
    events ||--o{ event_audiences : "shown to"
    departments |o--o{ event_audiences : "targeted by"
    teams |o--o{ event_audiences : "targeted by"
    memberships |o--o{ event_audiences : "targeted by"
    organizations ||--o{ announcements : "publishes"
    memberships ||--o{ announcements : "writes"
    announcements ||--o{ announcement_audiences : "shown to"
    departments |o--o{ announcement_audiences : "targeted by"
    teams |o--o{ announcement_audiences : "targeted by"
    memberships |o--o{ announcement_audiences : "targeted by"
    announcements ||--o{ announcement_reads : "read as"
    memberships ||--o{ announcement_reads : "reads"
    announcements ||--o{ announcement_attachments : "has"
    files ||--o{ announcement_attachments : "attached as"

    events {
        uuid id PK
        uuid org_id FK
        text title
        timestamptz starts_at "timed events"
        timestamptz ends_at
        date start_date "all-day events"
        date end_date
        text audience "org or targeted"
        uuid created_by FK
    }
    event_audiences {
        uuid id PK
        uuid org_id FK
        uuid event_id FK
        uuid department_id FK "exactly one of these three"
        uuid team_id FK
        uuid membership_id FK
    }
    announcements {
        uuid id PK
        uuid org_id FK
        uuid author_id FK
        text title
        text audience "org or targeted"
        timestamptz publish_at
        timestamptz expires_at
    }
    announcement_audiences {
        uuid id PK
        uuid org_id FK
        uuid announcement_id FK
        uuid department_id FK "exactly one of these three"
        uuid team_id FK
        uuid membership_id FK
    }
    announcement_reads {
        uuid announcement_id PK, FK
        uuid membership_id PK, FK
        uuid org_id FK
        timestamptz read_at
    }
    announcement_attachments {
        uuid announcement_id PK, FK
        uuid file_id PK, FK
        uuid org_id FK
    }
```

## Platform: notifications, activity, outbox

activity_events and notifications point at any entity through entity_type + entity_id, so they carry no foreign key to tasks, tickets or leave.

```mermaid
erDiagram
    memberships ||--o{ notifications : "receives"
    memberships ||--o{ notification_preferences : "sets"
    organizations ||--o{ activity_events : "logs"
    memberships |o--o{ activity_events : "performs"
    organizations ||--o{ outbox_events : "emits"
    organizations ||--o{ scheduled_runs : "runs"
    memberships ||--o{ idempotency_keys : "sends"

    notifications {
        uuid id PK
        uuid org_id FK
        uuid recipient_id FK
        text kind "e.g. leave.approved"
        text entity_type "points at any entity"
        uuid entity_id
        uuid source_event_id "unique with recipient"
        timestamptz read_at
    }
    notification_preferences {
        uuid membership_id PK, FK
        text kind PK
        uuid org_id FK
        boolean in_app
        boolean email
    }
    activity_events {
        uuid id PK
        uuid org_id FK
        uuid actor_id FK "null = system"
        text entity_type
        uuid entity_id
        text action
        jsonb changes "append-only"
    }
    scheduled_runs {
        uuid org_id PK, FK
        text job_name PK "e.g. tasks.due_reminder"
        text period_key PK "org-local date or year"
        timestamptz completed_at
    }
    outbox_events {
        uuid id PK
        uuid org_id FK
        text event_type
        jsonb payload
        timestamptz sent_at "null = not yet relayed"
        int attempts
    }
    idempotency_keys {
        uuid membership_id PK, FK
        text idem_key PK
        uuid org_id FK
        bytea request_fingerprint
        text status "in_progress or completed"
        jsonb response_body
    }
```

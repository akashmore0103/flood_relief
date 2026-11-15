-- ============================================================================
-- FloodRelief Decision Support System (DSS)
-- Complete Idempotent PostgreSQL 16 / 17 / 18 Production Schema & Seed Engine
-- Target Environment: Render.com Managed PostgreSQL & Local PostgreSQL 16+
-- File: database/flood_relief_pgsql_full.sql
-- ============================================================================

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

-- ============================================================================
-- PART 1: IDEMPOTENT TEARDOWN (CLEAN DROP IN REVERSE DEPENDENCY ORDER)
-- ============================================================================

DROP VIEW IF EXISTS sos_requests CASCADE;
DROP VIEW IF EXISTS flood_alerts CASCADE;
DROP VIEW IF EXISTS dams_reservoirs CASCADE;
DROP VIEW IF EXISTS dam_telemetry_view CASCADE;
DROP VIEW IF EXISTS relief_camps CASCADE;

DROP TABLE IF EXISTS donations_volunteers CASCADE;
DROP TABLE IF EXISTS simulation_logs CASCADE;
DROP TABLE IF EXISTS missing_persons CASCADE;
DROP TABLE IF EXISTS citizen_profiles CASCADE;
DROP TABLE IF EXISTS alert_delivery_logs CASCADE;
DROP TABLE IF EXISTS alerts CASCADE;
DROP TABLE IF EXISTS help_request_logs CASCADE;
DROP TABLE IF EXISTS help_requests CASCADE;
DROP TABLE IF EXISTS camp_updates CASCADE;
DROP TABLE IF EXISTS camps CASCADE;
DROP TABLE IF EXISTS risk_levels CASCADE;
DROP TABLE IF EXISTS risk_rules CASCADE;
DROP TABLE IF EXISTS dam_telemetry CASCADE;
DROP TABLE IF EXISTS zones CASCADE;
DROP TABLE IF EXISTS dams CASCADE;
DROP TABLE IF EXISTS river_basins CASCADE;
DROP TABLE IF EXISTS rivers CASCADE;
DROP TABLE IF EXISTS user_preferences CASCADE;
DROP TABLE IF EXISTS system_settings CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS roles CASCADE;

-- ============================================================================
-- PART 2: DDL TABLE SCHEMAS (PURE POSTGRESQL 16/18 COMPLIANT)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ROLES TABLE
-- User authorization tiers: Administrator (1), Relief Coordinator (2), Citizen (3)
-- ----------------------------------------------------------------------------
CREATE TABLE roles (
    id SERIAL PRIMARY KEY,
    role_name VARCHAR(50) NOT NULL UNIQUE,
    description VARCHAR(255) NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 2. USERS TABLE
-- Core credentials, contact points, geofenced basin/dam links, and login audit
-- ----------------------------------------------------------------------------
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    role_id INT NOT NULL REFERENCES roles(id) ON UPDATE CASCADE,
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL UNIQUE,
    phone VARCHAR(20) NULL,
    district VARCHAR(100) NULL,
    river_basin_id INT NULL,
    monitored_dam_id INT NULL,
    address TEXT NULL,
    password_hash VARCHAR(255) NOT NULL,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended')),
    last_login TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_users_role ON users(role_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_district ON users(district);

-- ----------------------------------------------------------------------------
-- 3. RIVERS TABLE
-- Monitored Indian river courses, hydrologic thresholds, and current flow status
-- ----------------------------------------------------------------------------
CREATE TABLE rivers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    basin_name VARCHAR(100) NOT NULL,
    states_covered VARCHAR(255) NOT NULL,
    warning_level_meters NUMERIC(6, 2) NOT NULL,
    danger_mark_meters NUMERIC(6, 2) NOT NULL,
    current_level_meters NUMERIC(6, 2) NOT NULL,
    status VARCHAR(20) DEFAULT 'Normal' CHECK (status IN ('Normal', 'Warning', 'Danger')),
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_rivers_status ON rivers(status);
CREATE INDEX idx_rivers_basin_name ON rivers(basin_name);

-- ----------------------------------------------------------------------------
-- 4. RIVER BASINS TABLE
-- Catchment drainage basins, regional watersheds, and primary river references
-- ----------------------------------------------------------------------------
CREATE TABLE river_basins (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    river_id INT NULL REFERENCES rivers(id) ON DELETE SET NULL,
    description TEXT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_river_basins_name ON river_basins(name);
CREATE INDEX idx_river_basins_river_id ON river_basins(river_id);

-- ----------------------------------------------------------------------------
-- 5. DAMS & RESERVOIRS TABLE
-- Major reservoirs, gross storage capacity (TMC), live storage %, and discharge
-- ----------------------------------------------------------------------------
CREATE TABLE dams (
    id SERIAL PRIMARY KEY,
    river_id INT NOT NULL REFERENCES rivers(id) ON DELETE CASCADE,
    name VARCHAR(150) NOT NULL,
    state VARCHAR(100) NOT NULL,
    district VARCHAR(100) NOT NULL,
    gross_capacity_tmc NUMERIC(8, 2) NOT NULL,
    current_storage_tmc NUMERIC(8, 2) NOT NULL,
    live_storage_pct NUMERIC(5, 2) NOT NULL,
    water_level_meters NUMERIC(6, 2) NOT NULL,
    fsl_meters NUMERIC(6, 2) NOT NULL,
    inflow_cusecs INT NOT NULL DEFAULT 0,
    outflow_cusecs INT NOT NULL DEFAULT 0,
    gate_status VARCHAR(150) DEFAULT 'All Gates Closed',
    latitude NUMERIC(10, 7) NOT NULL,
    longitude NUMERIC(10, 7) NOT NULL,
    last_updated TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_dams_river ON dams(river_id);
CREATE INDEX idx_dams_state ON dams(state);
CREATE INDEX idx_dams_district ON dams(district);
CREATE INDEX idx_dams_storage_pct ON dams(live_storage_pct);

-- Wire foreign keys back from users to river_basins and dams safely
ALTER TABLE users ADD CONSTRAINT fk_users_basin FOREIGN KEY (river_basin_id) REFERENCES river_basins(id) ON DELETE SET NULL;
ALTER TABLE users ADD CONSTRAINT fk_users_dam FOREIGN KEY (monitored_dam_id) REFERENCES dams(id) ON DELETE SET NULL;

-- ----------------------------------------------------------------------------
-- 6. DAM TELEMETRY OBSERVATIONS TABLE
-- Time-series telemetry snapshots, water inflow/outflow, and gate position history
-- ----------------------------------------------------------------------------
CREATE TABLE dam_telemetry (
    id SERIAL PRIMARY KEY,
    dam_id INT NOT NULL REFERENCES dams(id) ON DELETE CASCADE,
    water_level_meters NUMERIC(6, 2) NOT NULL,
    current_storage_tmc NUMERIC(8, 2) NOT NULL,
    live_storage_pct NUMERIC(5, 2) NOT NULL,
    inflow_cusecs INT NOT NULL DEFAULT 0,
    outflow_cusecs INT NOT NULL DEFAULT 0,
    gate_status VARCHAR(150) DEFAULT 'Normal',
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    source VARCHAR(100) DEFAULT 'Central Water Commission (CWC)'
);
CREATE INDEX idx_dam_telemetry_dam_date ON dam_telemetry(dam_id, recorded_at);

-- ----------------------------------------------------------------------------
-- 7. DISASTER MONITORING ZONES TABLE
-- Geospatial monitoring sectors, boundary polygons, gauge points, and live risk
-- ----------------------------------------------------------------------------
CREATE TABLE zones (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL DEFAULT '',
    zone_name VARCHAR(150) NULL,
    district VARCHAR(100) NOT NULL,
    state VARCHAR(100) DEFAULT 'Maharashtra',
    latitude NUMERIC(10, 7) NOT NULL,
    longitude NUMERIC(10, 7) NOT NULL,
    boundary_geojson TEXT NULL,
    river_basin VARCHAR(100) NULL,
    river_id INT NULL REFERENCES rivers(id) ON DELETE SET NULL,
    primary_dam_id INT NULL REFERENCES dams(id) ON DELETE SET NULL,
    warning_level_m NUMERIC(6, 2) NULL,
    danger_level_m NUMERIC(6, 2) NULL,
    current_water_level_m NUMERIC(6, 2) NULL,
    rainfall_24h_mm NUMERIC(6, 2) NULL,
    risk_level VARCHAR(50) NULL,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_zones_coords ON zones(latitude, longitude);
CREATE INDEX idx_zones_district ON zones(district);
CREATE INDEX idx_zones_river ON zones(river_id);
CREATE INDEX idx_zones_dam ON zones(primary_dam_id);

-- ----------------------------------------------------------------------------
-- 8. RISK RULES TABLE
-- Configurable formula weights, normalization ceilings, and classification bands
-- ----------------------------------------------------------------------------
CREATE TABLE risk_rules (
    id SERIAL PRIMARY KEY,
    rule_name VARCHAR(100) NOT NULL,
    rainfall_weight NUMERIC(4, 2) NOT NULL DEFAULT 0.50,
    river_weight NUMERIC(4, 2) NOT NULL DEFAULT 0.50,
    max_rainfall_baseline NUMERIC(6, 2) NOT NULL DEFAULT 250.00,
    max_river_baseline NUMERIC(5, 2) NOT NULL DEFAULT 15.00,
    low_max_score NUMERIC(5, 2) NOT NULL DEFAULT 25.00,
    mod_max_score NUMERIC(5, 2) NOT NULL DEFAULT 50.00,
    high_max_score NUMERIC(5, 2) NOT NULL DEFAULT 75.00,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    updated_by INT NULL REFERENCES users(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 9. RISK LEVELS TABLE
-- Recorded hydrological observations per zone, computed risk scores, and categories
-- ----------------------------------------------------------------------------
CREATE TABLE risk_levels (
    id SERIAL PRIMARY KEY,
    zone_id INT NOT NULL REFERENCES zones(id) ON DELETE CASCADE,
    rainfall_value NUMERIC(6, 2) NOT NULL DEFAULT 0.00,
    river_level_value NUMERIC(5, 2) NOT NULL DEFAULT 0.00,
    score NUMERIC(5, 2) NOT NULL,
    category VARCHAR(20) NOT NULL CHECK (category IN ('Low', 'Moderate', 'High', 'Critical')),
    source VARCHAR(100) DEFAULT 'Manual Entry',
    observed_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_risk_zone_date ON risk_levels(zone_id, observed_at);
CREATE INDEX idx_risk_category ON risk_levels(category);

-- ----------------------------------------------------------------------------
-- 10. RELIEF CAMPS & EMERGENCY SHELTERS TABLE
-- Relief shelters with GPS coordinates, capacity, supply status, and dam links
-- ----------------------------------------------------------------------------
CREATE TABLE camps (
    id SERIAL PRIMARY KEY,
    zone_id INT NULL REFERENCES zones(id) ON DELETE SET NULL,
    dam_id INT NULL REFERENCES dams(id) ON DELETE SET NULL,
    river_basin_id INT NULL REFERENCES river_basins(id) ON DELETE SET NULL,
    name VARCHAR(150) NOT NULL UNIQUE,
    camp_name VARCHAR(150) NULL,
    address TEXT NOT NULL,
    district VARCHAR(100) NOT NULL,
    latitude NUMERIC(10, 7) NOT NULL,
    longitude NUMERIC(10, 7) NOT NULL,
    contact_person VARCHAR(100) NOT NULL,
    contact_phone VARCHAR(20) NOT NULL,
    total_capacity INT NOT NULL DEFAULT 100,
    current_occupancy INT NOT NULL DEFAULT 0,
    status VARCHAR(20) DEFAULT 'Operational' CHECK (status IN ('Operational', 'Full', 'Standby', 'Closed', 'Active')),
    supply_status VARCHAR(30) DEFAULT 'Sufficient' CHECK (supply_status IN ('Abundant', 'Sufficient', 'Critical', 'Replenishment Needed')),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_camps_coords ON camps(latitude, longitude);
CREATE INDEX idx_camps_status ON camps(status, active);
CREATE INDEX idx_camps_dam ON camps(dam_id);
CREATE INDEX idx_camps_basin ON camps(river_basin_id);

-- ----------------------------------------------------------------------------
-- 11. CAMP OCCUPANCY & CAPACITY AUDIT UPDATES TABLE
-- Lifecycle tracking of headcount shifts, available bed changes, and coordinator notes
-- ----------------------------------------------------------------------------
CREATE TABLE camp_updates (
    id SERIAL PRIMARY KEY,
    camp_id INT NOT NULL REFERENCES camps(id) ON DELETE CASCADE,
    previous_occupancy INT NOT NULL,
    new_occupancy INT NOT NULL,
    previous_status VARCHAR(50) NOT NULL,
    new_status VARCHAR(50) NOT NULL,
    updated_by INT NULL REFERENCES users(id) ON DELETE SET NULL,
    remarks VARCHAR(255) NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_camp_updates_camp ON camp_updates(camp_id);

-- ----------------------------------------------------------------------------
-- 12. CITIZEN PERSONALIZED WATCH PROFILES TABLE
-- Bookmarked village, nearby river, and upstream dam for personalized watch
-- ----------------------------------------------------------------------------
CREATE TABLE citizen_profiles (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    saved_village_city VARCHAR(150) NULL,
    saved_river_id INT NULL REFERENCES rivers(id) ON DELETE SET NULL,
    saved_dam_id INT NULL REFERENCES dams(id) ON DELETE SET NULL,
    alert_notifications_enabled BOOLEAN DEFAULT TRUE,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 13. HELP & SOS EVACUATION REQUESTS TABLE
-- Citizen emergency assistance requests with unique reference code and GPS pin
-- ----------------------------------------------------------------------------
CREATE TABLE help_requests (
    id SERIAL PRIMARY KEY,
    reference_code VARCHAR(30) NOT NULL UNIQUE,
    citizen_id INT NULL REFERENCES users(id) ON DELETE SET NULL,
    guest_name VARCHAR(100) NOT NULL,
    guest_phone VARCHAR(20) NOT NULL,
    guest_email VARCHAR(120) NULL,
    request_type VARCHAR(30) NOT NULL DEFAULT 'Evacuation' CHECK (request_type IN ('Evacuation', 'Medical Support', 'Food & Water', 'Shelter', 'Missing Person', 'Other')),
    urgency VARCHAR(20) NOT NULL DEFAULT 'High' CHECK (urgency IN ('Low', 'Medium', 'High', 'Critical')),
    water_severity VARCHAR(30) NOT NULL DEFAULT 'Waist-Level' CHECK (water_severity IN ('Ankle-Level', 'Waist-Level', 'Roof-Level', 'Dry/Threatened')),
    mobile_verified BOOLEAN DEFAULT TRUE,
    people_count INT NOT NULL DEFAULT 1,
    description TEXT NOT NULL,
    address TEXT NOT NULL,
    latitude NUMERIC(10, 7) NOT NULL,
    longitude NUMERIC(10, 7) NOT NULL,
    status VARCHAR(20) DEFAULT 'New' CHECK (status IN ('New', 'Acknowledged', 'In Progress', 'Resolved', 'Closed')),
    assigned_to INT NULL REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_help_status ON help_requests(status);
CREATE INDEX idx_help_urgency ON help_requests(urgency);
CREATE INDEX idx_help_coords ON help_requests(latitude, longitude);
CREATE INDEX idx_help_reference ON help_requests(reference_code);

-- ----------------------------------------------------------------------------
-- 14. HELP REQUEST LIFECYCLE LOGS TABLE
-- Lifecycle tracking of status updates, notes, and coordinator dispatch actions
-- ----------------------------------------------------------------------------
CREATE TABLE help_request_logs (
    id SERIAL PRIMARY KEY,
    request_id INT NOT NULL REFERENCES help_requests(id) ON DELETE CASCADE,
    action VARCHAR(100) NOT NULL,
    previous_status VARCHAR(50) NULL,
    new_status VARCHAR(50) NOT NULL,
    action_by INT NULL REFERENCES users(id) ON DELETE SET NULL,
    notes TEXT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_help_logs_request ON help_request_logs(request_id);

-- ----------------------------------------------------------------------------
-- 15. EMERGENCY FLOOD ALERTS & BROADCASTS TABLE
-- Emergency bulletins, high-water warnings, and evacuation orders broadcasted
-- ----------------------------------------------------------------------------
CREATE TABLE alerts (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    message TEXT NOT NULL,
    instructions TEXT NULL,
    severity VARCHAR(30) NOT NULL DEFAULT 'Warning' CHECK (severity IN ('Advisory', 'Warning', 'Evacuation', 'Critical Danger')),
    target_zone_id INT NULL REFERENCES zones(id) ON DELETE SET NULL,
    channel VARCHAR(50) DEFAULT 'In-App',
    channels VARCHAR(100) DEFAULT 'Web,Email,SMS',
    status VARCHAR(20) DEFAULT 'Published' CHECK (status IN ('Draft', 'Published', 'Archived')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_by INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_alerts_status_severity ON alerts(status, severity);
CREATE INDEX idx_alerts_zone ON alerts(target_zone_id);

-- ----------------------------------------------------------------------------
-- 16. ALERT DELIVERY LOGS TABLE
-- Records dispatch of SMS, Email, and Push notifications to citizens
-- ----------------------------------------------------------------------------
CREATE TABLE alert_delivery_logs (
    id SERIAL PRIMARY KEY,
    alert_id INT NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    recipient_user_id INT NULL REFERENCES users(id) ON DELETE SET NULL,
    channel VARCHAR(100) NOT NULL DEFAULT 'Email',
    recipient_target VARCHAR(150) NULL,
    recipient_contact VARCHAR(150) NULL,
    delivery_status VARCHAR(30) DEFAULT 'Sent' CHECK (delivery_status IN ('Pending', 'Sent', 'Delivered', 'Failed')),
    details TEXT NULL,
    error_message VARCHAR(255) NULL,
    sent_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    dispatched_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_alert_delivery_alert ON alert_delivery_logs(alert_id);

-- ----------------------------------------------------------------------------
-- 17. MISSING & FOUND PERSONS REGISTRY TABLE
-- Public community directory for flood rescue and missing family tracing
-- ----------------------------------------------------------------------------
CREATE TABLE missing_persons (
    id SERIAL PRIMARY KEY,
    report_type VARCHAR(20) NOT NULL DEFAULT 'Missing' CHECK (report_type IN ('Missing', 'Found')),
    person_name VARCHAR(120) NOT NULL,
    gender VARCHAR(20) NOT NULL CHECK (gender IN ('Male', 'Female', 'Child', 'Other')),
    age INT NULL,
    last_seen_or_found_location VARCHAR(255) NOT NULL,
    last_seen_or_found_date DATE NOT NULL,
    photo_url VARCHAR(255) NULL,
    contact_name VARCHAR(120) NOT NULL,
    contact_phone VARCHAR(20) NOT NULL,
    contact_relation VARCHAR(100) NULL,
    camp_id INT NULL REFERENCES camps(id) ON DELETE SET NULL,
    status VARCHAR(20) DEFAULT 'Reported' CHECK (status IN ('Reported', 'Verified', 'Reunited', 'Closed')),
    reported_by_user_id INT NULL REFERENCES users(id) ON DELETE SET NULL,
    notes TEXT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_missing_status ON missing_persons(status, report_type);
CREATE INDEX idx_missing_name ON missing_persons(person_name);

-- ----------------------------------------------------------------------------
-- 18. RELIEF DONATIONS & VOLUNTEERS DIRECTORY TABLE
-- Citizen donation pledges, relief supply offers, and field volunteer enrollments
-- ----------------------------------------------------------------------------
CREATE TABLE donations_volunteers (
    id SERIAL PRIMARY KEY,
    type VARCHAR(20) NOT NULL CHECK (type IN ('Donation', 'Volunteer', 'Supplies')),
    full_name VARCHAR(120) NOT NULL,
    email VARCHAR(150) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    district VARCHAR(100) NOT NULL,
    state VARCHAR(100) DEFAULT 'Maharashtra',
    item_category VARCHAR(50) NULL CHECK (item_category IN ('Funds', 'Food Kits', 'Drinking Water', 'Medical Supplies', 'Blankets & Clothing', 'Rescue Equipment', 'General Service', 'Medical Service', 'Boat Operations')),
    amount NUMERIC(12, 2) NULL DEFAULT 0.00,
    quantity_description TEXT NULL,
    skills_or_notes TEXT NULL,
    assigned_camp_id INT NULL REFERENCES camps(id) ON DELETE SET NULL,
    status VARCHAR(20) DEFAULT 'Pending' CHECK (status IN ('Pending', 'Approved', 'Dispatched', 'Received', 'Completed', 'Cancelled')),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_donations_type ON donations_volunteers(type);
CREATE INDEX idx_donations_status ON donations_volunteers(status);

-- ----------------------------------------------------------------------------
-- 19. SIMULATION LOGS TABLE
-- Records administrator viva simulation runs and parameter triggers
-- ----------------------------------------------------------------------------
CREATE TABLE simulation_logs (
    id SERIAL PRIMARY KEY,
    triggered_by INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dam_id INT NOT NULL REFERENCES dams(id) ON DELETE CASCADE,
    simulated_rainfall_mm NUMERIC(6, 2) NOT NULL,
    simulated_discharge_cusecs INT NOT NULL,
    action VARCHAR(20) NOT NULL CHECK (action IN ('Triggered', 'Reset')),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 20. AUDIT LOGS TABLE
-- Administrative audit trail (data imports, threshold changes, logins)
-- ----------------------------------------------------------------------------
CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    user_id INT NULL REFERENCES users(id) ON DELETE SET NULL,
    action_type VARCHAR(100) NOT NULL,
    table_affected VARCHAR(50) NULL,
    record_id INT NULL,
    details TEXT NULL,
    ip_address VARCHAR(45) NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_audit_action ON audit_logs(action_type);
CREATE INDEX idx_audit_created ON audit_logs(created_at);

-- ----------------------------------------------------------------------------
-- 21. USER PREFERENCES TABLE
-- User UI theme, language choice, and notification subscription toggles
-- ----------------------------------------------------------------------------
CREATE TABLE user_preferences (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    language VARCHAR(10) DEFAULT 'en',
    theme VARCHAR(10) DEFAULT 'light',
    email_alerts BOOLEAN DEFAULT TRUE,
    sms_alerts BOOLEAN DEFAULT TRUE,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 22. SYSTEM SETTINGS TABLE
-- Key-value administrative parameters, portal metadata, and system banners
-- ----------------------------------------------------------------------------
CREATE TABLE system_settings (
    id SERIAL PRIMARY KEY,
    setting_key VARCHAR(100) NOT NULL UNIQUE,
    setting_value TEXT NULL,
    description VARCHAR(255) NULL,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- PART 3: APPLICATION COMPATIBILITY VIEWS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. RELIEF CAMPS VIEW (Used across Public & Coordinator Map Interfaces)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW relief_camps AS 
SELECT c.*, 
       c.id AS camp_id,
       COALESCE(c.camp_name, c.name) AS display_name,
       (c.total_capacity - c.current_occupancy) AS available_beds
FROM camps c;

-- ----------------------------------------------------------------------------
-- 2. DAMS & RESERVOIRS COMPATIBILITY VIEW
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW dams_reservoirs AS 
SELECT d.*,
       d.id AS dam_id,
       d.live_storage_pct AS storage_percent,
       d.gate_status AS flood_gate_status,
       d.water_level_meters AS water_level_m,
       d.fsl_meters AS full_reservoir_level_m,
       r.name AS river_name,
       r.basin_name
FROM dams d
LEFT JOIN rivers r ON d.river_id = r.id;

-- ----------------------------------------------------------------------------
-- 3. FLOOD ALERTS VIEW
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW flood_alerts AS 
SELECT a.*,
       a.id AS alert_id,
       a.expires_at AS valid_until,
       z.name AS zone_name,
       u.full_name AS author_name
FROM alerts a
LEFT JOIN zones z ON a.target_zone_id = z.id
LEFT JOIN users u ON a.created_by = u.id;

-- ----------------------------------------------------------------------------
-- 4. SOS EMERGENCY REQUESTS VIEW
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sos_requests AS 
SELECT hr.*,
       hr.id AS request_id,
       hr.people_count AS affected_persons,
       u.full_name AS assigned_coordinator_name
FROM help_requests hr
LEFT JOIN users u ON hr.assigned_to = u.id;

-- ----------------------------------------------------------------------------
-- 5. DAM TELEMETRY TIME-SERIES VIEW
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW dam_telemetry_view AS 
SELECT dt.*,
       d.name AS dam_name,
       d.district AS dam_district,
       r.name AS river_name,
       r.basin_name
FROM dam_telemetry dt
JOIN dams d ON dt.dam_id = d.id
JOIN rivers r ON d.river_id = r.id;

-- ============================================================================
-- PART 4: RICH INDIAN REALISTIC SEED DATA
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SEED ROLES
-- ----------------------------------------------------------------------------
INSERT INTO roles (id, role_name, description) VALUES
(1, 'Administrator', 'Full system control, rule configuration, zone setup, data import, and emergency alert broadcasting'),
(2, 'Relief Coordinator', 'Operational manager triaging emergency help requests, assigning teams, and updating camp capacities'),
(3, 'Citizen', 'Public user viewing flood risks, discovering nearest relief camps, and submitting emergency help requests');

-- ----------------------------------------------------------------------------
-- 2. SEED MAJOR INDIAN RIVERS
-- ----------------------------------------------------------------------------
INSERT INTO rivers (id, name, basin_name, states_covered, warning_level_meters, danger_mark_meters, current_level_meters, status) VALUES
(1, 'Godavari River', 'Godavari Basin', 'Maharashtra, Telangana, Andhra Pradesh, Chhattisgarh', 14.50, 16.20, 15.35, 'Warning'),
(2, 'Krishna River', 'Krishna Basin', 'Maharashtra, Karnataka, Telangana, Andhra Pradesh', 52.00, 54.50, 53.60, 'Warning'),
(3, 'Ganga River', 'Ganga Basin', 'Uttarakhand, Uttar Pradesh, Bihar, West Bengal', 70.20, 71.30, 69.80, 'Normal'),
(4, 'Yamuna River', 'Yamuna Basin', 'Haryana, Delhi, Uttar Pradesh', 204.50, 205.30, 205.10, 'Warning'),
(5, 'Narmada River', 'Narmada Basin', 'Madhya Pradesh, Maharashtra, Gujarat', 28.00, 31.00, 27.40, 'Normal'),
(6, 'Brahmaputra River', 'Brahmaputra Basin', 'Arunachal Pradesh, Assam', 49.60, 50.50, 50.25, 'Warning'),
(7, 'Mahanadi River', 'Mahanadi Basin', 'Chhattisgarh, Odisha', 26.50, 27.40, 29.10, 'Danger'),
(8, 'Periyar River', 'Periyar Basin', 'Kerala, Tamil Nadu', 12.00, 13.50, 13.15, 'Warning'),
(9, 'Kosi River', 'Kosi Basin', 'Bihar', 48.00, 50.50, 51.20, 'Danger'),
(10, 'Panchganga River', 'Krishna-Panchganga Basin', 'Maharashtra', 39.00, 43.00, 37.50, 'Normal'),
(11, 'Bhima River', 'Bhima Basin', 'Maharashtra, Karnataka', 415.50, 418.00, 414.20, 'Normal'),
(12, 'Mutha River', 'Bhima Basin', 'Maharashtra (Pune)', 580.50, 582.70, 579.80, 'Normal'),
(13, 'Tapi River', 'Tapi Basin', 'Madhya Pradesh, Maharashtra, Gujarat', 211.50, 214.00, 210.50, 'Normal'),
(14, 'Pravara River', 'Godavari Basin', 'Maharashtra (Ahmednagar)', 744.50, 746.50, 743.10, 'Normal'),
(15, 'Mula River', 'Godavari Basin', 'Maharashtra (Ahmednagar)', 549.50, 551.50, 548.20, 'Normal'),
(16, 'Ambi River', 'Bhima Basin', 'Maharashtra (Pune)', 636.50, 638.70, 635.40, 'Normal'),
(17, 'Ulhas River', 'Konkan Coastal Basin', 'Maharashtra (Thane/Mumbai)', 140.00, 142.50, 138.80, 'Normal'),
(18, 'Kaveri River', 'Kaveri Basin', 'Karnataka, Tamil Nadu', 65.50, 67.50, 64.80, 'Normal'),
(19, 'Pamba River', 'Periyar Basin', 'Kerala', 8.50, 10.20, 9.40, 'Warning'),
(20, 'Chalakudy River', 'Periyar Basin', 'Kerala', 6.00, 7.50, 6.80, 'Normal');

-- ----------------------------------------------------------------------------
-- 3. SEED RIVER BASINS
-- ----------------------------------------------------------------------------
INSERT INTO river_basins (id, name, river_id, description) VALUES
(1, 'Godavari Basin', 1, 'Godavari River catchment and regional drainage basin (Maharashtra/Telangana)'),
(2, 'Krishna Basin', 2, 'Krishna River catchment and regional drainage basin (Western Maharashtra/Karnataka)'),
(3, 'Ganga Basin', 3, 'Ganga River catchment and northern plains drainage basin'),
(4, 'Yamuna Basin', 4, 'Yamuna River catchment basin (Delhi, Haryana, Uttar Pradesh)'),
(5, 'Narmada Basin', 5, 'Narmada River catchment and rift valley drainage basin'),
(6, 'Brahmaputra Basin', 6, 'Brahmaputra Valley and northeastern flood basin (Assam)'),
(7, 'Mahanadi Basin', 7, 'Mahanadi River delta and eastern catchment basin (Odisha)'),
(8, 'Periyar Basin', 8, 'Periyar and Central Kerala Western Ghats drainage basin'),
(9, 'Kosi Basin', 9, 'Kosi River flood basin (North Bihar)'),
(10, 'Krishna-Panchganga Basin', 10, 'Panchganga and upper Krishna sub-basin (Kolhapur/Sangli)'),
(11, 'Bhima Basin', 11, 'Bhima River sub-basin feeding into Krishna system (Pune/Solapur)'),
(12, 'Tapi Basin', 13, 'Tapi River northern Maharashtra drainage basin (Jalgaon/Khandesh)'),
(13, 'Kaveri Basin', 18, 'Kaveri Southern Indian agricultural and flood basin (Karnataka/Tamil Nadu)'),
(14, 'Konkan Coastal Basin', 17, 'Western Ghats to Arabian Sea coastal estuaries and rivers');

-- ----------------------------------------------------------------------------
-- 4. SEED DAMS & RESERVOIRS
-- ----------------------------------------------------------------------------
INSERT INTO dams (id, river_id, name, state, district, gross_capacity_tmc, current_storage_tmc, live_storage_pct, water_level_meters, fsl_meters, inflow_cusecs, outflow_cusecs, gate_status, latitude, longitude, last_updated) VALUES
(1, 1, 'Jayakwadi Dam (Nath Sagar)', 'Maharashtra', 'Chhatrapati Sambhajinagar', 102.70, 92.40, 89.97, 463.50, 463.90, 38500, 42000, '18 Gates Opened at 1.5 ft', 19.4975000, 75.3888000, NOW()),
(2, 2, 'Koyna Dam (Shivsagar Lake)', 'Maharashtra', 'Satara', 105.20, 98.60, 93.72, 657.80, 659.43, 45000, 62500, '6 Radial Gates Raised 3.0 ft', 17.4000000, 73.7500000, NOW()),
(3, 2, 'Almatti Dam (Lal Bahadur Shastri Sagar)', 'Karnataka', 'Bagalkot', 123.08, 108.50, 88.15, 519.20, 519.60, 95000, 120000, '26 Crest Gates Discharging', 16.3312000, 75.8890000, NOW()),
(4, 3, 'Tehri Dam Reservoir', 'Uttarakhand', 'Tehri Garhwal', 148.00, 112.50, 76.01, 820.50, 830.00, 22000, 18500, 'Spillway Controlled Flow', 30.3789000, 78.4800000, NOW()),
(5, 5, 'Sardar Sarovar Dam', 'Gujarat', 'Narmada', 334.00, 295.20, 88.38, 136.80, 138.68, 85000, 115000, '23 Radial Gates Open at 1.8m', 21.8315000, 73.7483000, NOW()),
(6, 7, 'Hirakud Dam', 'Odisha', 'Sambalpur', 204.00, 186.20, 91.27, 191.80, 192.02, 110000, 145000, '12 Sluice Gates Discharging', 21.5700000, 83.8700000, NOW()),
(7, 2, 'Prakasam Barrage', 'Andhra Pradesh', 'Krishna (Vijayawada)', 3.07, 2.95, 96.09, 17.50, 17.39, 175000, 185000, '70 Gates Fully Raised', 16.5074000, 80.6053000, NOW()),
(8, 8, 'Idukki Arch Dam & Cheruthoni Reservoir', 'Kerala', 'Idukki', 70.50, 64.20, 91.06, 732.10, 732.43, 14200, 16800, '2 Shutters Open at 50 cm', 9.8497000, 76.9740000, NOW()),
(9, 1, 'Gangapur Dam (Nashik)', 'Maharashtra', 'Nashik', 5.63, 5.28, 93.78, 610.15, 610.82, 12400, 15200, '4 Spillway Gates Open at 1.0 ft', 19.9985000, 73.7120000, NOW()),
(10, 15, 'Mula Dam (Rahuri)', 'Maharashtra', 'Ahmednagar', 26.00, 24.15, 92.88, 550.20, 551.00, 18200, 22000, '5 Gates Raised at 1.5 ft', 19.3450000, 74.6120000, NOW()),
(11, 14, 'Bhandardara Dam (Wilson Dam)', 'Maharashtra', 'Ahmednagar', 11.04, 10.45, 94.65, 745.20, 746.00, 8500, 9800, 'Radial Gates Active', 19.5412000, 73.7621000, NOW()),
(12, 10, 'Radhanagari Dam (Laxmi Sagar)', 'Maharashtra', 'Kolhapur', 8.36, 8.02, 95.93, 535.80, 536.00, 14500, 18200, 'Auto Siphons Operating (Gates 1-4)', 16.4180000, 73.9920000, NOW()),
(13, 12, 'Khadakwasla Dam', 'Maharashtra', 'Pune', 1.97, 1.91, 96.95, 582.40, 582.70, 9200, 11400, 'Spillway Flushed at 2.0 ft', 18.4350000, 73.7620000, NOW()),
(14, 11, 'Ujani Dam (Bhima Reservoir)', 'Maharashtra', 'Solapur', 117.20, 112.50, 95.99, 496.65, 496.83, 42000, 56000, '16 Crest Gates Raised at 2.5 ft', 18.0750000, 75.1180000, NOW()),
(15, 16, 'Panshet Dam (Tanajisagar)', 'Maharashtra', 'Pune', 10.65, 10.15, 95.30, 638.20, 638.50, 6200, 7800, 'Controlled Spillway Discharge', 18.3750000, 73.6120000, NOW()),
(16, 1, 'Upper Vaitarna Dam', 'Maharashtra', 'Nashik', 11.70, 10.88, 92.99, 603.20, 603.50, 7800, 9200, 'Discharging into Middle Vaitarna', 19.7890000, 73.4900000, NOW()),
(17, 17, 'Bhatsa Dam', 'Maharashtra', 'Thane', 34.00, 31.85, 93.68, 141.20, 142.00, 16500, 19800, 'Gates Raised 1.2m', 19.3850000, 73.2850000, NOW()),
(18, 13, 'Hatnur Dam (Tapi River)', 'Maharashtra', 'Jalgaon', 9.00, 8.45, 93.89, 213.50, 214.00, 32000, 48000, '12 Gates Open at 1.8m', 21.0750000, 75.9250000, NOW()),
(19, 8, 'Mullaperiyar Dam', 'Kerala', 'Idukki', 15.50, 14.80, 95.48, 43.10, 43.28, 8500, 9200, 'Spillway Active - 6 Shutters Lifted', 9.5290000, 77.1460000, NOW()),
(20, 18, 'Krishna Raja Sagara (KRS) Dam', 'Karnataka', 'Mandya', 49.45, 45.20, 91.41, 37.80, 38.04, 38000, 44000, '80 Sluice Gates Regulated', 12.4280000, 76.5720000, NOW()),
(21, 9, 'Kosi Barrage Reservoir', 'Bihar', 'Supaul', 45.00, 42.80, 95.11, 74.20, 74.50, 185000, 210000, '38 Gates Fully Lifted', 26.5200000, 86.9300000, NOW());

-- ----------------------------------------------------------------------------
-- 5. SEED DAM TELEMETRY TIME-SERIES SNAPSHOTS
-- ----------------------------------------------------------------------------
INSERT INTO dam_telemetry (dam_id, water_level_meters, current_storage_tmc, live_storage_pct, inflow_cusecs, outflow_cusecs, gate_status, recorded_at, source) VALUES
(1, 463.10, 90.10, 87.73, 35000, 38000, '12 Gates Open', NOW() - INTERVAL '12 hours', 'CWC Hydrology Telemetry'),
(1, 463.50, 92.40, 89.97, 38500, 42000, '18 Gates Opened at 1.5 ft', NOW(), 'CWC Hydrology Telemetry'),
(2, 656.90, 95.40, 90.68, 42000, 55000, '4 Gates Raised 2.0 ft', NOW() - INTERVAL '12 hours', 'Maharashtra WRD Telemetry'),
(2, 657.80, 98.60, 93.72, 45000, 62500, '6 Radial Gates Raised 3.0 ft', NOW(), 'Maharashtra WRD Telemetry'),
(3, 518.80, 105.20, 85.47, 90000, 110000, '20 Gates Active', NOW() - INTERVAL '8 hours', 'Karnataka CWC Station'),
(3, 519.20, 108.50, 88.15, 95000, 120000, '26 Crest Gates Discharging', NOW(), 'Karnataka CWC Station'),
(8, 731.80, 62.50, 88.65, 12000, 14000, '1 Shutter Open', NOW() - INTERVAL '10 hours', 'Kerala Dam Safety Authority'),
(8, 732.10, 64.20, 91.06, 14200, 16800, '2 Shutters Open at 50 cm', NOW(), 'Kerala Dam Safety Authority'),
(13, 581.90, 1.85, 93.90, 8500, 9800, 'Spillway Flushed at 1.0 ft', NOW() - INTERVAL '6 hours', 'Pune Irrigation Division'),
(13, 582.40, 1.91, 96.95, 9200, 11400, 'Spillway Flushed at 2.0 ft', NOW(), 'Pune Irrigation Division'),
(14, 496.20, 110.10, 93.94, 38000, 50000, '12 Gates Open', NOW() - INTERVAL '6 hours', 'Solapur WRD Division'),
(14, 496.65, 112.50, 95.99, 42000, 56000, '16 Crest Gates Raised at 2.5 ft', NOW(), 'Solapur WRD Division');

-- ----------------------------------------------------------------------------
-- 6. SEED DISASTER MONITORING ZONES
-- ----------------------------------------------------------------------------
INSERT INTO zones (id, name, zone_name, district, state, latitude, longitude, boundary_geojson, river_basin, river_id, primary_dam_id, warning_level_m, danger_level_m, current_water_level_m, rainfall_24h_mm, risk_level, status) VALUES
(1, 'Aluva - Lower Periyar Basin', 'Aluva - Lower Periyar Basin', 'Ernakulam', 'Kerala', 10.1076000, 76.3516000, '{"type":"Polygon","coordinates":[[[76.330,10.090],[76.370,10.090],[76.370,10.130],[76.330,10.130],[76.330,10.090]]]}', 'Periyar Basin', 8, 8, 12.00, 13.50, 13.20, 195.00, 'Critical', 'active'),
(2, 'Kuttanad Delta Lowlands', 'Kuttanad Delta Lowlands', 'Alappuzha', 'Kerala', 9.4230000, 76.5126000, '{"type":"Polygon","coordinates":[[[76.490,9.400],[76.530,9.400],[76.530,9.440],[76.490,9.440],[76.490,9.400]]]}', 'Krishna Basin', 2, 2, 8.50, 10.00, 9.60, 145.00, 'High', 'active'),
(3, 'Chalakudy River Catchment', 'Chalakudy River Catchment', 'Thrissur', 'Kerala', 10.3070000, 76.3330000, '{"type":"Polygon","coordinates":[[[76.310,10.290],[76.350,10.290],[76.350,10.330],[76.310,10.330],[76.310,10.290]]]}', 'Periyar Basin', 8, 8, 5.50, 7.00, 6.20, 85.00, 'Moderate', 'active'),
(4, 'Ranni - Upper Pamba Basin', 'Ranni - Upper Pamba Basin', 'Pathanamthitta', 'Kerala', 9.3812000, 76.7885000, '{"type":"Polygon","coordinates":[[[76.760,9.360],[76.810,9.360],[76.810,9.400],[76.760,9.400],[76.760,9.360]]]}', 'Periyar Basin', 8, 8, 2.50, 4.00, 2.80, 35.00, 'Low', 'active'),
(5, 'Meppadi - Vythiri Hilly Zone', 'Meppadi - Vythiri Hilly Zone', 'Wayanad', 'Kerala', 11.5540000, 76.1260000, '{"type":"Polygon","coordinates":[[[76.100,11.530],[76.150,11.530],[76.150,11.570],[76.100,11.570],[76.100,11.530]]]}', 'Godavari Basin', 1, 1, 12.00, 14.00, 13.80, 215.00, 'Critical', 'active'),
(6, 'Nashik Godavari Downstream Basin', 'Nashik Godavari Downstream Basin', 'Nashik', 'Maharashtra', 19.9975000, 73.7898000, '{"type":"Polygon","coordinates":[[[73.740,19.950],[73.840,19.950],[73.840,20.050],[73.740,20.050],[73.740,19.950]]]}', 'Godavari Basin', 1, 9, 14.50, 16.20, 15.35, 120.00, 'High', 'active'),
(7, 'Paithan / Jayakwadi Inundation Belt', 'Paithan / Jayakwadi Inundation Belt', 'Chhatrapati Sambhajinagar', 'Maharashtra', 19.4780000, 75.3850000, '{"type":"Polygon","coordinates":[[[75.320,19.420],[75.450,19.420],[75.450,19.530],[75.320,19.530],[75.320,19.420]]]}', 'Godavari Basin', 1, 1, 462.50, 463.90, 463.50, 145.00, 'Critical', 'active'),
(8, 'Koyna-Krishna Confluence Basin (Karad)', 'Koyna-Krishna Confluence Basin (Karad)', 'Satara', 'Maharashtra', 17.2885000, 74.1840000, '{"type":"Polygon","coordinates":[[[74.120,17.220],[74.250,17.220],[74.250,17.340],[74.120,17.340],[74.120,17.220]]]}', 'Krishna Basin', 2, 2, 52.00, 54.50, 53.60, 95.00, 'High', 'active'),
(9, 'Panchganga Floodplains (Kolhapur)', 'Panchganga Floodplains (Kolhapur)', 'Kolhapur', 'Maharashtra', 16.7050000, 74.2433000, '{"type":"Polygon","coordinates":[[[74.180,16.650],[74.300,16.650],[74.300,16.760],[74.180,16.760],[74.180,16.650]]]}', 'Krishna-Panchganga Basin', 10, 12, 39.00, 43.00, 37.50, 65.00, 'Moderate', 'active'),
(10, 'Sangli Krishna River Inundation Area', 'Sangli Krishna River Inundation Area', 'Sangli', 'Maharashtra', 16.8524000, 74.5815000, '{"type":"Polygon","coordinates":[[[74.520,16.800],[74.650,16.800],[74.650,16.900],[74.520,16.900],[74.520,16.800]]]}', 'Krishna Basin', 2, 2, 14.50, 16.00, 13.80, 75.00, 'Moderate', 'active'),
(11, 'Pune Mutha-Mula River Floodplain', 'Pune Mutha-Mula River Floodplain', 'Pune', 'Maharashtra', 18.5204000, 73.8567000, '{"type":"Polygon","coordinates":[[[73.800,18.480],[73.920,18.480],[73.920,18.560],[73.800,18.560],[73.800,18.480]]]}', 'Bhima Basin', 12, 13, 580.50, 582.70, 579.80, 85.00, 'Moderate', 'active'),
(12, 'Pandharpur Bhima Flood Inundation Zone', 'Pandharpur Bhima Flood Inundation Zone', 'Solapur', 'Maharashtra', 17.6780000, 75.3250000, '{"type":"Polygon","coordinates":[[[75.280,17.620],[75.380,17.620],[75.380,17.720],[75.280,17.720],[75.280,17.620]]]}', 'Bhima Basin', 11, 14, 415.50, 418.00, 414.20, 90.00, 'Moderate', 'active'),
(13, 'Cuttack Mahanadi Delta Sector', 'Cuttack Mahanadi Delta Sector', 'Cuttack', 'Odisha', 20.4625000, 85.8830000, NULL, 'Mahanadi Basin', 7, 6, 26.00, 28.50, 29.10, 185.00, 'Critical', 'active'),
(14, 'Supaul Kosi Flood Basin', 'Supaul Kosi Flood Basin', 'Supaul', 'Bihar', 26.1260000, 86.6050000, NULL, 'Kosi Basin', 9, 21, 48.00, 50.50, 51.20, 165.00, 'Critical', 'active'),
(15, 'Guwahati Brahmaputra Sector', 'Guwahati Brahmaputra Sector', 'Kamrup', 'Assam', 26.1850000, 91.7450000, NULL, 'Brahmaputra Basin', 6, NULL, 49.50, 51.00, 50.20, 110.00, 'High', 'active');

-- ----------------------------------------------------------------------------
-- 7. SEED USERS (Bcrypt Hashed Credentials for Immediate Password Verification)
-- ----------------------------------------------------------------------------
-- Passwords:
-- Admin:        admin@floodrelief.org       -> Admin@1234
-- Coordinator:  coordinator@floodrelief.org -> Coord@1234
-- Citizen:      citizen@example.com         -> Citizen@1234
-- Other users:  Citizen@1234
INSERT INTO users (id, role_id, full_name, email, phone, district, river_basin_id, monitored_dam_id, address, password_hash, status, created_at) VALUES
(1, 1, 'Disaster Operations Admin', 'admin@floodrelief.org', '+91 98470 11223', 'Mumbai', 1, 1, 'State Disaster Control Room, Mantralaya, Mumbai', '$2y$10$QRTnH./Syoq9p.YQAsnC/ufuVUt2Uigg5yh.H.ubef1fxZTISxAYa', 'active', NOW()),
(2, 2, 'Rajesh Kumar (Relief Coordinator)', 'coordinator@floodrelief.org', '+91 94471 55667', 'Nashik', 1, 9, 'Nashik District Emergency Operations Center, Collectorate', '$2y$10$zuFBo0n06VoIyruuWCp9AevNAZGOOQx5xiPY3jV/hREqfMrulFrQ.', 'active', NOW()),
(3, 3, 'Ananya Nair (Citizen)', 'citizen@example.com', '+91 98950 33445', 'Nashik', 1, 9, 'Plot 42, Anandwalli, Near Gangapur Road, Nashik', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(4, 3, 'Sunil Deshmukh (Citizen)', 'sunil.deshmukh@example.com', '+91 98220 11223', 'Nashik', 1, 9, 'Gangapur Gaon, Near Riverbank Ghat, Nashik, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(5, 3, 'Priya Patil (Citizen)', 'priya.patil@example.com', '+91 98221 44556', 'Ahmednagar', 1, 11, 'Bhandardara Colony, Shendi, Akole, Ahmednagar, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(6, 3, 'Amit Shinde (Citizen)', 'amit.shinde@example.com', '+91 98222 77889', 'Chhatrapati Sambhajinagar', 1, 1, 'Near Paithan Gate, Nath Mandir Ward, Paithan, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(7, 3, 'Ramesh Joshi (Citizen)', 'ramesh.joshi@example.com', '+91 98223 99001', 'Satara', 2, 2, 'Koynanagar Helwak Road, Patan, Satara, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(8, 3, 'Kavita More (Citizen)', 'kavita.more@example.com', '+91 98224 22334', 'Solapur', 11, 14, 'Daund-Kurduvadi Marg, Tembhurni, Solapur, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(9, 3, 'Sanjay Jadhav (Citizen)', 'sanjay.jadhav.pune@example.com', '+91 98229 98877', 'Pune', 11, 13, 'Sinhagad Road, Khadakwasla Catchment, Pune, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW()),
(10, 3, 'Gaurav Kulkarni (Citizen)', 'gaurav.kulkarni@example.com', '+91 98221 12233', 'Jalgaon', 12, 18, 'Civil Lines, Near Tapi Road, Jalgaon, MH', '$2y$10$yS5J978I3cWgeANsLYnyy.3ze6IhB0.r1XIGGacdeNi50bY3J8fgS', 'active', NOW());

-- ----------------------------------------------------------------------------
-- 8. SEED RISK RULES
-- ----------------------------------------------------------------------------
INSERT INTO risk_rules (id, rule_name, rainfall_weight, river_weight, max_rainfall_baseline, max_river_baseline, low_max_score, mod_max_score, high_max_score, is_active, updated_by) VALUES
(1, 'Standard Monsoonal Thresholds v1.0', 0.50, 0.50, 250.00, 15.00, 25.00, 50.00, 75.00, TRUE, 1);

-- ----------------------------------------------------------------------------
-- 9. SEED RISK LEVELS
-- ----------------------------------------------------------------------------
INSERT INTO risk_levels (zone_id, rainfall_value, river_level_value, score, category, source, observed_at) VALUES
(1, 195.00, 13.20, 83.00, 'Critical', 'XML Ingestion', NOW()),
(2, 145.00, 9.60, 61.00, 'High', 'XML Ingestion', NOW()),
(3, 85.00, 6.20, 37.67, 'Moderate', 'Manual Entry', NOW()),
(4, 35.00, 2.80, 16.33, 'Low', 'Manual Entry', NOW()),
(5, 215.00, 13.80, 89.00, 'Critical', 'Sensor Feed', NOW()),
(6, 120.00, 15.35, 78.50, 'High', 'IMD Hydrology Feed', NOW()),
(7, 145.00, 463.50, 96.50, 'Critical', 'Central Water Commission (CWC)', NOW()),
(8, 95.00, 53.60, 74.00, 'High', 'IMD & CWC Station', NOW()),
(9, 65.00, 37.50, 42.00, 'Moderate', 'Irrigation Division Data', NOW()),
(10, 75.00, 13.80, 48.50, 'Moderate', 'IMD Station Sangli', NOW()),
(11, 85.00, 579.80, 46.00, 'Moderate', 'Pune Municipal Telemetry', NOW()),
(12, 90.00, 414.20, 49.50, 'Moderate', 'Solapur Irrigation Cell', NOW()),
(13, 185.00, 29.10, 94.50, 'Critical', 'CWC Delta Gauge', NOW()),
(14, 165.00, 51.20, 95.10, 'Critical', 'Kosi Project Cell', NOW()),
(15, 110.00, 50.20, 72.80, 'High', 'Brahmaputra Board', NOW());

-- ----------------------------------------------------------------------------
-- 10. SEED RELIEF CAMPS & PRIMARY SHELTERS
-- ----------------------------------------------------------------------------
INSERT INTO camps (id, zone_id, dam_id, river_basin_id, name, camp_name, address, district, latitude, longitude, contact_person, contact_phone, total_capacity, current_occupancy, status, supply_status, active) VALUES
(1, 1, 8, 8, 'Aluva Govt High School Relief Shelter', 'Aluva Govt High School Relief Shelter', 'Market Road, Near Aluva Metro Station, Ernakulam', 'Ernakulam', 10.1105000, 76.3540000, 'Suresh Menon (Tahsildar)', '+91 94471 23456', 350, 180, 'Operational', 'Sufficient', TRUE),
(2, 1, 8, 8, 'UC College Indoor Stadium Camp', 'UC College Indoor Stadium Camp', 'UC College PO, Aluva, Ernakulam', 'Ernakulam', 10.1250000, 76.3350000, 'Prof. K. Narayanan', '+91 94472 34567', 600, 520, 'Operational', 'Critical', TRUE),
(3, 2, 8, 8, 'Edathua St. Aloysius Higher Secondary Shelter', 'Edathua St. Aloysius Higher Secondary Shelter', 'Edathua Junction, Kuttanad, Alappuzha', 'Alappuzha', 9.3680000, 76.4710000, 'Fr. Mathew Joseph', '+91 94473 45678', 450, 410, 'Operational', 'Replenishment Needed', TRUE),
(4, 2, 8, 8, 'Champakulam Govt LP School Camp', 'Champakulam Govt LP School Camp', 'Champakulam Boat Jetty, Kuttanad, Alappuzha', 'Alappuzha', 9.4050000, 76.4250000, 'V. Radhakrishnan', '+91 94474 56789', 250, 85, 'Operational', 'Abundant', TRUE),
(5, 3, 8, 8, 'Chalakudy Carmel College Relief Center', 'Chalakudy Carmel College Relief Center', 'Near Railway Station, Chalakudy, Thrissur', 'Thrissur', 10.3010000, 76.3280000, 'Sr. Mercy Paul', '+91 94475 67890', 500, 220, 'Operational', 'Sufficient', TRUE),
(6, 4, 8, 8, 'Ranni St. Thomas College Evacuation Hub', 'Ranni St. Thomas College Evacuation Hub', 'Pazhavangadi, Ranni, Pathanamthitta', 'Pathanamthitta', 9.3850000, 76.7950000, 'Jacob Mathew', '+91 94476 78901', 400, 130, 'Operational', 'Sufficient', TRUE),
(7, 5, 8, 8, 'Meppadi Community Hall Emergency Shelter', 'Meppadi Community Hall Emergency Shelter', 'Panchayat Office Road, Meppadi, Wayanad', 'Wayanad', 11.5510000, 76.1280000, 'Dr. Faisal Rahman', '+91 94477 89012', 300, 280, 'Full', 'Critical', TRUE),
(8, 5, 8, 8, 'Vythiri Model Residential School Camp', 'Vythiri Model Residential School Camp', 'Old NH-212, Vythiri, Wayanad', 'Wayanad', 11.5420000, 76.0450000, 'K. Balakrishnan', '+91 94478 90123', 350, 95, 'Operational', 'Abundant', TRUE),
(9, 6, 9, 1, 'Nashik Municipal Relief Shelter', 'Nashik Municipal Relief Shelter', 'Near Gangapur Dam Road, Anandwalli, Nashik, Maharashtra', 'Nashik', 19.9985000, 73.7250000, 'Sunil Gaikwad (Tehsildar)', '+91 98220 55112', 600, 210, 'Operational', 'Sufficient', TRUE),
(10, 6, 11, 1, 'Akole / Sangamner Emergency Hall', 'Akole / Sangamner Emergency Hall', 'Wilson Dam Downstream Relief Zone, Shendi, Akole, Ahmednagar', 'Ahmednagar', 19.5412000, 73.9920000, 'Babanrao Thorat (Relief Officer)', '+91 98221 66223', 450, 120, 'Operational', 'Abundant', TRUE),
(11, 7, 1, 1, 'Paithan / Chhatrapati Sambhajinagar Shelter', 'Paithan / Chhatrapati Sambhajinagar Shelter', 'Jayakwadi Right Bank Canal Road, Paithan, Sambhajinagar', 'Chhatrapati Sambhajinagar', 19.4890000, 75.3810000, 'Dilip Deshmukh (Sub-Divisional Officer)', '+91 98222 77334', 800, 280, 'Operational', 'Sufficient', TRUE),
(12, 8, 2, 2, 'Karad / Satara Relief Camp', 'Karad / Satara Relief Camp', 'Krishna-Koyna Pritisangam Relief Complex, Karad, Satara', 'Satara', 17.2885000, 74.1840000, 'Ajay Patil (Executive Magistrate)', '+91 98223 88445', 900, 250, 'Operational', 'Abundant', TRUE),
(13, 12, 14, 11, 'Daund / Pandharpur Community Shelter', 'Daund / Pandharpur Community Shelter', 'Bhima River Relief Building, Daund Road, Pandharpur, Solapur', 'Solapur', 17.6780000, 75.3250000, 'Ganesh Kadam (Panchayat Officer)', '+91 98224 99556', 650, 240, 'Operational', 'Sufficient', TRUE),
(14, 10, 18, 12, 'Jalgaon Flood Relief Camp', 'Jalgaon Flood Relief Camp', 'Hatnur Reservoir Inundation Shelter, Bhusawal-Yawal Road, Jalgaon', 'Jalgaon', 21.0120000, 75.5680000, 'Sanjay Chaudhari (Revenue Inspector)', '+91 98225 11667', 500, 160, 'Operational', 'Sufficient', TRUE),
(15, 9, 12, 10, 'Kolhapur Rajaram Bandhara Relief Complex', 'Kolhapur Rajaram Bandhara Relief Complex', 'Near Panchganga Ghat, Kasba Bawada, Kolhapur', 'Kolhapur', 16.7210000, 74.2510000, 'Vilas Shinde (Disaster Cell)', '+91 98226 22778', 750, 310, 'Operational', 'Sufficient', TRUE),
(16, 11, 13, 11, 'Pune Sinhagad Road Disaster Shelter', 'Pune Sinhagad Road Disaster Shelter', 'Near Khadakwasla Dam Spillway, Dhayari, Pune', 'Pune', 18.4410000, 73.8010000, 'Anand Raje (Pune Municipal Corp)', '+91 98227 33445', 700, 210, 'Operational', 'Sufficient', TRUE),
(17, 13, 6, 7, 'Cuttack Ravenshaw Cyclone Center', 'Cuttack Ravenshaw Cyclone Center', 'College Square, Cuttack', 'Cuttack', 20.4650000, 85.8880000, 'Debasish Mohanty', '+91 94370 12345', 1000, 980, 'Operational', 'Critical', TRUE),
(18, 14, 21, 9, 'Supaul District High School Shelter', 'Supaul District High School Shelter', 'Near Gandhi Maidan, Supaul, Bihar', 'Supaul', 26.1290000, 86.6090000, 'Rameshwar Jha (Circle Officer)', '+91 98350 12345', 800, 720, 'Operational', 'Sufficient', TRUE),
(19, 15, NULL, 6, 'Guwahati Sarusajai Indoor Camp', 'Guwahati Sarusajai Indoor Camp', 'National Highway 37, Guwahati', 'Kamrup', 26.1890000, 91.7510000, 'Hemanta Sarma (Camp Manager)', '+91 94350 11223', 1200, 850, 'Operational', 'Abundant', TRUE);

-- ----------------------------------------------------------------------------
-- 11. SEED CAMP UPDATES AUDIT LOGS
-- ----------------------------------------------------------------------------
INSERT INTO camp_updates (camp_id, previous_occupancy, new_occupancy, previous_status, new_status, updated_by, remarks, created_at) VALUES
(1, 120, 180, 'Operational', 'Operational', 2, 'Inflow of 60 citizens from Lower Aluva ward 4.', NOW() - INTERVAL '5 hours'),
(2, 450, 520, 'Operational', 'Operational', 2, 'Capacity strained; dispatched request for additional bed kits.', NOW() - INTERVAL '3 hours'),
(7, 210, 280, 'Operational', 'Full', 2, 'Meppadi shelter declared at maximum safe occupancy.', NOW() - INTERVAL '1 hour'),
(11, 200, 280, 'Operational', 'Operational', 1, 'Jayakwadi downstream evacuation intake wave 1.', NOW() - INTERVAL '2 hours');

-- ----------------------------------------------------------------------------
-- 12. SEED CITIZEN PROFILES
-- ----------------------------------------------------------------------------
INSERT INTO citizen_profiles (user_id, saved_village_city, saved_river_id, saved_dam_id, alert_notifications_enabled) VALUES
(3, 'Nashik City / Anandwalli', 1, 9, TRUE),
(4, 'Gangapur Gaon Riverfront', 1, 9, TRUE),
(5, 'Shendi Bhandardara Colony', 14, 11, TRUE),
(6, 'Paithan Old Town Gate', 1, 1, TRUE),
(7, 'Karad Riverside Pritisangam', 2, 2, TRUE),
(8, 'Tembhurni Town Solapur', 11, 14, TRUE),
(9, 'Khadakwasla Dam Catchment, Pune', 12, 13, TRUE),
(10, 'Tapi Riverside Jalgaon', 13, 18, TRUE);

-- ----------------------------------------------------------------------------
-- 13. SEED HELP & SOS EVACUATION REQUESTS
-- ----------------------------------------------------------------------------
INSERT INTO help_requests (id, reference_code, citizen_id, guest_name, guest_phone, guest_email, request_type, urgency, water_severity, mobile_verified, people_count, description, address, latitude, longitude, status, assigned_to, created_at) VALUES
(1, 'REQ-20260905-9012', 3, 'Ananya Nair', '+91 98950 33445', 'citizen@example.com', 'Evacuation', 'Critical', 'Roof-Level', TRUE, 4, 'Water entered ground floor, elderly parents and infant stranded on rooftop terrace. Power disconnected.', 'House #42, Bank Junction, Aluva River View Road', 10.1090000, 76.3530000, 'Acknowledged', 2, NOW() - INTERVAL '2 hours'),
(2, 'REQ-20260905-8431', NULL, 'Mathew Varghese', '+91 98460 77889', NULL, 'Food & Water', 'High', 'Waist-Level', TRUE, 7, 'Drinking water supply contaminated. Need potable drinking water cans and non-perishable food kits.', 'Champakkulam East Ward, Kuttanad', 9.4280000, 76.5180000, 'In Progress', 2, NOW() - INTERVAL '4 hours'),
(3, 'REQ-20260905-7720', NULL, 'Pradeep Menon', '+91 97450 11990', 'pradeep@mail.com', 'Medical Support', 'Medium', 'Ankle-Level', TRUE, 2, 'Diabetic insulin medication urgently required for senior citizen. Road access partially submerged.', 'Near St. Marys Church, Chalakudy', 10.3060000, 76.3320000, 'New', NULL, NOW() - INTERVAL '30 minutes'),
(4, 'REQ-20261015-1102', 6, 'Amit Shinde', '+91 98222 77889', 'amit.shinde@example.com', 'Evacuation', 'Critical', 'Waist-Level', TRUE, 5, 'Jayakwadi 18-gate release caused sudden inundation in Paithan low-lying ward 4. Rapid rescue boat required.', 'Near Nath Mandir Ghat, Paithan', 19.4820000, 75.3850000, 'In Progress', 2, NOW() - INTERVAL '1 hour'),
(5, 'REQ-20261020-5541', 9, 'Sanjay Jadhav', '+91 98229 98877', 'sanjay.jadhav.pune@example.com', 'Shelter', 'High', 'Ankle-Level', TRUE, 3, 'Mutha river discharge increasing. Seeking shelter routing for family with elderly grandmother.', 'Sinhagad Road, Pune', 18.4520000, 73.8120000, 'New', NULL, NOW() - INTERVAL '45 minutes');

-- ----------------------------------------------------------------------------
-- 14. SEED HELP REQUEST LOGS
-- ----------------------------------------------------------------------------
INSERT INTO help_request_logs (id, request_id, action, previous_status, new_status, action_by, notes, created_at) VALUES
(1, 1, 'Request Created', NULL, 'New', NULL, 'Emergency request submitted online by citizen.', NOW() - INTERVAL '2 hours'),
(2, 1, 'Status Update', 'New', 'Acknowledged', 2, 'Rescue boat unit #4 dispatched from Aluva depot.', NOW() - INTERVAL '90 minutes'),
(3, 2, 'Request Created', NULL, 'New', NULL, 'Guest request submitted via public form.', NOW() - INTERVAL '4 hours'),
(4, 2, 'Status Update', 'New', 'In Progress', 2, 'Cooperative boat loaded with 50 water cans en route.', NOW() - INTERVAL '2 hours'),
(5, 3, 'Request Created', NULL, 'New', NULL, 'Medical assistance request recorded in system.', NOW() - INTERVAL '30 minutes'),
(6, 4, 'Status Update', 'New', 'In Progress', 2, 'NDRF motor boat dispatched to Paithan lowlands.', NOW() - INTERVAL '40 minutes');

-- ----------------------------------------------------------------------------
-- 15. SEED EMERGENCY ALERTS
-- ----------------------------------------------------------------------------
INSERT INTO alerts (id, title, message, instructions, severity, target_zone_id, channel, channels, status, is_active, created_by, expires_at, created_at) VALUES
(1, 'RED ALERT: Evacuation Advisory for Lower Periyar Basin', 'Periyar River water level has crossed extreme danger mark (13.2m). All residents within 300 meters of riverbanks must move to designated higher-ground relief camps immediately. NDRF teams stationed at Aluva Town.', 'Evacuate immediately to Aluva Govt High School Shelter. Carry identification, essential medicines, and waterproof bags.', 'Critical Danger', 1, 'All', 'Web,Email,SMS', 'Published', TRUE, 1, NOW() + INTERVAL '24 hours', NOW() - INTERVAL '3 hours'),
(2, 'ORANGE ALERT: River Water Rising in Kuttanad Lowlands', 'Continuous heavy precipitation upstream. Pamba and Manimala rivers swelling. Residents advised to secure livestock, charge emergency lights, and locate closest functional relief camps.', 'Move valuables to upper floors. Keep battery radios tuned to disaster broadcast.', 'Warning', 2, 'All', 'Web,Email,SMS', 'Published', TRUE, 1, NOW() + INTERVAL '36 hours', NOW() - INTERVAL '6 hours'),
(3, 'RED ALERT: Massive Discharge from Jayakwadi Dam (Nath Sagar)', 'Jayakwadi Dam has opened 18 gates discharging 42,000 cusecs into Godavari River. Downstream floodplain villages in Paithan and Shevgaon must evacuate to municipal shelters.', 'Avoid riverbank ghats. Follow designated evacuation route via Canal Road to Paithan Municipal Shelter.', 'Critical Danger', 7, 'All', 'Web,Email,SMS', 'Published', TRUE, 1, NOW() + INTERVAL '24 hours', NOW() - INTERVAL '1 hour'),
(4, 'YELLOW ADVISORY: Khadakwasla Dam Spillway Discharge Active', 'Mutha River water level rising due to 11,400 cusecs spillway release from Khadakwasla Dam. Low-lying bridges in Pune (Bhide Bridge) closed for vehicular traffic.', 'Do not park vehicles along riverbed roads. Keep emergency kit prepared.', 'Advisory', 11, 'In-App', 'Web', 'Published', TRUE, 1, NOW() + INTERVAL '18 hours', NOW() - INTERVAL '2 hours'),
(5, 'FLASH FLOOD WARNING: Kosi River Rising Beyond Extreme Danger', 'Kosi Barrage discharge exceeds 210,000 cusecs following cloudburst in Nepal catchment. Embankments in Supaul on high vigil.', 'Immediate high ground relocation ordered for unprotected diara settlements.', 'Critical Danger', 14, 'All', 'Web,Email,SMS', 'Published', TRUE, 1, NOW() + INTERVAL '48 hours', NOW() - INTERVAL '4 hours');

-- ----------------------------------------------------------------------------
-- 16. SEED ALERT DELIVERY LOGS
-- ----------------------------------------------------------------------------
INSERT INTO alert_delivery_logs (id, alert_id, channel, recipient_target, recipient_contact, delivery_status, details, sent_at, dispatched_at) VALUES
(1, 1, 'In-App Broadcast', 'Residents in Zone #1', 'All Public Web Portal Users', 'Delivered', 'Broadcasted to public top alert banner across portal.', NOW() - INTERVAL '3 hours', NOW() - INTERVAL '3 hours'),
(2, 1, 'SMS Gateway Simulation', 'Residents in Zone #1', '+91 98470 11223', 'Sent', 'Emergency SMS notification dispatched to 450 registered numbers in Aluva.', NOW() - INTERVAL '3 hours', NOW() - INTERVAL '3 hours'),
(3, 2, 'In-App Broadcast', 'Residents in Zone #2', 'All Public Web Portal Users', 'Delivered', 'Broadcasted to public top alert banner across portal.', NOW() - INTERVAL '6 hours', NOW() - INTERVAL '6 hours'),
(4, 3, 'Email (SMTP)', 'Residents in Zone #7', 'amit.shinde@example.com', 'Sent', 'Dispatched via smtp.gmail.com:465 (TLS)', NOW() - INTERVAL '1 hour', NOW() - INTERVAL '1 hour'),
(5, 3, 'SMS Gateway Simulation', 'Residents in Zone #7', '+91 98222 77889', 'Sent', 'Emergency SMS evacuation alert sent to Paithan ward residents.', NOW() - INTERVAL '1 hour', NOW() - INTERVAL '1 hour'),
(6, 4, 'In-App Broadcast', 'Pune Flood Zone #11', 'Pune Citizens', 'Delivered', 'Advisory banner published on citizen watch portal.', NOW() - INTERVAL '2 hours', NOW() - INTERVAL '2 hours'),
(7, 5, 'All Channels', 'Supaul Kosi District', 'Public Broadcast', 'Sent', 'Dispatched to community radio and cell broadcast network.', NOW() - INTERVAL '4 hours', NOW() - INTERVAL '4 hours');

-- ----------------------------------------------------------------------------
-- 17. SEED MISSING & FOUND PERSONS
-- ----------------------------------------------------------------------------
INSERT INTO missing_persons (id, report_type, person_name, gender, age, last_seen_or_found_location, last_seen_or_found_date, photo_url, contact_name, contact_phone, contact_relation, camp_id, status, notes) VALUES
(1, 'Missing', 'Aarav Sharma', 'Child', 9, 'Near Sangli Old Bridge during flood evacuation', CURRENT_DATE - INTERVAL '1 day', NULL, 'Ramesh Sharma', '+91 98220 12345', 'Father', NULL, 'Reported', 'Wearing blue t-shirt and grey shorts. Separated while boarding rescue boat.'),
(2, 'Missing', 'Sunita Deshmukh', 'Female', 62, 'Godavari Riverbank Colony, Paithan', CURRENT_DATE - INTERVAL '2 days', NULL, 'Vikas Deshmukh', '+91 94221 54321', 'Son', NULL, 'Verified', 'Diabetic patient, wearing maroon cotton saree and gold spectacles.'),
(3, 'Found', 'Unidentified Boy (approx 7 yrs)', 'Child', 7, 'Rescued from rooftop at Bank Junction, Aluva', CURRENT_DATE, NULL, 'Suresh Varma (Camp Incharge)', '+91 94470 12345', 'Relief Officer', 1, 'Reported', 'Currently sheltered safely at Aluva Govt High School Relief Shelter. Responds to the name "Appu".'),
(4, 'Found', 'Namdev Jadhav (Senior Citizen)', 'Male', 74, 'Near Gangapur Dam spillway pump house, Nashik', CURRENT_DATE - INTERVAL '1 day', NULL, 'Sunil Gaikwad (Tehsildar)', '+91 98220 55112', 'Relief Incharge', 9, 'Verified', 'Accommodated at Nashik Municipal Relief Shelter. Seeking family contact in Nashik.');

-- ----------------------------------------------------------------------------
-- 18. SEED RELIEF DONATIONS & VOLUNTEERS DIRECTORY
-- ----------------------------------------------------------------------------
INSERT INTO donations_volunteers (id, type, full_name, email, phone, district, state, item_category, amount, quantity_description, skills_or_notes, assigned_camp_id, status) VALUES
(1, 'Donation', 'Kirloskar Relief Trust', 'csr@kirloskargroup.com', '+91 20 2747 4411', 'Pune', 'Maharashtra', 'Funds', 250000.00, 'Direct bank wire for emergency dry ration kits', 'Corporate CSR Disaster Relief Contribution', 16, 'Approved'),
(2, 'Supplies', 'Red Cross Maharashtra Chapter', 'relief@redcrossmh.org', '+91 22 2266 1234', 'Mumbai', 'Maharashtra', 'Medical Supplies', 0.00, '500 First-Aid Trauma Kits & ORS cartons', 'Dispatched via refrigerated emergency van', 9, 'Dispatched'),
(3, 'Volunteer', 'Dr. Sneha Kulkarni', 'dr.sneha@aimsmedical.org', '+91 98230 45678', 'Nashik', 'Maharashtra', 'Medical Service', 0.00, 'Physician / Emergency Trauma Care', 'Available on ground for emergency medical triage and waterborne disease screening', 9, 'Approved'),
(4, 'Volunteer', 'Girish Mahajan (River Rescue Club)', 'girish.rescue@gmail.com', '+91 98220 88990', 'Satara', 'Maharashtra', 'Boat Operations', 0.00, 'Licensed inflatable motorized boat pilot with 3 divers', 'Available for deep water flood rescue along Koyna-Krishna confluence', 12, 'Approved'),
(5, 'Supplies', 'Tata Consumer Products Relief Cell', 'csr.water@tataconsumer.com', '+91 22 6665 8282', 'Mumbai', 'Maharashtra', 'Drinking Water', 0.00, '2,000 cases of 1-liter packaged mineral water bottles', 'Immediate delivery to Paithan and Jayakwadi flood camps', 11, 'Received'),
(6, 'Donation', 'Anonymous Citizen Donor', 'donor.help@gmail.com', '+91 98900 12345', 'Ernakulam', 'Kerala', 'Funds', 50000.00, 'Online UPI donation for baby food and hygiene kits', 'Citizen Emergency Fund contribution', 1, 'Approved');

-- ----------------------------------------------------------------------------
-- 19. SEED SIMULATION LOGS
-- ----------------------------------------------------------------------------
INSERT INTO simulation_logs (id, triggered_by, dam_id, simulated_rainfall_mm, simulated_discharge_cusecs, action, created_at) VALUES
(1, 1, 1, 145.00, 42000, 'Triggered', NOW() - INTERVAL '1 day'),
(2, 1, 1, 12.00, 3800, 'Reset', NOW() - INTERVAL '20 hours');

-- ----------------------------------------------------------------------------
-- 20. SEED AUDIT LOGS
-- ----------------------------------------------------------------------------
INSERT INTO audit_logs (id, user_id, action_type, table_affected, record_id, details, ip_address, created_at) VALUES
(1, 1, 'SYSTEM_INIT', 'system', NULL, 'PostgreSQL 16/18 Database Schema and seed engine initialized successfully.', '127.0.0.1', NOW() - INTERVAL '1 day'),
(2, 1, 'USER_LOGIN', 'users', 1, 'Successful login by admin@floodrelief.org (Administrator)', '127.0.0.1', NOW() - INTERVAL '12 hours'),
(3, 1, 'ALERT_BROADCAST', 'alerts', 1, 'Broadcasted Critical Danger alert: Lower Periyar Basin', '127.0.0.1', NOW() - INTERVAL '3 hours'),
(4, 1, 'ALERT_BROADCAST', 'alerts', 3, 'Broadcasted Critical Danger alert: Jayakwadi Dam release', '127.0.0.1', NOW() - INTERVAL '1 hour'),
(5, 2, 'CAMP_OCCUPANCY_UPDATE', 'camps', 1, 'Updated Aluva Govt High School occupancy from 120 to 180.', '127.0.0.1', NOW() - INTERVAL '5 hours');

-- ----------------------------------------------------------------------------
-- 21. SEED USER PREFERENCES
-- ----------------------------------------------------------------------------
INSERT INTO user_preferences (user_id, language, theme, email_alerts, sms_alerts) VALUES
(1, 'en', 'dark', TRUE, TRUE),
(2, 'en', 'light', TRUE, TRUE),
(3, 'en', 'light', TRUE, TRUE),
(6, 'mr', 'light', TRUE, TRUE),
(9, 'mr', 'light', TRUE, TRUE);

-- ----------------------------------------------------------------------------
-- 22. SEED SYSTEM SETTINGS
-- ----------------------------------------------------------------------------
INSERT INTO system_settings (setting_key, setting_value, description) VALUES
('portal_name', 'FloodRelief DSS - Decision Support System', 'Official portal public branding name'),
('state_emergency_helpline', '1077 / 112', 'State 24x7 disaster response toll-free emergency helpline'),
('active_monsoon_mode', 'true', 'Toggles high-frequency telemetry polling and live dam alert banners'),
('cwc_api_sync_interval_mins', '15', 'Automated CWC dam telemetry polling frequency'),
('default_evacuation_buffer_km', '5.0', 'Default radius for identifying nearest primary relief camps'),
('smtp_notifications_enabled', 'true', 'Enables automated red alert dispatch via configured SMTP server');

-- ============================================================================
-- PART 5: SYNCHRONIZE POSTGRESQL PRIMARY KEY SEQUENCES
-- ============================================================================

SELECT setval('roles_id_seq', (SELECT COALESCE(MAX(id), 1) FROM roles));
SELECT setval('users_id_seq', (SELECT COALESCE(MAX(id), 1) FROM users));
SELECT setval('rivers_id_seq', (SELECT COALESCE(MAX(id), 1) FROM rivers));
SELECT setval('river_basins_id_seq', (SELECT COALESCE(MAX(id), 1) FROM river_basins));
SELECT setval('dams_id_seq', (SELECT COALESCE(MAX(id), 1) FROM dams));
SELECT setval('dam_telemetry_id_seq', (SELECT COALESCE(MAX(id), 1) FROM dam_telemetry));
SELECT setval('zones_id_seq', (SELECT COALESCE(MAX(id), 1) FROM zones));
SELECT setval('risk_rules_id_seq', (SELECT COALESCE(MAX(id), 1) FROM risk_rules));
SELECT setval('risk_levels_id_seq', (SELECT COALESCE(MAX(id), 1) FROM risk_levels));
SELECT setval('camps_id_seq', (SELECT COALESCE(MAX(id), 1) FROM camps));
SELECT setval('camp_updates_id_seq', (SELECT COALESCE(MAX(id), 1) FROM camp_updates));
SELECT setval('citizen_profiles_id_seq', (SELECT COALESCE(MAX(id), 1) FROM citizen_profiles));
SELECT setval('help_requests_id_seq', (SELECT COALESCE(MAX(id), 1) FROM help_requests));
SELECT setval('help_request_logs_id_seq', (SELECT COALESCE(MAX(id), 1) FROM help_request_logs));
SELECT setval('alerts_id_seq', (SELECT COALESCE(MAX(id), 1) FROM alerts));
SELECT setval('alert_delivery_logs_id_seq', (SELECT COALESCE(MAX(id), 1) FROM alert_delivery_logs));
SELECT setval('missing_persons_id_seq', (SELECT COALESCE(MAX(id), 1) FROM missing_persons));
SELECT setval('donations_volunteers_id_seq', (SELECT COALESCE(MAX(id), 1) FROM donations_volunteers));
SELECT setval('simulation_logs_id_seq', (SELECT COALESCE(MAX(id), 1) FROM simulation_logs));
SELECT setval('audit_logs_id_seq', (SELECT COALESCE(MAX(id), 1) FROM audit_logs));
SELECT setval('user_preferences_id_seq', (SELECT COALESCE(MAX(id), 1) FROM user_preferences));
SELECT setval('system_settings_id_seq', (SELECT COALESCE(MAX(id), 1) FROM system_settings));

-- ============================================================================
-- END OF SCRIPT: flood_relief_pgsql_full.sql
-- ============================================================================

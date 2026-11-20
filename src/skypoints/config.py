"""Business rules in one place."""
STALE_DAYS = 90
MEMBER_COLUMNS = ["member_name", "member_id", "enrollment_date", "last_flight_date", "tier_code",
                  "agent_name", "state", "country", "post_code", "dob", "is_active"]
MAX_LEN = {"member_name": 255, "member_id": 18, "tier_code": 5, "agent_name": 255, "state": 5,
           "country": 5, "post_code": 5, "is_active": 1}
# Feeds mix ISO-2, ISO-3 and short names (USA, IND, PHIL, CAN, AU). Canonical = ISO alpha-2.
COUNTRY_MAP = {"USA": "US", "US": "US", "IND": "IN", "IN": "IN", "PHIL": "PH", "PH": "PH",
               "CAN": "CA", "CA": "CA", "AU": "AU", "AUS": "AU"}
TABLE_NAMES = {"US": "TABLE_USA", "IN": "TABLE_INDIA", "PH": "TABLE_PHILIPPINES",
               "CA": "TABLE_CANADA", "AU": "TABLE_AUSTRALIA"}
KNOWN_TIERS = {"GLD", "SLV", "PLT", "BRZ"}
KNOWN_ACTIVE = {"A", "I"}
# header aliases seen across the spec / staging table / country files
ALIASES = {"id": "member_id", "unique_id": "member_id", "tiercode": "tier_code", "tier_type": "tier_code",
           "enrollmentdate": "enrollment_date", "date_of_enrollment": "enrollment_date", "flightdate": "last_flight_date",
           "date_of_flight": "last_flight_date", "date_of_birth": "dob", "individual_or_corporate": "member_type",
           "type": "member_type", "name": "member_name", "mem_id": "member_id", "memberid": "member_id", "enroll_dt": "enrollment_date",
           "flight_dt": "last_flight_date", "flight_date": "last_flight_date", "tier": "tier_code",
           "county": "country", "flag": "is_active", "active_member": "is_active", "postcode": "post_code",
           "date_of_birth": "dob"}

EXTRA_COLUMNS = ["member_type"]
# Each source layout: how its dates are written. Country comes from the file name for the per-country extracts.
#  YMD  = 20101012        ISO = 2022-05-11       DMY = 1/1/2022 (day first)
#  MDY  = 6/15/2022 or 6152022 (unpadded digits, ambiguous when 7 digits)    DMY8 = 03051985 (zero may be lost)
PROFILES = {
    "PIPE": {"enrollment_date": "YMD", "last_flight_date": "YMD", "dob": "DMY8"},
    "USA":  {"enrollment_date": "MDY", "last_flight_date": "MDY", "dob": "MDY"},
    "AUS":  {"enrollment_date": "ISO", "last_flight_date": "ISO", "dob": "ISO"},
    "IND":  {"enrollment_date": "DMY", "last_flight_date": "DMY", "dob": "DMY"},
}
KNOWN_MEMBER_TYPES = {"I", "C"}
NULL_TOKENS = {"NULL", "N/A", "NA", "NONE", "NAN", "NAT"}

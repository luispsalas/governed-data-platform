"""Generate synthetic PII data for the Governed Lakehouse POC.

Everything here is fake (Faker). Fixed seed, so every run produces the same files.

Output (in data/):
  customers.csv  ~5,000 rows  - PII-heavy: names, email, phone, birth date, national ID, address
  orders.csv     ~20,000 rows - transactions with a (fake) card number, for PCI-style masking

A small share of rows carry deliberate defects (null email, negative amount,
future order date, unknown customer) so the Phase 5 data-quality rules have
something to catch. Rates are set in DEFECT_RATE.

Run:  .venv/bin/python generate_data.py
"""

import csv
import random
from datetime import date, timedelta
from pathlib import Path

from faker import Faker

SEED = 42
N_CUSTOMERS = 5000
N_ORDERS = 20000
DEFECT_RATE = 0.01  # about 1% of rows get one data-quality defect

# region -> list of (country, Faker locale); regions drive the row filter in Phase 3
REGIONS = {
    "NA": [("US", "en_US"), ("CA", "en_CA")],
    "EU": [("DE", "de_DE"), ("FR", "fr_FR"), ("ES", "es_ES")],
    "LATAM": [("MX", "es_MX"), ("BR", "pt_BR"), ("CO", "es_CO")],
}
REGION_WEIGHTS = {"NA": 0.40, "EU": 0.35, "LATAM": 0.25}
CURRENCY = {"US": "USD", "CA": "CAD", "DE": "EUR", "FR": "EUR", "ES": "EUR",
            "MX": "MXN", "BR": "BRL", "CO": "COP"}

random.seed(SEED)
fakers = {}
for countries in REGIONS.values():
    for country, locale in countries:
        f = Faker(locale)
        f.seed_instance(SEED + len(fakers))  # distinct seed per locale, or they repeat each other's values
        fakers[country] = f

OUT = Path(__file__).parent / "data"
OUT.mkdir(exist_ok=True)


def national_id(f):
    # Most locales implement ssn() in their own national format; fall back if not
    try:
        return f.ssn()
    except AttributeError:
        return f.bothify("??#########").upper()


def make_customers():
    rows = []
    regions = list(REGION_WEIGHTS)
    weights = list(REGION_WEIGHTS.values())
    for i in range(1, N_CUSTOMERS + 1):
        region = random.choices(regions, weights)[0]
        country, _ = random.choice(REGIONS[region])
        f = fakers[country]
        first, last = f.first_name(), f.last_name()
        email = f"{first}.{last}{random.randint(1, 999)}@{f.free_email_domain()}".lower().replace(" ", "")
        if random.random() < DEFECT_RATE:
            email = ""  # defect: missing email
        rows.append({
            "customer_id": f"C{i:05d}",
            "first_name": first,
            "last_name": last,
            "email": email,
            "phone": f.phone_number(),
            "date_of_birth": f.date_of_birth(minimum_age=18, maximum_age=85).isoformat(),
            "national_id": national_id(f),
            "street_address": f.street_address().replace("\n", " "),
            "city": f.city(),
            "postcode": f.postcode(),
            "country": country,
            "region": region,
            "segment": random.choices(["retail", "premium", "business"], [0.7, 0.2, 0.1])[0],
            "marketing_consent": random.random() < 0.55,  # GDPR/CCPA consent flag
            "created_at": (date(2022, 1, 1) + timedelta(days=random.randint(0, 1300))).isoformat(),
        })
    return rows


def make_orders(customers):
    rows = []
    today = date(2026, 9, 21)
    for i in range(1, N_ORDERS + 1):
        c = random.choice(customers)
        f = fakers[c["country"]]
        created = date.fromisoformat(c["created_at"])
        order_date = created + timedelta(days=random.randint(0, max(1, (today - created).days)))
        amount = round(random.lognormvariate(3.8, 0.9), 2)
        customer_id = c["customer_id"]

        if random.random() < DEFECT_RATE:
            defect = random.choice(["negative_amount", "future_date", "orphan_customer"])
            if defect == "negative_amount":
                amount = -amount
            elif defect == "future_date":
                order_date = today + timedelta(days=random.randint(1, 365))
            else:
                customer_id = f"C{random.randint(90000, 99999)}"

        rows.append({
            "order_id": f"O{i:06d}",
            "customer_id": customer_id,
            "order_date": order_date.isoformat(),
            "amount": amount,
            "currency": CURRENCY[c["country"]],
            "card_number": f.credit_card_number(),
            "status": random.choices(["completed", "refunded", "cancelled"], [0.9, 0.06, 0.04])[0],
        })
    return rows


def write_csv(name, rows):
    path = OUT / name
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"{path.name}: {len(rows):,} rows")


if __name__ == "__main__":
    customers = make_customers()
    write_csv("customers.csv", customers)
    write_csv("orders.csv", make_orders(customers))

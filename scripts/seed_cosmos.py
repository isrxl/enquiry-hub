"""
Bulk-seed Cosmos DB with sample enquiry data from seed_data.json.

Usage:
    az login
    python scripts/seed_cosmos.py --endpoint https://<account>.documents.azure.com:443/

Or set COSMOS_ENDPOINT in the environment and omit --endpoint.
"""

import argparse
import json
import os
import sys
from pathlib import Path

from azure.cosmos import CosmosClient, PartitionKey
from azure.identity import DefaultAzureCredential


SEED_FILE = Path(__file__).parent / "seed_data.json"
DATABASE_NAME = "EnquiryHub"
CONTAINER_NAME = "Enquiries"


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed Cosmos DB with sample enquiries.")
    parser.add_argument(
        "--endpoint",
        default=os.environ.get("COSMOS_ENDPOINT"),
        help="Cosmos DB account endpoint URL (or set COSMOS_ENDPOINT env var)",
    )
    args = parser.parse_args()

    if not args.endpoint:
        print("ERROR: provide --endpoint or set COSMOS_ENDPOINT", file=sys.stderr)
        sys.exit(1)

    items = json.loads(SEED_FILE.read_text(encoding="utf-8"))
    print(f"Loaded {len(items)} items from {SEED_FILE.name}")

    credential = DefaultAzureCredential()
    client = CosmosClient(url=args.endpoint, credential=credential)
    container = client.get_database_client(DATABASE_NAME).get_container_client(CONTAINER_NAME)

    ok = 0
    for item in items:
        container.upsert_item(item)
        ok += 1
        print(f"  [{ok}/{len(items)}] upserted {item['id']}  urgency={item['urgency']}")

    print(f"\nDone — {ok} items upserted into {DATABASE_NAME}/{CONTAINER_NAME}")


if __name__ == "__main__":
    main()

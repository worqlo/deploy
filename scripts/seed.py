#!/usr/bin/env python3
"""
Seed script for self-hosted Worqlo deployments.

This script populates essential reference data required for the application to function:
- Roles (admin, user)
- Domains (Sales, Marketing, Support, Engineering)

NOTE: Connector metadata (connectors, connection_properties, domain_connectors) is now
defined in code as static classes. See:
- connectors/hubspot/connection.py (HUBSPOT_METADATA)
- connectors/salesforce/connection.py (SALESFORCE_METADATA)
- connectors/odoo/connection.py (ODOO_METADATA)

Run AFTER Alembic migrations have created the tables.

Usage:
    python deploy/scripts/seed.py
    # or in Docker: docker-compose exec api python deploy/scripts/seed.py
"""

import asyncio
import os
import sys
import uuid
from datetime import datetime, timezone

# Add parent directory to path so we can import app modules
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker


# Get database URL from environment
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+asyncpg://worqlo:worqlo@localhost:5432/worqlo"
)

# Convert postgres:// to postgresql+asyncpg:// if needed
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)
elif DATABASE_URL.startswith("postgresql://") and "asyncpg" not in DATABASE_URL:
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)


# =============================================================================
# Seed Data Definitions
# =============================================================================

ROLES = [
    {
        "id": str(uuid.uuid4()),
        "title": "admin",
        "description": "Administrator with full access to all features",
        "is_active": True,
    },
    {
        "id": str(uuid.uuid4()),
        "title": "user",
        "description": "Standard user with basic access",
        "is_active": True,
    },
]

DOMAINS = [
    {"id": str(uuid.uuid4()), "title": "Sales", "is_active": True},
    {"id": str(uuid.uuid4()), "title": "Marketing", "is_active": True},
    {"id": str(uuid.uuid4()), "title": "Support", "is_active": True},
    {"id": str(uuid.uuid4()), "title": "Engineering", "is_active": True},
]


# =============================================================================
# Seed Functions
# =============================================================================

async def check_table_exists(session: AsyncSession, table_name: str) -> bool:
    """Check if a table exists in the database."""
    result = await session.execute(
        text("""
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_schema = 'public' 
                AND table_name = :table_name
            )
        """),
        {"table_name": table_name}
    )
    return result.scalar()


async def check_table_has_data(session: AsyncSession, table_name: str) -> bool:
    """Check if a table has any data."""
    result = await session.execute(text(f"SELECT EXISTS (SELECT 1 FROM {table_name} LIMIT 1)"))
    return result.scalar()


async def seed_roles(session: AsyncSession) -> None:
    """Seed roles table."""
    if await check_table_has_data(session, "roles"):
        print("  ⏭️  Roles table already has data, skipping...")
        return

    now = datetime.now(timezone.utc)
    for role in ROLES:
        await session.execute(
            text("""
                INSERT INTO roles (id, title, description, is_active, date_created, is_deleted)
                VALUES (:id, :title, :description, :is_active, :date_created, false)
                ON CONFLICT DO NOTHING
            """),
            {**role, "date_created": now}
        )
    print(f"  ✅ Seeded {len(ROLES)} roles")


async def seed_domains(session: AsyncSession) -> list:
    """Seed domains table and return the seeded domains."""
    if await check_table_has_data(session, "domains"):
        print("  ⏭️  Domains table already has data, skipping...")
        # Return existing domains
        result = await session.execute(text("SELECT id, title FROM domains WHERE is_deleted = false"))
        return [{"id": str(row.id), "title": row.title} for row in result.fetchall()]

    now = datetime.now(timezone.utc)
    for domain in DOMAINS:
        await session.execute(
            text("""
                INSERT INTO domains (id, title, is_active, date_created, is_deleted)
                VALUES (:id, :title, :is_active, :date_created, false)
                ON CONFLICT DO NOTHING
            """),
            {**domain, "date_created": now}
        )
    print(f"  ✅ Seeded {len(DOMAINS)} domains")
    return DOMAINS


async def main():
    """Run all seed operations."""
    print("\n" + "=" * 60)
    print("🌱 Worqlo Database Seeding")
    print("=" * 60)
    print(f"\nDatabase: {DATABASE_URL.split('@')[1] if '@' in DATABASE_URL else DATABASE_URL}")
    
    engine = create_async_engine(DATABASE_URL, echo=False)
    async_session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async with async_session() as session:
        # Check if tables exist (migrations ran)
        if not await check_table_exists(session, "roles"):
            print("\n❌ Error: Tables don't exist. Run Alembic migrations first:")
            print("   alembic upgrade head")
            sys.exit(1)

        print("\n📊 Seeding reference data...\n")
        print("   Note: Connector metadata is now defined in code, not database.")
        print("   See connectors/*/connection.py for METADATA definitions.\n")
        
        try:
            await seed_roles(session)
            await seed_domains(session)
            
            await session.commit()
            print("\n" + "=" * 60)
            print("✅ Seeding completed successfully!")
            print("=" * 60 + "\n")
            
        except Exception as e:
            await session.rollback()
            print(f"\n❌ Seeding failed: {e}")
            sys.exit(1)

    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())

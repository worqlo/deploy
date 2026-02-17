-- =============================================================================
-- Worqlo Database Initialization
-- =============================================================================
-- This script runs ONCE on first PostgreSQL container startup.
-- It ONLY configures PostgreSQL extensions.
--
-- NOTE: Tables are NOT created here - Alembic migrations handle that.
-- NOTE: Seed data is NOT inserted here - deploy/scripts/seed.py handles that.
--
-- The startup order is:
--   1. PostgreSQL starts, runs this init-db.sql (extensions)
--   2. API container starts, runs Alembic migrations (tables)
--   3. API container runs seed.py (roles, domains, connectors)
--   4. Application starts
-- =============================================================================

-- Enable pgvector extension for knowledge base embeddings
-- Used by DocumentChunk for semantic search
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable UUID generation for primary keys
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable pg_trgm for text/trigram search (fuzzy matching)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Grant permissions to the worqlo user
GRANT ALL PRIVILEGES ON DATABASE worqlo TO worqlo;

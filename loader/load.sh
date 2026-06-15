#!/bin/bash
set -e

PGCONN="postgresql://slr:${POSTGRES_PASSWORD}@postgis/slr"

echo "Waiting for PostGIS to accept connections..."
until pg_isready -h postgis -p 5432 -U slr; do
  sleep 2
done

echo "Creating table..."
psql "$PGCONN" <<'SQL'
DROP TABLE IF EXISTS slr_inundation;
DROP TABLE IF EXISTS slr_temp;

CREATE TABLE slr_inundation (
  id       SERIAL PRIMARY KEY,
  scenario INTEGER NOT NULL,
  geom     GEOMETRY(MultiPolygon, 4326)
);
CREATE INDEX slr_geom_idx ON slr_inundation USING GIST (geom);
SQL

for FT in 1 2 3 4 5 6; do
  echo "Fetching ${FT}ft scenario from NOAA..."
  curl -sL \
    "https://www.coast.noaa.gov/arcgis/rest/services/dc_slr/SLR_${FT}ft/MapServer/0/query?where=1%3D1&outFields=*&f=geojson" \
    -o /tmp/slr.geojson

  echo "Loading ${FT}ft into staging table..."
  ogr2ogr -f PostgreSQL "$PGCONN" \
    /tmp/slr.geojson \
    -nln slr_temp \
    -nlt PROMOTE_TO_MULTI \
    -overwrite

  echo "Moving ${FT}ft features into main table..."
  psql "$PGCONN" -c "
    INSERT INTO slr_inundation (scenario, geom)
    SELECT ${FT}, ST_Multi(wkb_geometry)::geometry(MultiPolygon, 4326)
    FROM slr_temp;
    DROP TABLE IF EXISTS slr_temp;
  "
  echo "  Scenario ${FT}ft done."
done

echo "All 6 scenarios loaded successfully."

# Sea Level Rise Explorer — Design Spec

**Date:** 2026-06-15  
**Status:** Approved

## Goal

Build a containerized web mapping application that visualizes NOAA sea level rise inundation scenarios. Primary purpose is learning Docker/Docker Compose containerization concepts in a GIS context, using exclusively free and open source tools.

---

## Architecture

Five containers orchestrated with Docker Compose:

```
┌─────────────────────────────────────────────────────────────┐
│  docker-compose.yml                                          │
│                                                             │
│  ┌──────────┐    ┌─────────────┐    ┌──────────────────┐   │
│  │  loader  │───▶│   postgis   │◀───│   pg_tileserv    │   │
│  │(one-shot)│    │  :5432      │    │   :7800          │   │
│  └──────────┘    └─────────────┘    └──────────────────┘   │
│                        ▲                                    │
│                        │            ┌──────────────────┐   │
│                        └────────────│  pg_featureserv  │   │
│                                     │  :9000           │   │
│                                     └──────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  nginx  :8080  (serves Leaflet frontend)             │   │
│  │         proxies /tiles → pg_tileserv                 │   │
│  │         proxies /features → pg_featureserv           │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Containers

| Service | Image | Role |
|---|---|---|
| `postgis` | `postgis/postgis:16-3.4` | Spatial database |
| `loader` | `ghcr.io/osgeo/gdal:ubuntu-small-latest` | One-shot data ingestion, exits after import |
| `pg_tileserv` | `pramsey/pg_tileserv` | Serves Mapbox Vector Tiles from PostGIS |
| `pg_featureserv` | `pramsey/pg_featureserv` | Serves OGC API Features (query/filter) |
| `nginx` | `nginx:alpine` | Serves static frontend, proxies tile/feature APIs |

### Docker Compose Concepts Demonstrated

- **Named network** — all services share one internal network; containers resolve each other by service name (e.g., `postgis:5432`)
- **Named volume** — PostGIS data directory mounted to a named volume so data survives `docker compose down/up`
- **`depends_on` + healthcheck** — `loader`, `pg_tileserv`, and `pg_featureserv` wait for PostGIS to pass a health check before starting
- **Init container pattern** — `loader` runs once and exits with `restart: no`; long-lived services use `restart: unless-stopped`
- **Environment variables** — database credentials passed via `.env` file, never hard-coded
- **nginx reverse proxy** — single origin at `localhost:8080` proxies to internal container endpoints

---

## Data

### Source

NOAA Sea Level Rise inundation data via ArcGIS REST API:  
`https://www.coast.noaa.gov/arcgis/rest/services/dc_slr`

Scenarios to load: 1ft through 6ft (`SLR_1ft` through `SLR_6ft` map services).

### Ingestion

The `loader` container runs `ogr2ogr` (GDAL) to pull each scenario from the NOAA ArcGIS REST endpoint as GeoJSON and insert it into the PostGIS table with a `scenario` column:

```bash
for FT in 1 2 3 4 5 6; do
  ogr2ogr -f PostgreSQL \
    PG:"host=postgis dbname=slr user=slr password=..." \
    "https://www.coast.noaa.gov/arcgis/rest/services/dc_slr/SLR_${FT}ft/MapServer/0/query?where=1%3D1&outFields=*&f=geojson" \
    -nln slr_inundation \
    -nlt PROMOTE_TO_MULTI \
    -sql "SELECT *, ${FT} AS scenario FROM OGRGeoJSON" \
    -append
done
```

### PostGIS Schema

```sql
CREATE TABLE slr_inundation (
  id        SERIAL PRIMARY KEY,
  scenario  INTEGER NOT NULL,       -- sea level rise in feet (1–6)
  geom      GEOMETRY(MultiPolygon, 4326)
);
CREATE INDEX ON slr_inundation USING GIST (geom);
```

Additional attribute columns from the NOAA source (e.g., `state`, `county`) will be preserved as-is by `ogr2ogr`.

---

## APIs

### pg_tileserv — Vector Tiles

Auto-discovers `slr_inundation` and serves Mapbox Vector Tiles:

```
GET /tiles/public.slr_inundation/{z}/{x}/{y}.pbf
```

Frontend fetches tiles for the selected scenario by passing a CQL filter:

```
GET /tiles/public.slr_inundation/{z}/{x}/{y}.pbf?filter=scenario=3
```

### pg_featureserv — Feature Query

Auto-discovers `slr_inundation` and serves OGC API Features:

```
GET /features/collections/public.slr_inundation/items?scenario=3&limit=1000
```

Used for popup attribute display when a user clicks a polygon.

### nginx Proxying

Both APIs are proxied through nginx so the browser only talks to `localhost:8080`:

```
/tiles/     → http://pg_tileserv:7800/
/features/  → http://pg_featureserv:9000/
```

---

## Frontend

Single `index.html` file — no build step, no framework. Leaflet loaded from CDN.

### Layout

```
┌────────────────────────────────────────────┐
│  NOAA Sea Level Rise Explorer              │
│  Sea Level Rise: 1ft ──●────────── 6ft    │
├────────────────────────────────────────────┤
│                                            │
│         (Leaflet map, full height)         │
│                                            │
│   OpenStreetMap basemap                    │
│   + inundation layer (blue, semi-transparent)│
│                                            │
│   [click a feature → popup with attrs]    │
└────────────────────────────────────────────┘
```

### Behavior

- **Basemap:** OpenStreetMap tiles (free, no API key required)
- **Inundation layer:** vector tiles from pg_tileserv, styled blue with semi-transparency; deeper scenarios use higher opacity
- **Scenario slider:** range input from 1–6; dragging updates the tile layer URL filter and redraws the layer
- **Feature popups:** clicking a polygon fetches attributes from pg_featureserv and displays them in a Leaflet popup

---

## File Structure

```
containers/
├── docker-compose.yml
├── .env                        # DB credentials (gitignored)
├── .env.example
├── loader/
│   └── load.sh                 # ogr2ogr ingestion script
├── nginx/
│   └── nginx.conf              # reverse proxy config
└── frontend/
    └── index.html              # Leaflet app
```

---

## Local Development

```bash
cp .env.example .env
docker compose up
# loader runs once, then exits
# app available at http://localhost:8080
```

To reload data: `docker compose run --rm loader`  
To wipe and restart: `docker compose down -v && docker compose up`

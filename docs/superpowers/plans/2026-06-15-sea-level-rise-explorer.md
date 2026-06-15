# Sea Level Rise Explorer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a containerized web mapping application that visualizes NOAA sea level rise inundation scenarios (1–6 ft) using Docker Compose, PostGIS, pg_featureserv, and Leaflet.

**Architecture:** Five Docker Compose services — PostGIS (spatial database), a one-shot loader (fetches NOAA data via ogr2ogr and exits), pg_tileserv (vector tile endpoint, bonus explorer), pg_featureserv (GeoJSON feature/filter API), and nginx (static frontend + reverse proxy). All services share a Docker-managed internal network; the browser only talks to nginx on port 8080.

**Tech Stack:** Docker Compose, PostGIS 16-3.4, GDAL/ogr2ogr, pramsey/pg_tileserv, pramsey/pg_featureserv, nginx:alpine, Leaflet 1.9.4, OpenStreetMap tiles (no API key required)

---

## File Structure

```
containers/
├── docker-compose.yml
├── .env                          # gitignored — copied from .env.example
├── .env.example
├── .gitignore
├── loader/
│   ├── Dockerfile                # GDAL image + postgresql-client + curl
│   └── load.sh                   # ogr2ogr ingestion script (runs once, exits)
├── nginx/
│   └── nginx.conf                # static file serving + reverse proxy rules
└── frontend/
    └── index.html                # Leaflet app — no build step, no framework
```

---

### Task 1: Scaffold project

**Files:**
- Create: `.gitignore`
- Create: `.env.example`
- Create: `.env` (local only, not committed)

- [ ] **Step 1: Create .gitignore**

```
.env
```

- [ ] **Step 2: Create .env.example**

```
POSTGRES_PASSWORD=changeme
```

- [ ] **Step 3: Create .env**

```bash
cp .env.example .env
```

Open `.env` and set any local password:
```
POSTGRES_PASSWORD=slrpass
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: scaffold project"
```

---

### Task 2: PostGIS service

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Write docker-compose.yml with PostGIS only**

```yaml
version: "3.9"

services:
  postgis:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_DB: slr
      POSTGRES_USER: slr
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "slr", "-d", "slr"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  pgdata:
```

- [ ] **Step 2: Start PostGIS and verify it becomes healthy**

```bash
docker compose up -d postgis
docker compose ps
```

Expected output (after ~15 seconds — the image downloads on first run):
```
NAME                    IMAGE                    STATUS
containers-postgis-1    postgis/postgis:16-3.4   Up (healthy)
```

If it shows `Up (health: starting)`, wait another 10 seconds and re-run `docker compose ps`.

- [ ] **Step 3: Verify PostGIS extension is available**

```bash
docker compose exec postgis psql -U slr -d slr -c "SELECT PostGIS_Version();"
```

Expected: a row showing the PostGIS version string, e.g.:
```
             postgis_version
------------------------------------------
 3.4 USE_GEOS=1 USE_PROJ=1 USE_STATS=1
```

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add PostGIS service"
```

---

### Task 3: Loader container

**Files:**
- Create: `loader/Dockerfile`
- Create: `loader/load.sh`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Write loader/Dockerfile**

```dockerfile
FROM ghcr.io/osgeo/gdal:ubuntu-small-latest
RUN apt-get update \
  && apt-get install -y --no-install-recommends postgresql-client curl \
  && rm -rf /var/lib/apt/lists/*
COPY load.sh /load.sh
RUN chmod +x /load.sh
ENTRYPOINT ["/load.sh"]
```

- [ ] **Step 2: Write loader/load.sh**

```bash
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
```

- [ ] **Step 3: Add loader service to docker-compose.yml**

Replace the existing `services:` block:

```yaml
version: "3.9"

services:
  postgis:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_DB: slr
      POSTGRES_USER: slr
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "slr", "-d", "slr"]
      interval: 5s
      timeout: 5s
      retries: 10

  loader:
    build: ./loader
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      postgis:
        condition: service_healthy
    restart: "no"

volumes:
  pgdata:
```

- [ ] **Step 4: Build the loader image**

```bash
docker compose build loader
```

Expected: build completes with `Successfully built` (or similar). This downloads the GDAL base image and installs postgresql-client and curl.

- [ ] **Step 5: Run the loader**

```bash
docker compose up loader
```

Watch the logs. The loader fetches 6 NOAA scenarios over the network — expect 1–3 minutes depending on connection speed. Expected final log line:
```
containers-loader-1  | All 6 scenarios loaded successfully.
containers-loader-1 exited with code 0
```

Exit code 0 means success. Any other exit code means a step failed — scroll up in the logs to find which scenario failed.

- [ ] **Step 6: Verify data in PostGIS**

```bash
docker compose exec postgis psql -U slr -d slr -c \
  "SELECT scenario, COUNT(*) FROM slr_inundation GROUP BY scenario ORDER BY scenario;"
```

Expected (row counts vary by region — any non-zero count is correct):
```
 scenario | count
----------+-------
        1 |    42
        2 |    89
        3 |   134
        ...
(6 rows)
```

If any scenario shows 0 rows, re-run the loader: `docker compose run --rm loader`

- [ ] **Step 7: Commit**

```bash
git add loader/ docker-compose.yml
git commit -m "feat: add NOAA data loader container"
```

---

### Task 4: pg_tileserv and pg_featureserv services

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add pg_tileserv and pg_featureserv to docker-compose.yml**

Replace the `services:` block:

```yaml
version: "3.9"

services:
  postgis:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_DB: slr
      POSTGRES_USER: slr
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "slr", "-d", "slr"]
      interval: 5s
      timeout: 5s
      retries: 10

  loader:
    build: ./loader
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      postgis:
        condition: service_healthy
    restart: "no"

  pg_tileserv:
    image: pramsey/pg_tileserv:latest
    environment:
      DATABASE_URL: postgresql://slr:${POSTGRES_PASSWORD}@postgis/slr
    depends_on:
      postgis:
        condition: service_healthy
    ports:
      - "7800:7800"
    restart: unless-stopped

  pg_featureserv:
    image: pramsey/pg_featureserv:latest
    environment:
      DATABASE_URL: postgresql://slr:${POSTGRES_PASSWORD}@postgis/slr
    depends_on:
      postgis:
        condition: service_healthy
    ports:
      - "9000:9000"
    restart: unless-stopped

volumes:
  pgdata:
```

- [ ] **Step 2: Start the new services**

```bash
docker compose up -d pg_tileserv pg_featureserv
```

- [ ] **Step 3: Verify pg_tileserv responds**

```bash
curl -s http://localhost:7800/index.json
```

Expected: JSON response containing tile service metadata. If you get `connection refused`, wait 10 seconds and retry — pg_tileserv starts quickly but may still be pulling the image.

- [ ] **Step 4: Verify pg_tileserv discovered our table**

```bash
curl -s http://localhost:7800/public.slr_inundation.json
```

Expected: JSON with layer metadata. If you get a 404, check `docker compose logs pg_tileserv` for connection errors.

- [ ] **Step 5: Verify pg_featureserv discovered our table**

```bash
curl -s http://localhost:9000/collections/public.slr_inundation.json
```

Expected: JSON containing `"id": "public.slr_inundation"`.

- [ ] **Step 6: Test a filtered feature query against pg_featureserv**

```bash
curl -s "http://localhost:9000/collections/public.slr_inundation/items?scenario=1&limit=2"
```

Expected: a GeoJSON FeatureCollection with 2 features, each having `"scenario": 1` in their properties.

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add pg_tileserv and pg_featureserv services"
```

---

### Task 5: nginx service and frontend skeleton

**Files:**
- Create: `nginx/nginx.conf`
- Create: `frontend/index.html`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Write nginx/nginx.conf**

```nginx
server {
    listen 80;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location /tiles/ {
        proxy_pass http://pg_tileserv:7800/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /features/ {
        proxy_pass http://pg_featureserv:9000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

The trailing slash on `proxy_pass` is important: it strips the `/tiles/` and `/features/` prefixes before forwarding to the upstream container.

- [ ] **Step 2: Write frontend/index.html (placeholder)**

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>SLR Explorer</title></head>
<body><h1>Sea Level Rise Explorer</h1><p>Map coming soon.</p></body>
</html>
```

- [ ] **Step 3: Add nginx to docker-compose.yml**

Add the following service after `pg_featureserv` in the `services:` block:

```yaml
  nginx:
    image: nginx:alpine
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./frontend:/usr/share/nginx/html:ro
    ports:
      - "8080:80"
    depends_on:
      - pg_tileserv
      - pg_featureserv
    restart: unless-stopped
```

- [ ] **Step 4: Start nginx**

```bash
docker compose up -d nginx
```

- [ ] **Step 5: Verify nginx serves the placeholder**

```bash
curl -s http://localhost:8080
```

Expected:
```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>SLR Explorer</title></head>
<body><h1>Sea Level Rise Explorer</h1><p>Map coming soon.</p></body>
</html>
```

- [ ] **Step 6: Verify nginx proxies /features/ to pg_featureserv**

```bash
curl -s "http://localhost:8080/features/collections/public.slr_inundation.json" | grep '"id"'
```

Expected output contains: `"id": "public.slr_inundation"`

This confirms the reverse proxy is working — the browser will only ever talk to port 8080.

- [ ] **Step 7: Commit**

```bash
git add nginx/ frontend/ docker-compose.yml
git commit -m "feat: add nginx reverse proxy and frontend skeleton"
```

---

### Task 6: Full Leaflet frontend

**Files:**
- Modify: `frontend/index.html`

- [ ] **Step 1: Replace index.html with the full Leaflet application**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>NOAA Sea Level Rise Explorer</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: sans-serif; display: flex; flex-direction: column; height: 100vh; }

    #controls {
      padding: 10px 16px;
      background: #1a1a2e;
      color: #e0e0e0;
      display: flex;
      align-items: center;
      gap: 20px;
      flex-shrink: 0;
    }

    #controls h1 { font-size: 1rem; font-weight: 600; white-space: nowrap; }

    #slider-group { display: flex; align-items: center; gap: 10px; }

    #scenario-slider { width: 180px; accent-color: #00b4d8; cursor: pointer; }

    #ft-display { min-width: 40px; font-weight: bold; color: #00b4d8; }

    #status { margin-left: auto; font-size: 0.85rem; color: #aaa; font-style: italic; }

    #map { flex: 1; }
  </style>
</head>
<body>
  <div id="controls">
    <h1>NOAA Sea Level Rise Explorer</h1>
    <div id="slider-group">
      <span>Sea level rise:</span>
      <input type="range" id="scenario-slider" min="1" max="6" value="1" step="1">
      <span id="ft-display">1 ft</span>
    </div>
    <span id="status">Loading...</span>
  </div>
  <div id="map"></div>

  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    const map = L.map('map').setView([37.5, -76], 7);

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      maxZoom: 19
    }).addTo(map);

    let inundationLayer = null;
    const statusEl = document.getElementById('status');
    const ftDisplay = document.getElementById('ft-display');

    const scenarioColors = {
      1: '#caf0f8',
      2: '#90e0ef',
      3: '#48cae4',
      4: '#0096c7',
      5: '#0077b6',
      6: '#03045e'
    };

    async function loadScenario(ft) {
      ftDisplay.textContent = `${ft} ft`;
      statusEl.textContent = 'Loading...';

      if (inundationLayer) {
        map.removeLayer(inundationLayer);
        inundationLayer = null;
      }

      try {
        const res = await fetch(
          `/features/collections/public.slr_inundation/items?scenario=${ft}&limit=10000`
        );
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const geojson = await res.json();
        const count = geojson.features ? geojson.features.length : 0;

        inundationLayer = L.geoJSON(geojson, {
          style: {
            color: scenarioColors[ft],
            fillColor: scenarioColors[ft],
            fillOpacity: 0.5,
            weight: 0.5
          },
          onEachFeature: (feature, layer) => {
            layer.bindPopup(
              `<strong>Sea Level Rise Scenario</strong><br>` +
              `Inundation depth: <b>${ft} ft</b>`
            );
          }
        }).addTo(map);

        statusEl.textContent = `${count} features loaded`;
      } catch (err) {
        statusEl.textContent = `Error: ${err.message}`;
        console.error(err);
      }
    }

    document.getElementById('scenario-slider').addEventListener('input', e => {
      loadScenario(parseInt(e.target.value, 10));
    });

    loadScenario(1);
  </script>
</body>
</html>
```

- [ ] **Step 2: Open the app in your browser**

Navigate to `http://localhost:8080`.

nginx serves the updated file immediately — no container restart needed.

Expected:
- Dark control bar at top with title and "Sea level rise: 1 ft" slider
- OpenStreetMap basemap fills the rest of the page
- After a few seconds, light blue inundation polygons appear along coastal areas
- Status bar shows feature count (e.g., `42 features loaded`)
- Dragging the slider left/right reloads features in a progressively darker blue
- Clicking a polygon opens a popup showing the scenario depth

If the map area is blank after 10 seconds: open browser DevTools → Console tab to check for errors. Common issues:
- `404 /features/...` → pg_featureserv isn't running (`docker compose ps`)
- `0 features loaded` → loader didn't finish or failed (`docker compose logs loader`)

- [ ] **Step 3: Commit**

```bash
git add frontend/index.html
git commit -m "feat: add Leaflet frontend with scenario slider and feature popups"
```

---

## Full Stack Smoke Test

After all tasks are complete, verify the entire system works from scratch:

```bash
docker compose down -v
docker compose up
```

`-v` removes the named volume, wiping the database so the loader runs fresh. Watch `docker compose logs loader -f` in a second terminal until you see `All 6 scenarios loaded successfully.`

Then open `http://localhost:8080` and verify:

- [ ] OSM basemap loads
- [ ] Default 1ft scenario shows light blue inundation polygons on the coast
- [ ] Sliding to 6ft shows darker blue with more inundation area
- [ ] Clicking a polygon shows the popup
- [ ] `docker compose ps` shows all services Up, loader shows `Exited (0)`

To re-run the loader without wiping the database (useful for debugging):
```bash
docker compose run --rm loader
```

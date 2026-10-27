#!/usr/bin/env node
// Build-time source patch for src/services/country-geometry.ts.
//
// Why: the app replaces a country's bundled boundary with a higher-resolution
// one fetched from maps.worldmonitor.app/country-boundary-overrides.geojson.
// The bundled countries.geojson follows RFC 7946 (outer rings counter-
// clockwise, holes clockwise); the override file is not guaranteed to, and as
// of 2026-10-27 its single feature (Pakistan) is wound clockwise. deck.gl (2D)
// does not care. three-conic-polygon-geometry (globe.gl, the 3D view) renders
// a clockwise outer ring as its COMPLEMENT — the entire globe — so with the
// Country Instability layer on, the 3D globe is a uniform wash in Pakistan's
// fill colour. This normalises ring winding before the override is adopted.
//
// Guarded: exits non-zero (failing the image build) if the anchor line is not
// found exactly once, or if upstream has grown its own rewind — either way
// the patch needs a human look rather than a silent skip.
//
// Runs from the upstream source root: node containers/patch-country-overrides.mjs

import { readFileSync, writeFileSync } from 'node:fs';

const FILE = 'src/services/country-geometry.ts';
const ANCHOR = '    mainFeature.geometry = overrideFeature.geometry;\n';
const MARKER = 'rewindGeometry';

let src = readFileSync(FILE, 'utf8');

if (src.includes(MARKER)) {
  console.error(`[patch] ${FILE} already contains "${MARKER}" — upstream may have fixed this; drop the patch`);
  process.exit(1);
}
const hits = src.split(ANCHOR).length - 1;
if (hits !== 1) {
  console.error(`[patch] anchor found ${hits} times in ${FILE} (expected 1) — update the patch`);
  process.exit(1);
}

src = src.replace(
  ANCHOR,
  '    rewindGeometry(overrideFeature.geometry); // fork patch: containers/patch-country-overrides.mjs\n' + ANCHOR,
);

src += `
// --- fork patch (ryannix123/worldmonitor-redhat) -----------------------------
// three-conic-polygon-geometry renders a clockwise outer ring as its complement
// (the whole globe). The bundled countries.geojson is RFC 7946 (outer CCW,
// holes CW); the CDN override file is not guaranteed to be. Normalise before
// adopting an override geometry. Mutates in place; no-op on already-correct data.
function ringSignedArea(ring: number[][]): number {
  let sum = 0;
  for (let i = 0; i < ring.length - 1; i++) {
    const a = ring[i];
    const b = ring[i + 1];
    if (!a || !b) continue;
    sum += (a[0] ?? 0) * (b[1] ?? 0) - (b[0] ?? 0) * (a[1] ?? 0);
  }
  return sum / 2;
}

function rewindPolygonRings(rings: number[][][]): void {
  rings.forEach((ring, index) => {
    const area = ringSignedArea(ring);
    if (area === 0) return;
    const wantCounterClockwise = index === 0;
    if ((area > 0) !== wantCounterClockwise) ring.reverse();
  });
}

function rewindGeometry(geometry: Geometry): void {
  if (geometry.type === 'Polygon') {
    rewindPolygonRings(geometry.coordinates);
  } else if (geometry.type === 'MultiPolygon') {
    for (const polygon of geometry.coordinates) rewindPolygonRings(polygon);
  }
}
`;

writeFileSync(FILE, src);
console.log(`[patch] ${FILE}: override geometries are rewound to RFC 7946 before adoption`);

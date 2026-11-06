#!/usr/bin/env node
// Build-time source patch for src/components/GlobeMap.ts.
//
// Why: on the 3D globe the Country Instability choropleth renders as a wash
// over the entire sphere instead of per-country fills. The renderer
// (globe.gl → three-conic-polygon-geometry) takes a ring's orientation as
// meaning: a ring wound one way is the country, wound the other way it is
// everything EXCEPT the country. public/data/countries.geojson is RFC 7946
// (outer rings counter-clockwise). Upstream knows the globe wants the
// opposite: the conflict-zone polygons in the same flushPolygons() pass go
// through getReversedRing() and render correctly. The CII loop pushes the
// raw rings, so every scored country is drawn as its own complement.
//
// This routes the CII rings through the same getReversedRing() cache the
// conflict layer uses. It composes with patch-country-overrides.mjs, which
// normalises the CDN override file to RFC 7946 first; without that, an
// override wound the other way (Pakistan, as of 2026-10-27) would be the one
// country still drawn inside-out after this reversal.
//
// Guarded: exits non-zero if the anchor is not found exactly once, or if the
// CII loop already reverses, so the nightly goes red with a named cause.
//
// Runs from the upstream source root: node containers/patch-globe-cii-winding.mjs

import { readFileSync, writeFileSync } from 'node:fs';

const FILE = 'src/components/GlobeMap.ts';
const ANCHOR =
  "        for (const ring of rings) {\n" +
  "          polys.push({ coords: ring, name, _kind: 'cii', level: entry.level, score: entry.score });\n" +
  "        }\n";
const REPLACEMENT =
  "        for (let ri = 0; ri < rings.length; ri++) {\n" +
  "          // fork patch (containers/patch-globe-cii-winding.mjs): same ring\n" +
  "          // reversal the conflict layer applies; raw RFC 7946 rings render\n" +
  "          // as their complement on the globe.\n" +
  "          polys.push({ coords: this.getReversedRing('cii', code, ri, rings[ri] as number[][][]), name, _kind: 'cii', level: entry.level, score: entry.score });\n" +
  "        }\n";

let src = readFileSync(FILE, 'utf8');

if (src.includes("getReversedRing('cii'")) {
  console.error(`[patch] ${FILE} already reverses CII rings — upstream may have fixed this; drop the patch`);
  process.exit(1);
}
if (!src.includes('private getReversedRing(')) {
  console.error(`[patch] ${FILE} has no getReversedRing() helper any more — update the patch`);
  process.exit(1);
}
const hits = src.split(ANCHOR).length - 1;
if (hits !== 1) {
  console.error(`[patch] anchor found ${hits} times in ${FILE} (expected 1) — update the patch`);
  process.exit(1);
}

writeFileSync(FILE, src.replace(ANCHOR, REPLACEMENT));
console.log(`[patch] ${FILE}: CII choropleth rings are reversed for the globe like the conflict layer's`);

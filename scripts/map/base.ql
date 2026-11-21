[out:json][timeout:900][maxsize:2000000000];
(
  way["natural"="coastline"](1.12,103.55,1.52,104.15);
  nwr["natural"~"^(water|wood|scrub|wetland|grassland|beach|sand)$"](1.15,103.58,1.50,104.12);
  nwr["landuse"~"^(reservoir|basin|grass|forest|recreation_ground|cemetery|meadow|village_green)$"](1.15,103.58,1.50,104.12);
  nwr["leisure"~"^(park|garden|golf_course|nature_reserve|pitch|playground)$"](1.15,103.58,1.50,104.12);
  nwr["waterway"~"^(riverbank|dock)$"](1.15,103.58,1.50,104.12);
  way["waterway"~"^(river|canal|drain)$"](1.15,103.58,1.50,104.12);
  way["railway"~"^(subway|light_rail|rail)$"](1.15,103.58,1.50,104.12);
  way["aeroway"~"^(runway|taxiway)$"](1.15,103.58,1.50,104.12);
  node["place"~"^(suburb|town|quarter|neighbourhood|island)$"](1.15,103.58,1.50,104.12);
);
out tags geom;
